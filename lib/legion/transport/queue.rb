# frozen_string_literal: true

module Legion
  module Transport
    class Queue < Legion::Transport::CONNECTOR::Queue
      include Legion::Transport::Common

      def initialize(queue = queue_name, options = {})
        retries ||= 0
        @options = options
        merged = options_builder(default_options, queue_options, options)
        ensure_dlx(merged)
        super(channel, queue, merged)
      rescue Legion::Transport::CONNECTOR::PreconditionFailed
        retries.zero? ? retries = 1 : raise
        recreate_queue(queue)
        @channel = Legion::Transport::Connection.channel
        retry
      end

      def recreate_queue(queue)
        Legion::Transport.logger.warn "Queue:#{queue} exists with wrong parameters, deleting and creating"
        queue = ::Bunny::Queue.new(Legion::Transport::Connection.channel, queue, no_declare: true, passive: true)
        queue.delete
      end

      def default_options
        hash = Concurrent::Hash.new
        hash[:manual_ack] = true
        hash[:durable] = true
        hash[:exclusive] = false
        hash[:block] = false
        hash[:auto_delete] = false
        args = { 'x-queue-type': 'quorum' }
        args[:'x-dead-letter-exchange'] = dlx_exchange_name if dlx_enabled
        hash[:arguments] = args
        hash
      end

      def queue_options
        Concurrent::Hash.new
      end

      def dlx_enabled
        true
      end

      def dlx_exchange_name
        "#{self.class.ancestors.first.to_s.split('::')[2].downcase}.dlx"
      end

      def ensure_dlx(merged_options)
        dlx_name = merged_options.dig(:arguments, :'x-dead-letter-exchange')
        return if dlx_name.nil? || dlx_name.empty?

        channel.exchange_declare(dlx_name, 'fanout', durable: true, auto_delete: false)
        channel.queue_declare("#{dlx_name}.queue", durable: true, auto_delete: false,
                                                    arguments: { 'x-queue-type': 'classic' })
        channel.queue_bind("#{dlx_name}.queue", dlx_name, routing_key: '#')
      rescue StandardError => e
        Legion::Transport.logger.warn "Failed to declare DLX #{dlx_name}: #{e.message}"
      end

      def queue_name
        ancestor = self.class.ancestors.first.to_s.split('::')
        name = if ancestor[5].scan(/[A-Z]/).length > 1
                 ancestor[5].gsub!(/(.)([A-Z])/, '\1_\2').downcase!
               else
                 ancestor[5].downcase!
               end
        "#{ancestor[2].downcase}.#{name}"
      end

      def delete(options = {})
        super
        true
      rescue Legion::Transport::CONNECTOR::PreconditionFailed => e
        Legion::Logging.warn("Queue#delete precondition failed: #{e.message}") if defined?(Legion::Logging)
        false
      end

      def acknowledge(delivery_tag)
        channel.acknowledge(delivery_tag)
      end

      def reject(delivery_tag, requeue: false)
        channel.reject(delivery_tag, requeue)
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
