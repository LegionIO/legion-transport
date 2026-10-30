# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'publisher'
require_relative 'tenant_quota'

module Legion
  module Transport
    class Message
      include Legion::Transport::Common

      LEGION_PROTOCOL_VERSION = '2.0'

      class << self
        include Legion::Logging::Helper
      end

      def initialize(**options)
        @options = options
        validate
      end

      def self.max_payload_bytes
        Legion::Settings[:transport][:max_payload_bytes]
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.message.max_payload_bytes')
        1_048_576
      end

      def publish(options = nil)
        raise unless @valid

        original_options = @options
        @options = @options.merge(options) if options
        payload = encode_message
        validate_payload_size(payload: payload)
        destination, declaration, tenant_id = resolve_publish_destination
        envelope = publish_envelope_options(@options)
        if destination.is_a?(Class)
          destination = destination.cached_instance(name: declaration[:name], tenant_id: tenant_id) ||
                        destination.new(declaration[:name], tenant_id: tenant_id)
        end
        Legion::Transport::TenantQuota.check_publish(tenant_id, message_size: payload.bytesize)
        quota_checked = true
        result = Legion::Transport::Publisher.publish(
          exchange: destination, payload: payload, envelope: envelope,
          publisher_confirm: @options[:publisher_confirm] == true, mandatory: @options[:mandatory] == true,
          confirm_timeout_ms: @options.fetch(:publish_confirm_timeout_ms, 5000)
        )
        if result[:status] == :failed
          return spool_publish_result(result: result, payload: payload, envelope: envelope, declaration: declaration, tenant_id: tenant_id)
        end
        return result if return_publish_result?(@options) || !result[:accepted]

        nil
      rescue Bunny::ConnectionClosedError, Bunny::ChannelAlreadyClosed, Bunny::ChannelError,
             Bunny::NetworkErrorWrapper, IOError, Timeout::Error => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.message.publish')
        result = publish_failure_result(:failed, e)
        return result unless payload && envelope && declaration

        Legion::Transport::TenantQuota.check_publish(tenant_id, message_size: payload.bytesize) unless quota_checked
        spool_publish_result(result: result, payload: payload, envelope: envelope, declaration: declaration, tenant_id: tenant_id)
      ensure
        @options = original_options if original_options
      end

      def publish_exchange_name
        @options[:exchange] if @options[:exchange].is_a?(String)
      end

      def publish_envelope_options(options)
        {
          routing_key:      options[:routing_key] || routing_key || '',
          content_type:     options[:content_type] || content_type,
          content_encoding: @options[:content_encoding] || content_encoding,
          type:             options[:type] || type,
          priority:         options[:priority] || priority,
          expiration:       options[:expiration] || expiration,
          headers:          headers,
          persistent:       options.key?(:persistent) ? options[:persistent] : persistent
        }.tap do |envelope|
          %i[message_id correlation_id reply_to app_id timestamp].each do |key|
            envelope[key] = options[key] || public_send(key)
          end
          envelope[:mandatory] = true if options[:mandatory] == true
          %i[user_id delivery_mode cluster_id].each { |key| envelope[key] = options[key] if options.key?(key) }
        end
      end

      def spool_enabled?(options)
        options.fetch(:spool, true) != false
      end

      def return_publish_result?(options)
        options[:return_result] == true || options[:mandatory] == true || options[:publisher_confirm] == true ||
          options[:spool] == false
      end

      def publish_failure_result(status, error, options = @options)
        {
          status:         status,
          accepted:       false,
          error_class:    error.class.name,
          error:          error.message,
          routing_key:    options[:routing_key] || routing_key || '',
          message_id:     message_id,
          correlation_id: correlation_id
        }
      end

      def app_id
        @options[:app_id] || 'legion'
      end

      def message_id
        @options[:message_id] || @options[:task_id]
      end

      # user_id Sender's identifier. https://www.rabbitmq.com/extensions.html#validated-user-id
      def user_id
        @options[:user_id] || Legion::Transport.settings[:connection][:user]
      end

      def reply_to
        @options[:reply_to]
      end

      # ID of the message that this message is a reply to.
      # Links subtasks back to the parent task.
      def correlation_id
        @options[:correlation_id] || @options[:parent_id] || @options[:task_id]
      end

      def persistent
        @options.fetch(:persistent) { Legion::Transport.settings[:messages][:persistent] }
      end

      def expiration
        if @options.key? :expiration
          @options[:expiration]
        elsif @options.key? :ttl
          @options[:ttl]
        elsif Legion::Transport.settings[:messages].key? :expiration
          Legion::Transport.settings[:messages][:expiration]
        elsif Legion::Transport.settings[:messages].key? :ttl
          Legion::Transport.settings[:messages][:ttl]
        end
      end

      PUBLISH_OPTION_KEYS = %i[
        tenant_id encrypt publisher_confirm mandatory publish_confirm_timeout_ms return_result spool
      ].freeze

      ENVELOPE_KEYS = %i[
        headers content_type content_encoding persistent expiration
        priority app_id user_id reply_to correlation_id message_id delivery_mode cluster_id
        routing_key exchange type timestamp ttl
      ].concat(PUBLISH_OPTION_KEYS).freeze

      def message
        @options.except(*ENVELOPE_KEYS)
      end

      def routing_key
        @options[:routing_key] if @options.key? :routing_key
      end

      def encode_message
        message_payload = message
        message_payload = Legion::JSON.dump(message_payload) unless message_payload.is_a? String

        if encrypt?
          encrypted = encrypt_message(message_payload)
          headers[:iv] = encrypted[:iv]
          @options[:content_encoding] = 'encrypted/cs'
          log.debug "Message encrypted with content_encoding=encrypted/cs class=#{self.class.name}"
          return encrypted[:enciphered_message]
        else
          @options[:content_encoding] = 'identity'
        end

        message_payload
      end

      def encrypt_message(message, _type = 'cs')
        unless defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:encrypt) && Legion::Settings.dig(:crypt, :cs_encrypt_ready) == true
          raise Legion::Transport::EncryptionNotReady, 'Message encryption requires a ready cluster secret'
        end

        timeout = Legion::Settings.dig(:crypt, :cluster_secret_timeout) || 5
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
          raise Legion::Transport::EncryptionNotReady, 'Cluster secret readiness timeout must be finite and positive'
        end

        Timeout.timeout(timeout, Legion::Transport::EncryptionNotReady, 'Cluster secret encryption timed out') { Legion::Crypt.encrypt(message) }
      end

      def encrypt?
        @options.key?(:encrypt) ? @options[:encrypt] : Legion::Settings[:transport][:messages][:encrypt]
      end

      def exchange_name
        parts = derive_extension_parts
        "Legion::Extensions::#{parts.join('::')}::Transport::Exchanges::#{parts.first}"
      end

      def exchange
        Kernel.const_get(exchange_name)
      end

      def headers
        @options[:headers] ||= Concurrent::Hash.new
        @options[:headers]['legion_protocol_version'] ||= LEGION_PROTOCOL_VERSION
        inject_legion_version_header
        inject_region_header
        inject_legion_region_header
        %i[task_id relationship_id trigger_namespace_id trigger_function_id parent_id master_id runner_namespace runner_class namespace_id function_id function
           chain_id debug].each do |header|
          next unless @options.key? header

          value = @options[header]
          @options[:headers][header] = case value
                                       when Integer, Float, TrueClass, FalseClass
                                         value
                                       else
                                         value.to_s
                                       end
        end
        inject_identity_headers
        @options[:headers]
      rescue StandardError => e
        handle_exception(e, level: :error, handled: true, operation: 'transport.message.headers')
        {}
      end

      def priority
        @options[:priority] || Legion::Transport.settings[:messages][:priority] || 0
      end

      def content_type
        'application/json'
      end

      def content_encoding
        'identity'
      end

      def type
        'task'
      end

      def timestamp
        Time.now.to_i
      end

      def validate
        @valid = true
      end

      def channel
        Legion::Transport::Connection.channel
      end

      private

      def resolve_publish_destination
        tenant_id = Legion::Transport::TenantTopology.resolve_tenant_id(tenant_id: @options[:tenant_id])
        destination = exchange
        tenant_id = destination.tenant_id if !@options.key?(:tenant_id) && destination.respond_to?(:tenant_id)
        declaration = if destination.is_a?(Class)
                        destination.declaration(name: publish_exchange_name, tenant_id: tenant_id)
                      else
                        { name: destination.name, type: destination.type }
                      end
        [destination, declaration, tenant_id]
      end

      def validate_payload_size(payload:)
        limit = self.class.max_payload_bytes
        size = payload.bytesize
        return if size <= limit

        raise Legion::Transport::PayloadTooLarge,
              "message payload is #{size} bytes, exceeds limit of #{limit} bytes"
      end

      def identity_process_resolved?
        defined?(Legion::Identity::Process) && Legion::Identity::Process.resolved?
      end

      def identity_headers
        id = Legion::Identity::Process.identity_hash
        headers = {
          'x-legion-identity-canonical-name' => id[:canonical_name].to_s,
          'x-legion-identity-trust'          => id[:trust].to_s,
          'x-legion-identity-id'             => id[:id].to_s,
          'x-legion-identity-kind'           => id[:kind].to_s,
          'x-legion-identity-mode'           => id[:mode].to_s,
          'x-legion-identity-source'         => id[:source].to_s
        }
        headers['x-legion-identity-db-principal-id'] = id[:db_principal_id] if id[:db_principal_id]
        headers['x-legion-identity-db-identity-id']  = id[:db_identity_id]  if id[:db_identity_id]
        headers
      end

      def inject_identity_headers
        return unless identity_process_resolved?

        @options[:headers].merge!(identity_headers)
      rescue LoadError, StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.message.inject_identity_headers')
      end

      def inject_legion_version_header
        return unless defined?(Legion::VERSION)

        @options[:headers]['x-legion-version'] ||= Legion::VERSION.to_s
      end

      def inject_region_header
        region = begin
          Legion::Settings[:transport][:region]
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.message.inject_region_header')
          nil
        end
        return if region.nil?

        @options[:headers]['x-legion-region'] = region
        affinity = @options[:region_affinity] || 'prefer_local'
        @options[:headers]['x-legion-region-affinity'] = affinity
      end

      def inject_legion_region_header
        return unless defined?(Legion::Region) &&
                      Legion::Region.respond_to?(:current)

        default_affinity = (defined?(Legion::Settings) && Legion::Settings.dig(:region, :default_affinity)) || 'prefer_local'
        explicit_region = defined?(Legion::Settings) ? Legion::Settings.dig(:region, :current) : nil
        return if explicit_region.nil? && default_affinity == 'any'

        current_region = Legion::Region.current
        return if current_region.nil?

        @options[:headers]['region'] = current_region
        @options[:headers]['region_affinity'] = @options[:region_affinity] ||
                                                default_affinity
      end

      def spool_publish_result(result:, payload:, envelope:, declaration:, tenant_id:)
        return result unless spool_enabled?(@options) && defined?(Legion::Transport::Spool)

        persisted = Legion::Transport::Spool.write(
          **envelope, exchange: declaration[:name], payload: payload,
                      exchange_type: declaration[:type], tenant_id: tenant_id
        )
        return result unless persisted == true

        log.info "Message persisted for replay exchange=#{declaration[:name]}"
        result.merge(status: :spooled, accepted: false, exchange: declaration[:name])
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.message.spool_write')
        result.merge(status: :failed, accepted: false, error_class: e.class.name, error: e.message)
      end
    end
  end
end

Dir["#{__dir__}/messages/*.rb"].each { |file| require file }
