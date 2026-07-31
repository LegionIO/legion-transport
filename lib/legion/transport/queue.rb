# frozen_string_literal: true

module Legion
  module Transport
    class Queue < Legion::Transport::CONNECTOR::Queue
      include Legion::Transport::Common

      def initialize(queue = queue_name, options = {})
        retries ||= 0
        @queue_name_arg = queue
        @options = options
        merged = options_builder(default_options, queue_options, options)
        ensure_dlx(merged)
        super(channel, queue, merged)
      rescue Legion::Transport::CONNECTOR::PreconditionFailed => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.initialize', queue: queue)
        identity_resolved = defined?(Legion::Identity::Process) && Legion::Identity::Process.resolved?
        raise if credential_scoping_enabled? && (bootstrap_phase? || (!topology_mode? && identity_resolved && !own_queue?))

        retries.zero? ? retries = 1 : raise
        recreate_queue(queue)
        safely_close_channel(@channel)
        @channel = Legion::Transport::Connection.channel
        retry
      end

      def recreate_queue(queue)
        log.warn "Queue:#{queue} exists with wrong parameters, deleting and creating"
        tmp_channel = Legion::Transport::Connection.channel
        tmp_queue = ::Bunny::Queue.new(tmp_channel, queue, no_declare: true, passive: true)
        tmp_queue.delete
      ensure
        safely_close_channel(tmp_channel)
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

        @queue_name_arg.to_s.start_with?(prefix)
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

      def ensure_dlx(merged_options)
        return if credential_scoping_enabled? && (bootstrap_phase? || !topology_mode?)

        dlx_name = merged_options.dig(:arguments, :'x-dead-letter-exchange')
        return if dlx_name.nil? || dlx_name.empty?

        session = Legion::Transport::Connection.session
        return unless session&.open?

        dlx_ch = nil
        dlx_ch = session.create_channel
        declare_dlx(dlx_name, dlx_ch)
      rescue Legion::Transport::CONNECTOR::PreconditionFailed => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.ensure_dlx', dlx: dlx_name)
        recreate_dlx(dlx_name)
      rescue Legion::Transport::CONNECTOR::ChannelAlreadyClosed => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.ensure_dlx',
                         dlx: dlx_name, detail: 'channel closed during DLX declaration')
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.ensure_dlx', dlx: dlx_name)
      ensure
        dlx_ch&.close if dlx_ch&.open?
      end

      def declare_dlx(dlx_name, dlx_channel)
        dlx_channel.exchange_declare_without_recording_topology(dlx_name, 'fanout', durable: true, auto_delete: false)
        dlx_channel.queue_declare_without_recording_topology("#{dlx_name}.queue", durable: true, auto_delete: false,
                                                                                  arguments: { 'x-queue-type': 'classic' })
        dlx_channel.queue_bind("#{dlx_name}.queue", dlx_name, routing_key: '#')
      end

      def recreate_dlx(dlx_name)
        log.warn "DLX #{dlx_name} exists with wrong parameters, deleting and recreating"
        ch = Legion::Transport::Connection.session.create_channel
        ch.exchange_delete(dlx_name)
        ch.queue_delete("#{dlx_name}.queue")
        ch.close
        ch = Legion::Transport::Connection.session.create_channel
        declare_dlx(dlx_name, ch)
      rescue Legion::Transport::CONNECTOR::ChannelAlreadyClosed => e
        handle_exception(e, level: :error, handled: true, operation: 'transport.queue.recreate_dlx',
                         dlx: dlx_name, detail: 'session channel unavailable during DLX recreation')
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.queue.recreate_dlx', dlx: dlx_name)
      ensure
        ch&.close if ch&.open?
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
