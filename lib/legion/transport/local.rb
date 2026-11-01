# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Transport
    module Local
      PendingMessage = Struct.new(:exchange, :routing_key, :payload, :properties, :delivery_tag, :redelivered, :requeued, keyword_init: true)
      QueueState = Struct.new(:name, :key, :pending, :unacked, :subscribers, :owners, :bindings, :draining, :implicit, :exchange_name,
                              keyword_init: true)
      Subscription = Struct.new(:queue, :owner, :callback, :manual_ack, :running_thread, :completed, keyword_init: true)

      @queues = {}
      @mutex = Mutex.new
      @next_delivery_tag = 0

      class << self
        include Legion::Logging::Helper

        def setup
          log.info 'Legion::Transport::Local initialized (in-memory mode)'
        end

        # Direct Local callers can buffer before subscribing, scoped to exchange
        # and routing key. Broker-facing InProcess exchanges require declared queues.
        def publish(exchange_name, routing_key, payload, **properties)
          exchange_type = properties.delete(:exchange_type) { 'topic' }
          implicit_queue = properties.delete(:implicit_queue) { true }
          message = PendingMessage.new(exchange: exchange_name, routing_key: routing_key, payload: payload, properties: properties)
          queues = @mutex.synchronize do
            matches = @queues.values.select do |queue|
              next false if queue.implicit && !implicit_queue

              routes?(queue: queue, exchange_name: exchange_name, routing_key: routing_key, exchange_type: exchange_type)
            end
            matches << implicit_queue_state(name: routing_key, exchange_name: exchange_name) if matches.empty? && implicit_queue
            matches.each { |queue| queue.pending << message }
            matches
          end
          queues.each { |queue| deliver_pending(queue: queue) }
          { published: true, routed: !queues.empty?, routing_key: routing_key }
        end

        def subscribe(queue_name, exchange_name: '', **, &block)
          raise ArgumentError, 'subscriber callback required' unless block

          queue = @mutex.synchronize { implicit_queue_state(name: queue_name, exchange_name: exchange_name) }
          subscription = add_subscription(queue: queue) { |message| block.call(message.payload) }
          deliver_pending(queue: queue)
          { subscribed: true, queue: queue_name, subscription: subscription }
        end

        def declare_queue(name:, owner:, **)
          @mutex.synchronize do
            raise IOError, 'local queue owner is closed' unless owner.open?

            queue = (@queues[[false, name]] ||= new_queue(name: name))
            queue.owners << owner unless queue.owners.include?(owner)
            queue
          end
        end

        def bind(queue:, exchange_name:, routing_key:, **)
          @mutex.synchronize do
            ensure_queue!(queue: queue)
            binding = [exchange_name, routing_key]
            queue.bindings << binding unless queue.bindings.include?(binding)
          end
        end

        def unbind(queue:, exchange_name:, routing_key:, **)
          @mutex.synchronize do
            ensure_queue!(queue: queue)
            queue.bindings.delete([exchange_name, routing_key])
          end
        end

        def add_subscription(queue:, owner: nil, manual_ack: false, **, &callback)
          raise ArgumentError, 'subscriber callback required' unless callback

          @mutex.synchronize do
            ensure_queue!(queue: queue)
            raise IOError, 'local consumer channel is closed' if owner && !owner.open?

            subscription = Subscription.new(queue: queue, owner: owner, callback: callback, manual_ack: manual_ack,
                                            completed: ConditionVariable.new)
            queue.subscribers << subscription
            subscription
          end
        end

        def cancel(subscription:, **)
          @mutex.synchronize do
            unregister(subscription: subscription)
            await_completion(subscription: subscription)
            requeue_unacked(subscription: subscription)
          end
          true
        end

        def cancelled?(subscription:, **)
          @mutex.synchronize { subscription.callback.nil? }
        end

        def release_owner(owner:, **)
          @mutex.synchronize do
            subscriptions = []
            @queues.delete_if do |_key, queue|
              queue.owners.delete(owner)
              removed = !queue.implicit && queue.owners.empty?
              subscriptions.concat(queue.subscribers.select { |subscriber| removed || subscriber.owner.equal?(owner) })
              queue.pending.clear if removed
              removed
            end
            cancel_subscriptions(subscriptions: subscriptions)
          end
          true
        end

        def delete_queue(name:, **)
          @mutex.synchronize do
            queue = @queues.delete([false, name])
            return true unless queue

            queue.pending.clear
            cancel_subscriptions(subscriptions: queue.subscribers.dup)
          end
          true
        end

        def delete_exchange(name:, **)
          @mutex.synchronize do
            @queues.each_value { |queue| queue.bindings.reject! { |exchange, _key| exchange == name } }
          end
          true
        end

        def queue_depth(queue_name)
          @mutex.synchronize { @queues.values.sum { |queue| queue.name == queue_name ? queue.pending.size : 0 } }
        end

        def settle(owner:, delivery_tag:, multiple: false, requeue: false, **)
          queues = @mutex.synchronize do
            matched = @queues.values.reject do |queue|
              entries = queue.unacked.select do |tag, (subscription, _message)|
                subscription.owner.equal?(owner) && (tag == delivery_tag || (multiple && (delivery_tag.zero? || tag <= delivery_tag)))
              end
              entries.each do |tag, (_subscription, message)|
                queue.unacked.delete(tag)
                requeue_message(queue: queue, message: message) if requeue
              end
              entries.empty?
            end
            raise ArgumentError, "Unknown local delivery tag #{delivery_tag}" if matched.empty?

            matched
          end
          queues.each { |queue| deliver_pending(queue: queue) } if requeue
          true
        end

        def deliver_pending(queue:, **)
          acquired = @mutex.synchronize do
            next false if queue.draining || queue.pending.empty? || queue.subscribers.empty?

            queue.draining = Thread.current
            true
          end
          return unless acquired

          loop do
            delivery = @mutex.synchronize do
              if queue.pending.empty? || queue.subscribers.empty?
                queue.draining = nil
                next
              end

              subscription = queue.subscribers.shift
              queue.subscribers << subscription
              subscription.running_thread = Thread.current
              message = queue.pending.shift.dup
              message.delivery_tag = (@next_delivery_tag += 1)
              message.requeued = false
              queue.unacked[message.delivery_tag] = [subscription, message] if subscription.manual_ack
              [subscription, subscription.callback, message]
            end
            break unless delivery

            break unless deliver(queue: queue, subscription: delivery[0], callback: delivery[1], message: delivery[2])
          end
        ensure
          @mutex.synchronize { queue.draining = nil if queue.draining.equal?(Thread.current) } if acquired
        end

        def reset!
          @mutex.synchronize do
            queues = @queues.values
            @queues.clear
            queues.each { |queue| queue.pending.clear }
            cancel_subscriptions(subscriptions: queues.flat_map(&:subscribers))
          end
          log.info 'Legion::Transport::Local shut down (queues cleared)'
        end

        def active?
          true
        end

        private

        def new_queue(name:, implicit: false, exchange_name: nil, **)
          key = implicit ? [true, exchange_name, name] : [false, name]
          QueueState.new(name: name, key: key, pending: [], unacked: {}, subscribers: [], owners: [], bindings: [],
                         implicit: implicit, exchange_name: exchange_name)
        end

        def implicit_queue_state(name:, exchange_name:, **)
          @queues[[true, exchange_name, name]] ||= new_queue(name: name, implicit: true, exchange_name: exchange_name)
        end

        def ensure_queue!(queue:, **)
          return if @queues[queue.key].equal?(queue)

          raise IOError, 'local queue has been deleted'
        end

        def unregister(subscription:, **)
          subscription.callback = nil
          subscription.queue.subscribers.delete(subscription)
        end

        def await_completion(subscription:, **)
          subscription.completed.wait(@mutex) while subscription.running_thread && !subscription.running_thread.equal?(Thread.current)
        end

        def cancel_subscriptions(subscriptions:, **)
          subscriptions.each do |subscription|
            unregister(subscription: subscription)
            await_completion(subscription: subscription)
            requeue_unacked(subscription: subscription)
          end
        end

        def deliver(queue:, subscription:, callback:, message:, **)
          callback.call(message)
          !message.requeued
        rescue StandardError
          @mutex.synchronize do
            outstanding = queue.unacked.delete(message.delivery_tag)
            requeue_message(queue: queue, message: message) if !subscription.manual_ack || outstanding
          end
          raise
        ensure
          @mutex.synchronize do
            subscription.running_thread = nil
            subscription.completed.broadcast
          end
        end

        def requeue_unacked(subscription:, **)
          queue = subscription.queue
          entries = queue.unacked.select { |_tag, (subscriber, _message)| subscriber.equal?(subscription) }
          entries.reverse_each do |tag, (_subscriber, message)|
            queue.unacked.delete(tag)
            requeue_message(queue: queue, message: message)
          end
        end

        def requeue_message(queue:, message:, **)
          return unless @queues[queue.key].equal?(queue)

          message.redelivered = true
          message.requeued = true
          queue.pending.unshift(message)
        end

        def routes?(queue:, exchange_name:, routing_key:, exchange_type:, **)
          return queue.exchange_name == exchange_name && queue.name == routing_key if queue.implicit
          return queue.name == routing_key if exchange_name.empty?

          queue.bindings.any? do |exchange, pattern|
            next false unless exchange == exchange_name

            case exchange_type.to_s
            when 'fanout' then true
            when 'topic' then topic_match?(pattern: pattern, routing_key: routing_key)
            else pattern == routing_key
            end
          end
        end

        def topic_match?(pattern:, routing_key:, **)
          words = routing_key.empty? ? [] : routing_key.split('.', -1)
          matched = [true] + Array.new(words.size, false)
          (pattern.empty? ? [] : pattern.split('.', -1)).each do |word|
            previous = matched
            matched = Array.new(words.size + 1, false)
            if word == '#'
              matched[0] = previous[0]
              words.each_index { |index| matched[index + 1] = previous[index + 1] || matched[index] }
            else
              words.each_index do |index|
                matched[index + 1] = previous[index] && (word == '*' || word == words[index])
              end
            end
          end
          matched.last
        end
      end
    end
  end
end
