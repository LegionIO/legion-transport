# frozen_string_literal: true

require_relative 'tenant_topology'
require_relative 'tenant_migration'

module Legion
  module Transport
    class Queue < Legion::Transport::CONNECTOR::Queue
      include Legion::Transport::Common

      attr_reader :tenant_id

      def initialize(queue = nil, options = {}, **kwargs)
        options = options.merge(kwargs) unless kwargs.empty?
        @options = options.dup
        @explicit_channel = @options.delete(:channel)
        @channel = @explicit_channel if @explicit_channel
        @tenant_id = Legion::Transport::TenantTopology.resolve_tenant_id(tenant_id: @options.delete(:tenant_id))
        @queue_name_arg = queue || queue_name
        name = Legion::Transport::TenantTopology.queue_name(@queue_name_arg, tenant_id: @tenant_id)
        merged = options_builder(default_options, queue_options, @options)
        merged[:arguments] = (merged[:arguments] || {}).to_h { |key, value| [key.to_sym, value] }
        dlx_name = merged[:arguments][:'x-dead-letter-exchange']
        if dlx_name
          merged[:arguments][:'x-dead-letter-exchange'] =
            Legion::Transport::TenantTopology.exchange_name(dlx_name, tenant_id: @tenant_id)
        else
          merged[:arguments].delete(:'x-dead-letter-exchange')
        end
        ensure_dlx(merged_options: merged)
        result = super(channel, name, merged)
        Legion::Transport::TenantMigration.register_queue(tenant_id: @tenant_id, name: @queue_name_arg,
                                                          options: merged, source_dlx: dlx_name)
        result
      rescue Legion::Transport::CONNECTOR::PreconditionFailed => e
        handle_exception(e, level: :warn, handled: false, operation: 'transport.queue.initialize', queue: name,
                         detail: 'Declaration failed; existing queue and messages were preserved. Reconcile broker options explicitly.')
        safely_close_channel(@channel) unless @explicit_channel
        raise
      end

      def bind(exchange, options = {})
        name = exchange.respond_to?(:name) ? exchange.name : exchange
        scoped_name = Legion::Transport::TenantTopology.exchange_name(name, tenant_id: @tenant_id)
        result = super(scoped_name, options)
        declaration = channel.exchanges[scoped_name] if channel.respond_to?(:exchanges)
        Legion::Transport::TenantMigration.register_binding(tenant_id: @tenant_id, name: @queue_name_arg,
                                                            exchange: declaration || exchange, options: options)
        result
      end

      def unbind(exchange, options = {})
        name = exchange.respond_to?(:name) ? exchange.name : exchange
        result = super(Legion::Transport::TenantTopology.exchange_name(name, tenant_id: @tenant_id), options)
        Legion::Transport::TenantMigration.register_binding(tenant_id: @tenant_id, name: @queue_name_arg,
                                                            exchange: exchange, options: options, remove: true)
        result
      end

      def default_options
        hash = Concurrent::Hash.new
        hash[:manual_ack] = true
        hash[:durable] = true
        hash[:exclusive] = false
        hash[:block] = false
        hash[:auto_delete] = false
        is_passive = passive?
        hash[:passive] = is_passive
        if is_passive
          hash[:arguments] = {}
        else
          args = { 'x-queue-type': 'quorum' }
          args[:'x-dead-letter-exchange'] = dlx_exchange_name if dlx_enabled
          hash[:arguments] = args
        end
        hash
      end

      def passive?
        return false unless credential_scoping_enabled?
        return false unless defined?(Legion::Identity::Process)
        return true  if bootstrap_phase?
        return false if topology_mode?
        return false if own_queue?

        true
      end

      def own_queue?
        return false unless defined?(Legion::Identity::Process) && Legion::Identity::Process.resolved?

        prefix = Legion::Identity::Process.queue_prefix
        return false if prefix.nil? || prefix.empty?

        @queue_name_arg.to_s.start_with?(prefix) ||
          @queue_name_arg.to_s.start_with?(Legion::Transport::TenantTopology.queue_name(prefix, tenant_id: @tenant_id))
      end

      def queue_options
        Concurrent::Hash.new
      end

      def dlx_enabled
        true
      end

      def dlx_exchange_name
        "#{derive_segments.join('.')}.dlx"
      end

      def ensure_dlx(merged_options:, **)
        return if merged_options[:passive] || merged_options[:no_declare]
        return if credential_scoping_enabled? && (bootstrap_phase? || !topology_mode?)

        arguments = merged_options[:arguments] || {}
        dlx_name = arguments[:'x-dead-letter-exchange'] || arguments['x-dead-letter-exchange']
        return if dlx_name.nil? || dlx_name.empty?

        session = if @explicit_channel.respond_to?(:connection)
                    @explicit_channel.connection
                  else
                    Legion::Transport::Connection.session
                  end
        raise IOError, "Cannot provision required DLX #{dlx_name}: transport session is not open" unless session&.open?

        dlx_ch = session.create_channel
        declare_dlx(dlx_name, dlx_ch)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: 'transport.queue.ensure_dlx', dlx: dlx_name,
                         detail: 'Required dead-letter topology is unavailable; source queue was not declared.')
        raise
      ensure
        safely_close_channel(dlx_ch)
      end

      def declare_dlx(dlx_name, dlx_channel)
        dlx_channel.exchange_declare_without_recording_topology(dlx_name, 'fanout', durable: true, auto_delete: false)
        dlx_channel.queue_declare_without_recording_topology("#{dlx_name}.queue", durable: true, auto_delete: false,
                                                                                  arguments: { 'x-queue-type': 'classic' })
        dlx_channel.queue_bind("#{dlx_name}.queue", dlx_name, routing_key: '#')
      end

      def queue_name
        "#{derive_segments.join('.')}.#{derive_leaf}"
      end

      def delete(options = {})
        super
        true
      rescue Legion::Transport::CONNECTOR::PreconditionFailed => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.delete')
        false
      end

      def acknowledge(delivery_tag)
        channel.acknowledge(delivery_tag)
      end

      def reject(delivery_tag, requeue: false)
        channel.reject(delivery_tag, requeue)
      end

      def nack_or_dlq(delivery_tag, retry_count: 0, threshold: 2)
        if retry_count < threshold
          reject(delivery_tag, requeue: true)
        else
          reject(delivery_tag, requeue: false)
        end
      end

      private

      def credential_scoping_enabled?
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

      def safely_close_channel(tmp_channel)
        tmp_channel&.close if tmp_channel&.open?
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.close_channel')
      end
    end
  end
end

require_relative 'queues/node'
require_relative 'queues/node_status'
require_relative 'queues/task_log'
require_relative 'queues/task_update'
require_relative 'queues/agent'
require_relative 'queues/region_outbound'
