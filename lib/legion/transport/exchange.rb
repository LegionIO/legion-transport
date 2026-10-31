# frozen_string_literal: true

require_relative 'tenant_topology'
require_relative 'publisher'

module Legion
  module Transport
    class Exchange < Legion::Transport::CONNECTOR::Exchange
      include Legion::Transport::Common

      # Cache only exchanges declared for the same tenant, options and channel context.
      @instance_cache = Concurrent::ThreadLocalVar.new { {} }

      class << self
        def instance_cache
          Legion::Transport::Exchange.instance_variable_get(:@instance_cache)
        end

        def declaration(name: nil, options: {}, tenant_id: nil, **)
          instance = allocate
          instance.send(:prepare_declaration, name: name, options: options, tenant_id: tenant_id)
          { name: instance.instance_variable_get(:@declaration_name), type: instance.instance_variable_get(:@type) }
        end

        def cached_instance(name: nil, options: {}, tenant_id: nil, **)
          instance = allocate
          instance.send(:prepare_declaration, name: name, options: options, tenant_id: tenant_id)
          key = instance.instance_variable_get(:@cache_key)
          cache = instance_cache.value
          cached = cache[key]
          return cached if cached && Legion::Transport::Publisher.channel_usable?(channel: cached.channel)

          cache.delete(key)
          nil
        end

        def clear_cache
          instance_cache.value.clear
        end
      end

      attr_reader :tenant_id

      def initialize(exchange = nil, options = {}, **kwargs)
        options = options.merge(kwargs) unless kwargs.empty?
        prepare_declaration(name: exchange, options: options, tenant_id: options[:tenant_id])
        super(channel, @type, @declaration_name, @declaration_options)
        self.class.instance_cache.value[@cache_key] = self
      rescue Legion::Transport::CONNECTOR::PreconditionFailed, Legion::Transport::CONNECTOR::ChannelAlreadyClosed => e
        handle_exception(e, level: :warn, handled: false, operation: 'transport.exchange.initialize',
                         exchange: @declaration_name,
                         detail: 'Declaration failed; existing exchange and bindings were preserved. Reconcile broker options explicitly.')
        safely_close_channel(@channel) unless @explicit_channel
        raise
      end

      def bind(source, options = {})
        name = source.respond_to?(:name) ? source.name : source
        super(Legion::Transport::TenantTopology.exchange_name(name, tenant_id: @tenant_id), options)
      end

      def unbind(source, options = {})
        name = source.respond_to?(:name) ? source.name : source
        super(Legion::Transport::TenantTopology.exchange_name(name, tenant_id: @tenant_id), options)
      end

      def default_options
        hash = Concurrent::Hash.new
        hash[:durable] = true
        hash[:auto_delete] = false
        hash[:arguments] = {}
        hash[:passive] = passive?
        hash
      end

      def passive?
        return false unless credential_scoping_enabled?
        return false unless defined?(Legion::Identity::Process)
        return true  if bootstrap_phase?
        return false if topology_mode?

        true
      end

      def exchange_name
        derive_segments.join('.')
      end

      def exchange_options
        Concurrent::Hash.new
      end

      def delete(options = {})
        super
        true
      rescue Legion::Transport::CONNECTOR::PreconditionFailed => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.exchange.delete')
        false
      end

      def default_type
        'topic'
      end

      def channel
        @channel ||= @explicit_channel || Legion::Transport::Connection.channel
      rescue Legion::Transport::CONNECTOR::ChannelLevelException => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.exchange.channel')
        # Prefer closing the channel from the exception (available even when @channel is nil
        # because the exception was raised before assignment completed).
        error_channel = e.respond_to?(:channel) ? e.channel : @channel
        safely_close_channel(error_channel)
        @channel = Legion::Transport::Connection.channel
        raise e unless @channel.open?

        @channel
      end

      private

      def prepare_declaration(name:, options:, tenant_id:, **)
        @options = options.dup
        @explicit_channel = @options.delete(:channel)
        @options.delete(:tenant_id)
        @tenant_id = Legion::Transport::TenantTopology.resolve_tenant_id(tenant_id: tenant_id || options[:tenant_id])
        @declaration_name = Legion::Transport::TenantTopology.exchange_name(name || exchange_name, tenant_id: @tenant_id)
        @declaration_options = options_builder(default_options, exchange_options, @options)
        @type = @declaration_options[:type] || default_type
        @cache_key = [self.class, @tenant_id, @declaration_name, @type,
                      declaration_snapshot(value: @declaration_options), @explicit_channel].freeze
      end

      def declaration_snapshot(value:, **)
        case value
        when Hash
          value.to_h { |key, item| [key, declaration_snapshot(value: item)] }.freeze
        when Array
          value.map { |item| declaration_snapshot(value: item) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      def credential_scoping_enabled?
        return false unless defined?(Legion::Settings)

        Legion::Settings.dig(:crypt, :vault, :dynamic_rmq_creds) == true
      end

      def bootstrap_phase?
        return false unless defined?(Legion::Identity::Process)

        !Legion::Identity::Process.resolved? && credential_scoping_enabled?
      end

      def topology_mode?
        return true unless defined?(Legion::Mode)

        Legion::Mode.infra? || (Legion::Mode.respond_to?(:worker?) && Legion::Mode.worker?)
      end

      def safely_close_channel(error_channel)
        error_channel&.close if error_channel&.open?
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.exchange.close_channel')
      end
    end
  end
end
