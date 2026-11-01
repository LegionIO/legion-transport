# frozen_string_literal: true

require 'securerandom'
require 'timeout'
require 'legion/logging/helper'
require_relative 'settings'
require_relative 'errors'

module Legion
  module Transport
    module Publisher
      extend Legion::Logging::Helper
      extend Legion::Transport::Settings::Helper

      RETURN_TOKEN_HEADER = 'x-legion-publish-attempt'
      class ConfirmTimeout < Timeout::Error; end

      @channel_mutex = Mutex.new

      class << self
        def publish!(exchange:, payload:, envelope:, **options)
          policy = transport_task_publication_settings.merge(options)
          result = publish(exchange: exchange, payload: payload, envelope: envelope,
                           publisher_confirm: policy.fetch(:publisher_confirm), mandatory: policy.fetch(:mandatory),
                           confirm_timeout_ms: policy.fetch(:confirm_timeout_ms) { policy.fetch(:publish_confirm_timeout_ms) })
          return result if result[:accepted] == true && result[:status] == :accepted

          raise Legion::Transport::PublishRejected.new(result: result)
        end

        def publish(exchange:, payload:, envelope:, publisher_confirm: false, mandatory: false,
                    confirm_timeout_ms: transport_task_publication_settings.fetch(:publish_confirm_timeout_ms), **)
          mandatory ||= envelope[:mandatory] == true
          envelope = envelope.merge(mandatory: true) if mandatory
          if defined?(Legion::Transport::InProcess::Exchange) && exchange.is_a?(Legion::Transport::InProcess::Exchange)
            local = exchange.publish(payload, **envelope)
            status = mandatory && local[:routed] != true ? :unroutable : :accepted
            return publish_result(exchange: exchange, envelope: envelope, status: status)
          end

          channel = exchange.channel
          mutex = @channel_mutex.synchronize do
            channel.instance_variable_get(:@legion_publish_mutex) ||
              channel.instance_variable_set(:@legion_publish_mutex, Mutex.new)
          end
          mutex.synchronize do
            raise IOError, 'Publisher channel was retired after a confirm timeout' if channel.instance_variable_get(:@legion_publish_retired)

            reliable = publisher_confirm || mandatory || channel.using_publisher_confirmations?
            timeout = confirm_timeout_ms.to_f / 1000.0
            raise ArgumentError, 'confirm_timeout_ms must be finite and positive' if reliable && (!timeout.finite? || !timeout.positive?)

            publish_on_channel(exchange: exchange, payload: payload, envelope: envelope, reliable: reliable, timeout: timeout)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.publisher.publish')
          publish_result(exchange: exchange, envelope: envelope, status: :failed).merge(error_class: e.class.name, error: e.message)
        end

        def channel_usable?(channel:, **)
          !channel.nil? && channel.open? && !channel.instance_variable_get(:@legion_publish_retired)
        end

        private

        def publish_on_channel(exchange:, payload:, envelope:, reliable:, timeout:, **)
          channel = exchange.channel
          returned = {}
          outgoing = envelope
          outgoing = return_envelope(exchange: exchange, envelope: envelope, returned: returned) if envelope[:mandatory]
          if reliable
            unless channel.respond_to?(:confirm_select) && channel.respond_to?(:wait_for_confirms)
              raise IOError, 'Publisher confirms are not supported by this channel'
            end

            channel.confirm_select unless channel.using_publisher_confirmations?
          end
          exchange.publish(payload, **outgoing)
          status = reliable ? wait_for_confirmation(channel: channel, timeout: timeout) : :accepted
          status = :unroutable if returned[:returned]
          publish_result(exchange: exchange, envelope: envelope, status: status).merge(returned.except(:returned))
        end

        def return_envelope(exchange:, envelope:, returned:, **)
          token = SecureRandom.uuid
          exchange.on_return do |return_info, properties, _content|
            headers = properties.respond_to?(:headers) ? properties.headers : properties[:headers]
            next unless headers && (headers[RETURN_TOKEN_HEADER] || headers[RETURN_TOKEN_HEADER.to_sym]) == token

            returned[:return_reply_code] = return_info.reply_code
            returned[:return_reply_text] = return_info.reply_text
            returned[:returned] = true
          end
          envelope.merge(mandatory: true, headers: (envelope[:headers] || {}).merge(RETURN_TOKEN_HEADER => token))
        end

        def wait_for_confirmation(channel:, timeout:, **)
          confirmed = Timeout.timeout(timeout, ConfirmTimeout) { channel.wait_for_confirms }
          confirmed == true ? :accepted : :nacked
        rescue Timeout::Error => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.publisher.confirm_timeout')
          # A late ack/nack belongs to the timed-out attempt. Never reuse its
          # outstanding-confirm state for a subsequent publication.
          channel.instance_variable_set(:@legion_publish_retired, true)
          close_timed_out_channel(channel: channel, timeout: timeout)
          :confirm_timeout
        end

        def close_timed_out_channel(channel:, timeout:, **)
          Timeout.timeout(timeout, ConfirmTimeout) { channel.close if channel.open? }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.publisher.close_timed_out_channel')
        end

        def publish_result(exchange:, envelope:, status:, **)
          {
            status:         status,
            accepted:       status == :accepted,
            exchange:       exchange.name,
            routing_key:    envelope[:routing_key] || '',
            message_id:     envelope[:message_id],
            correlation_id: envelope[:correlation_id]
          }.compact
        end
      end
    end
  end
end
