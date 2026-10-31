# frozen_string_literal: true

require 'base64'
Dir["#{__dir__}/../exchanges/*.rb"].each { |file| require file }

module Legion
  module Transport
    module Spool
      module Legacy
        ENVELOPE_KEYS = %i[
          routing_key content_type content_encoding type priority expiration headers persistent
          message_id correlation_id reply_to app_id timestamp mandatory user_id delivery_mode cluster_id
        ].freeze
        CONSTANT_NAME = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)+\z/

        class << self
          def convert(record:, **)
            raise LegacyRecordError, 'Legacy spool record must be a Hash' unless record.is_a?(Hash)

            payload = record[:payload]
            options = payload.is_a?(Hash) ? payload : {}
            record = record.merge(exchange:    record[:exchange] || options[:exchange],
                                  routing_key: record[:routing_key] || options[:routing_key])
            validate_record(record: record)
            envelope = saved_envelope(record: record, options: options)
            tenant_id = record.fetch(:tenant_id) { options.fetch(:tenant_id, 'default') }
            tenant_id = Legion::Transport::TenantTopology.resolve_tenant_id(tenant_id: tenant_id || 'default')
            declaration = destination(record: record, options: options, tenant_id: tenant_id)
            encoded = payload.is_a?(String) ? payload : Legion::JSON.dump(payload)

            if encryption_required?(record: record, options: options, envelope: envelope)
              encrypted = Legion::Transport::Message.allocate.encrypt_message(encoded)
              envelope[:headers] = envelope.fetch(:headers, {}).except(:iv, 'iv').merge(iv: encrypted[:iv])
              envelope[:content_encoding] = 'encrypted/cs'
              encoded = encrypted[:enciphered_message]
            else
              envelope[:content_encoding] = 'identity'
            end

            {
              spool_version:    2,
              exchange:         declaration[:name],
              exchange_type:    record[:exchange_type] || declaration[:type],
              tenant_id:        tenant_id,
              payload:          Base64.strict_encode64(encoded),
              payload_encoding: encoded.encoding.name,
              envelope:         envelope,
              spooled_at:       record[:spooled_at]
            }
          rescue NameError, ArgumentError, TypeError => e
            raise LegacyRecordError, "Cannot convert legacy spool record: #{e.message}"
          end

          private

          def validate_record(record:, **)
            raise LegacyRecordError, 'Legacy spool record is missing its raw payload' unless record.key?(:payload)
            raise LegacyRecordError, 'Legacy spool record is missing its exchange destination' unless record[:exchange].is_a?(String)
            raise LegacyRecordError, 'Legacy spool record is missing its saved routing key' unless record[:routing_key].is_a?(String)
            unless record[:spooled_at].is_a?(String) && !record[:spooled_at].empty?
              raise LegacyRecordError, 'Legacy spool record is missing its saved timestamp'
            end
            return unless record.key?(:exchange_type) && !record[:exchange_type].is_a?(String)

            raise LegacyRecordError, 'Legacy spool exchange type must be a String'
          end

          def saved_envelope(record:, options:, **)
            envelope = options.slice(*ENVELOPE_KEYS).merge(record.slice(*ENVELOPE_KEYS))
            headers = [options[:headers], record[:headers]].compact
            raise LegacyRecordError, 'Legacy spool headers must be a Hash' unless headers.all?(Hash)

            envelope[:headers] = headers.reduce({}) { |saved, value| saved.merge(value) }
            envelope[:content_type] ||= 'application/json'
            envelope
          end

          def destination(record:, options:, tenant_id:, **)
            name = record[:exchange]
            unless CONSTANT_NAME.match?(name)
              return { name: Legion::Transport::TenantTopology.exchange_name(name, tenant_id: tenant_id),
                       type: 'topic' }
            end

            klass = Object.const_get(name)
            raise LegacyRecordError, "Legacy spool destination #{name} is not an Exchange or Message class" unless klass.is_a?(Class)

            if klass <= Legion::Transport::Exchange
              declaration(klass: klass, name: nil, options: options, tenant_id: tenant_id)
            elsif klass <= Legion::Transport::Message
              if klass <= Legion::Transport::Messages::Dynamic
                options = options[:args].merge(options) if options[:args].is_a?(Hash)
                raise LegacyRecordError, 'Legacy dynamic message has no saved function_id' unless options[:function_id]
              end
              saved_message = klass.allocate
              saved_message.instance_variable_set(:@options, options.merge(tenant_id: tenant_id))
              if saved_message.is_a?(Legion::Transport::Messages::Dynamic) && saved_message.function.nil?
                raise LegacyDependencyNotReady, 'Legacy dynamic message function metadata is not loaded'
              end

              exchange = saved_message.exchange
              declaration(klass: exchange, name: saved_message.publish_exchange_name, options: options, tenant_id: tenant_id)
            else
              raise LegacyRecordError, "Legacy spool destination #{name} is not an Exchange or Message class"
            end
          rescue NameError => e
            raise LegacyDependencyNotReady, "Legacy spool destination #{name} is not loaded: #{e.message}"
          end

          def declaration(klass:, name:, options:, tenant_id:, **)
            unless klass.is_a?(Class) && klass <= Legion::Transport::Exchange
              raise LegacyRecordError, 'Legacy spool message does not resolve to an offline Exchange declaration'
            end

            name ||= options[:exchange] if klass == Legion::Transport::Exchange
            if klass == Legion::Transport::Exchange && !name.is_a?(String)
              raise LegacyRecordError, 'Legacy spool message lost its exchange destination; no saved broker exchange name exists'
            end
            raise LegacyRecordError, 'Legacy spool exchange name must be a String' unless name.nil? || name.is_a?(String)

            klass.declaration(name: name, tenant_id: tenant_id)
          end

          def encryption_required?(record:, options:, envelope:, **)
            # The historical writer saved raw payloads even after an encrypted publish
            # failed. An IV is evidence of encryption policy, never reusable wire data.
            return true if [record[:content_encoding], options[:content_encoding]].any? { |value| value.to_s.start_with?('encrypted/') }
            return true if envelope[:headers].key?(:iv) || envelope[:headers].key?('iv')
            return record[:encrypt] if record.key?(:encrypt)
            return options[:encrypt] if options.key?(:encrypt)

            bootstrap = envelope[:routing_key] == 'node.crypt.push_cluster_secret' &&
                        options[:function] == 'push_cluster_secret' &&
                        options[:runner_class] == 'Legion::Extensions::Node::Runners::Crypt'
            return false if bootstrap

            Legion::Settings.dig(:transport, :messages, :encrypt)
          end
        end
      end
    end
  end
end
