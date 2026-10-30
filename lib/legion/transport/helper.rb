# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'publisher'
require_relative 'tenant_quota'

module Legion
  module Transport
    module Helper
      include Legion::Logging::Helper

      # --- TTL Resolution ---
      # Override in your LEX to set a custom default message TTL for the extension.
      # Resolution chain: per-call :ttl option -> LEX override -> Settings -> nil (no expiration)
      def transport_default_ttl
        Legion::Settings.dig(:transport, :messages, :ttl)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :transport_default_ttl)
        nil
      end

      # --- Namespace / Wiring ---

      def transport_path
        @transport_path ||= "#{full_path}/transport"
      end

      def transport_class
        @transport_class ||= lex_class::Transport
      end

      def messages
        @messages ||= transport_class::Messages
      end

      def queues
        @queues ||= transport_class::Queues
      end

      def exchanges
        @exchanges ||= transport_class::Exchanges
      end

      def default_exchange
        @default_exchange ||= build_default_exchange
      end

      def build_default_exchange
        return transport_class::Exchanges.const_get(lex_const, false) if transport_class::Exchanges.const_defined?(lex_const, false)

        amqp = amqp_prefix
        transport_class::Exchanges.const_set(lex_const, Class.new(Legion::Transport::Exchange) do
          define_method(:exchange_name) { amqp }
        end)
        @default_exchange = transport_class::Exchanges.const_get(lex_const, false)
      end

      # --- Status ---

      def transport_connected?
        !!Legion::Settings.dig(:transport, :connected)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :transport_connected)
        false
      end

      def transport_session_open?
        Legion::Transport::Connection.session_open?
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :transport_session_open)
        false
      end

      def transport_channel_open?
        Legion::Transport::Connection.channel_open?
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :transport_channel_open)
        false
      end

      def transport_lite_mode?
        Legion::Transport::Connection.lite_mode?
      end

      # --- Resource Info ---

      def transport_channel
        Legion::Transport::Connection.channel
      end

      def transport_spool_count
        Legion::Transport::Spool.count
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :transport_spool_count)
        0
      end

      # --- Publish Convenience ---

      def transport_publish(routing_key:, payload: {}, **opts)
        structured = opts.delete(:return_result) == true || opts[:publisher_confirm] == true || opts[:mandatory] == true
        return structured ? { status: :failed, accepted: false, error: 'Transport is disconnected' } : false unless transport_connected?

        if opts.key?(:ttl)
          ttl = opts.delete(:ttl)
          opts[:expiration] = ttl.to_s if ttl
        elsif !opts.key?(:expiration)
          ttl = transport_default_ttl
          opts[:expiration] = ttl.to_s if ttl
        end
        opts[:persistent] = Legion::Settings.dig(:transport, :messages, :persistent) unless opts.key?(:persistent)
        encoded = transport_encode_payload(payload: payload, options: opts)
        tenant_id = Legion::Transport::TenantTopology.resolve_tenant_id(tenant_id: opts.delete(:tenant_id))
        declaration = default_exchange.declaration(tenant_id: tenant_id)
        publisher_confirm = opts.delete(:publisher_confirm) == true
        mandatory = opts.delete(:mandatory) == true
        confirm_timeout_ms = opts.delete(:publish_confirm_timeout_ms) || 5000
        exchange = default_exchange.cached_instance(name: declaration[:name], tenant_id: tenant_id) ||
                   default_exchange.new(declaration[:name], tenant_id: tenant_id)
        Legion::Transport::TenantQuota.check_publish(tenant_id, message_size: encoded.bytesize)
        result = Legion::Transport::Publisher.publish(
          exchange: exchange, payload: encoded, envelope: opts.merge(routing_key: routing_key),
          publisher_confirm: publisher_confirm, mandatory: mandatory, confirm_timeout_ms: confirm_timeout_ms
        )
        structured ? result : result[:accepted]
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :transport_publish, routing_key: routing_key)
        structured ? { status: :failed, accepted: false, error_class: e.class.name, error: e.message } : false
      end

      private

      def transport_encode_payload(payload:, options:, **)
        encoded = payload.is_a?(String) ? payload : Legion::JSON.dump(payload)
        encrypt = options.key?(:encrypt) ? options.delete(:encrypt) : Legion::Settings.dig(:transport, :messages, :encrypt)
        return encoded unless encrypt

        unless defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:encrypt) && Legion::Settings.dig(:crypt, :cs_encrypt_ready) == true
          raise Legion::Transport::EncryptionNotReady, 'Message encryption requires a ready cluster secret'
        end

        timeout = Legion::Settings.dig(:crypt, :cluster_secret_timeout) || 5
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
          raise Legion::Transport::EncryptionNotReady, 'Cluster secret readiness timeout must be finite and positive'
        end

        encrypted = Timeout.timeout(timeout, Legion::Transport::EncryptionNotReady, 'Cluster secret encryption timed out') do
          Legion::Crypt.encrypt(encoded)
        end
        options[:headers] = (options[:headers] || {}).merge(iv: encrypted[:iv])
        options[:content_encoding] = 'encrypted/cs'
        encrypted[:enciphered_message]
      end
    end
  end
end
