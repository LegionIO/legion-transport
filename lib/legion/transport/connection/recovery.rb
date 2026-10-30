# frozen_string_literal: true

require 'timeout'

module Legion
  module Transport
    module Connection
      # A forced reconnect replaces the session, unlike Bunny's automatic recovery.
      # Keep the original channels: actors retain queues, consumers and channel references.
      # Capture before teardown; restore only after the old transport and workers stop.
      class Recovery
        def self.capture(sessions:, excluded_channels: [], timeout: Legion::Transport::Connection::SHUTDOWN_TIMEOUT, **)
          Timeout.timeout(timeout) do
            new(sessions: sessions.compact.uniq, excluded_channels: excluded_channels)
          end
        end

        def initialize(sessions:, excluded_channels: [], **)
          @excluded_channels = excluded_channels
          @registered_sessions = {}
          @states = sessions.filter_map { |session| capture_session(session: session) }
          @mutex = Mutex.new
          @restored = false
        end

        def restore(session:, **)
          @mutex.synchronize do
            return true if @restored || @states.empty?
            raise IOError, 'replacement session is not open' unless session&.open?
            raise IOError, 'partially restored session must be torn down before retrying' if @attempted_session.equal?(session)

            ensure_quiescent_sources!
            @attempted_session = session
            active = @states.to_h { |state| [state, active_consumers(state: state)] }
            @states.each do |state|
              state[:channels].each { |channel| restore_channel(channel: channel, session: session) }
            end
            restore_topology(active: active)
            active.each do |state, consumers|
              consumers.each do |consumer|
                consumer.consumer_tag = state[:consumer_tags].fetch(consumer)
                consumer.channel.basic_consume_with(consumer)
                @registered_sessions[consumer] = session
              end
            end
            @restored = true
          end
        end

        private

        def capture_session(session:, **)
          # Network recovery closes channels without unregistering them. Explicit
          # Channel#close unregisters them, so retained closed channels still need recovery.
          channels = session.instance_variable_get(:@channel_mutex).synchronize do
            session.instance_variable_get(:@channels).values.reject do |channel|
              channel.number.zero? || @excluded_channels.include?(channel)
            end
          end
          return if channels.empty?

          registrations = channels.flat_map do |channel|
            channel.instance_variable_get(:@consumer_mutex).synchronize { channel.consumers.to_a }
          end
          consumers = registrations.map(&:last)
          queues = (channels.flat_map { |channel| channel.queues.values } + consumers.map(&:queue).grep(::Bunny::Queue)).uniq
          exchanges = channels.flat_map { |channel| channel.exchanges.values }.uniq
          state = { session: session, channels: channels, consumers: consumers,
                    consumer_names: consumers.to_h { |consumer| [consumer, consumer.queue_name] },
                    consumer_tags: registrations.to_h { |tag, consumer| [consumer, tag] },
                    queues: [], exchanges: [], queue_bindings: [], exchange_bindings: [] }
          if session.respond_to?(:topology_registry)
            capture_registry(state: state, registry: session.topology_registry, queues: queues, exchanges: exchanges)
          else
            capture_objects(state: state, queues: queues, exchanges: exchanges)
          end
          state
        end

        def capture_registry(state:, registry:, queues:, exchanges:, **)
          queues_by_name = queues.group_by(&:name)
          exchanges_by_name = exchanges.to_h { |exchange| [exchange.name, exchange] }
          registry.filtered_queues.each do |record|
            objects = queues_by_name[record.name] || []
            options = if objects.empty?
                        { durable: record.durable, exclusive: record.exclusive, auto_delete: record.auto_delete, arguments: record.arguments }
                      else
                        objects.first.options.dup
                      end
            state[:queues] << { name: record.name, server_named: record.server_named?, options: options, objects: objects,
                                channel: recovery_channel(state: state, channel: objects.first&.channel || record.channel) }
          end
          registry.filtered_exchanges.reject(&:predeclared?).each do |record|
            object = exchanges_by_name[record.name]
            options = if object
                        object.instance_variable_get(:@options).dup
                      else
                        { durable: record.durable, auto_delete: record.auto_delete, arguments: record.arguments }
                      end
            state[:exchanges] << { name: record.name, type: record.type, options: options,
                                   channel: recovery_channel(state: state, channel: object&.channel || record.channel) }
          end
          capture_registry_bindings(state: state, registry: registry)
        end

        def capture_registry_bindings(state:, registry:, **)
          registry.filtered_queue_bindings.each do |binding|
            state[:queue_bindings] << { queue: binding.destination, exchange: binding.source,
                                       options: { routing_key: binding.routing_key, arguments: binding.arguments },
                                       channel: recovery_channel(state: state, channel: binding.channel) }
          end
          registry.filtered_exchange_bindings.each do |binding|
            state[:exchange_bindings] << { source: binding.source, destination: binding.destination,
                                          options: { routing_key: binding.routing_key, arguments: binding.arguments },
                                          channel: recovery_channel(state: state, channel: binding.channel) }
          end
        end

        def capture_objects(state:, queues:, exchanges:, **)
          queues.group_by(&:name).each do |name, objects|
            queue = objects.first
            state[:queues] << { name: name, server_named: queue.server_named?, options: queue.options.dup,
                                objects: objects, channel: queue.channel }
            objects.each do |object|
              object.instance_variable_get(:@bindings).each do |binding|
                state[:queue_bindings] << { queue: name, exchange: binding[:exchange], channel: object.channel,
                                           options: { routing_key: binding[:routing_key], arguments: binding[:arguments] } }
              end
            end
          end
          exchanges.each do |exchange|
            unless exchange.predefined?
              state[:exchanges] << { name: exchange.name, type: exchange.type, channel: exchange.channel,
                                     options: exchange.instance_variable_get(:@options).dup }
            end
            exchange.instance_variable_get(:@bindings).each do |binding|
              source = binding[:source]
              state[:exchange_bindings] << { source: source.respond_to?(:name) ? source.name : source,
                                            destination: exchange.name, channel: exchange.channel, options: binding[:opts].dup }
            end
          end
          state[:queue_bindings].uniq!
          state[:exchange_bindings].uniq!
        end

        def recovery_channel(state:, channel:, **)
          state[:channels].include?(channel) ? channel : state[:channels].first
        end

        def active_consumers(state:, **)
          # Channel#close retains the consumer map, whereas Basic.CancelOk removes it.
          # Recheck after teardown so a cancellation after capture is not resurrected.
          state[:consumers].select do |consumer|
            tag = state[:consumer_tags].fetch(consumer)
            source = @registered_sessions.fetch(consumer, state[:session])
            registered = !source.respond_to?(:topology_registry) || source.topology_registry.consumers.key?(tag)
            registered && consumer.channel.consumers[tag].equal?(consumer)
          end
        end

        def ensure_quiescent_sources!
          channels = @states.flat_map { |state| state[:channels] }
          channels.map(&:connection).uniq.each do |source|
            reader = source.instance_variable_get(:@reader_loop)&.instance_variable_get(:@thread)
            raise IOError, 'old session transport or reader is still running' if source.transport.open? || reader&.alive?
          end
          # Bunny 3.x delivers plain integer tags. A callback from an old work pool
          # could acknowledge an unrelated new delivery if allowed to survive rebinding.
          return unless channels.any? { |channel| Array(channel.work_pool.threads).any?(&:alive?) }

          raise IOError, 'old consumer workers are still running'
        end

        def restore_channel(channel:, session:, **)
          number = session.next_channel_id
          raise IOError, 'replacement session channel limit exhausted' if number.negative?

          pool = channel.work_pool
          channel.instance_variable_set(:@connection, session)
          channel.instance_variable_set(:@logger, session.logger)
          channel.instance_variable_set(:@frame_max, session.frame_max)
          channel.id = number
          channel.instance_variable_set(:@work_pool, ::Bunny::ConsumerWorkPool.new(pool.size, pool.abort_on_exception,
                                                                                   pool.instance_variable_get(:@shutdown_timeout)))
          channel.send(:reset_continuations)
          # Bunny 2.x uses versioned delivery tags; advance before accepting deliveries.
          channel.increment_recoveries_counter if channel.respond_to?(:increment_recoveries_counter)
          channel.open
          channel.recover_prefetch_setting
          channel.recover_confirm_mode
          channel.recover_tx_mode
        end

        def restore_topology(active:, **)
          # Bunny's aggregate recovery either swallows declaration errors (2.x) or
          # replaces consumers and loses the original queue references (3.x). Use its
          # recorded topology and protocol APIs, but let every failure reach the caller.
          active.each_key do |state|
            state[:exchanges].each do |exchange|
              next if exchange[:options][:no_declare]

              exchange[:channel].exchange_declare(exchange[:name], exchange[:type], exchange[:options])
            end
          end
          names = active.to_h do |state, _consumers|
            [state, state[:queues].to_h { |queue| [queue[:name], restore_queue(queue: queue)] }]
          end
          active.each do |state, consumers|
            state[:exchange_bindings].each do |binding|
              binding[:channel].exchange_bind(binding[:source], binding[:destination], binding[:options])
            end
            state[:queue_bindings].each do |binding|
              binding[:channel].queue_bind(names[state].fetch(binding[:queue], binding[:queue]), binding[:exchange], binding[:options])
            end
            consumers.each do |consumer|
              next if consumer.queue.respond_to?(:name)

              original_name = state[:consumer_names].fetch(consumer)
              consumer.instance_variable_set(:@queue, names[state].fetch(original_name, original_name))
            end
          end
        end

        def restore_queue(queue:, **)
          name = queue[:name]
          unless queue[:options][:no_declare]
            requested_name = queue[:server_named] ? '' : name
            name = queue[:channel].queue_declare(requested_name, queue[:options]).queue
          end
          queue[:objects].each do |object|
            object.channel.deregister_queue(object)
            object.instance_variable_set(:@name, name)
            object.channel.register_queue(object)
            object.channel.record_queue(object) if object.channel.respond_to?(:record_queue)
          end
          name
        end
      end
    end
  end
end
