# frozen_string_literal: true

require 'securerandom'
require_relative 'local'

module Legion
  module Transport
    module InProcess
      class PreconditionFailed < StandardError; end
      class ChannelAlreadyClosed < StandardError; end
      class ChannelLevelException < StandardError; end

      DeliveryInfo = Struct.new(:delivery_tag, :routing_key, :exchange, keyword_init: true)

      class MessageProperties < Hash
        FIELDS = %i[content_type headers timestamp content_encoding delivery_mode priority correlation_id reply_to
                    expiration message_id type user_id app_id cluster_id persistent mandatory].freeze

        def initialize(**properties)
          super()
          update(content_type: 'application/json', headers: {}, timestamp: ::Time.now, content_encoding: nil)
          update(properties)
        end

        FIELDS.each { |field| define_method(field) { self[field] } }
      end

      class Session
        def initialize
          @open = false
          @channels = []
          @mutex = Mutex.new
        end

        def start
          @mutex.synchronize { @open = true }
          Legion::Transport::Local.setup
          self
        end

        def open?
          @mutex.synchronize { @open }
        end

        def closed?
          !open?
        end

        def close
          channels = @mutex.synchronize do
            @open = false
            @channels.shift(@channels.size)
          end
          channels.each(&:close)
          Legion::Transport::Local.release_owner(owner: self)
          true
        end

        # Bunny's channel factory contract requires these four positional defaults.
        def create_channel(_id = nil, _pool_size = 1, _abort_on_exception = false, _shutdown_timeout = 60, **) # rubocop:disable Metrics/ParameterLists, Style/OptionalBooleanParameter
          @mutex.synchronize do
            raise IOError, 'local session is closed' unless @open

            channel = Channel.new(connection: self)
            @channels << channel
            channel
          end
        end

        def unregister_channel(channel:)
          @mutex.synchronize { @channels.delete(channel) }
        end

        def on_blocked(&); end

        def on_unblocked(&); end

        def after_recovery_completed(&); end

        def after_recovery_attempts_exhausted(&); end
      end

      class Channel
        attr_reader :connection

        def initialize(connection: nil)
          @connection = connection
          @open = true
          @mutex = Mutex.new
        end

        def open?
          @mutex.synchronize { @open }
        end

        def close
          @mutex.synchronize { @open = false }
          Legion::Transport::Local.release_owner(owner: self)
          @connection&.unregister_channel(channel: self)
          true
        end

        def prefetch(count, _global: false)
          count
        end

        def basic_qos(count, _global: false)
          prefetch(count)
        end

        def exchange(name, type: :direct, **options)
          Exchange.new(self, type, name, options)
        end

        def default_exchange
          Exchange.new(self, :direct, '')
        end

        def exchange_declare(name, type, options = {})
          Exchange.new(self, type, name, options)
        end

        def exchange_declare_without_recording_topology(name, type, options = {})
          Exchange.new(self, type, name, options)
        end

        def queue_declare_without_recording_topology(name, options = {})
          Queue.new(self, name, options)
        end

        def queue_bind(queue_name, exchange_name, options = {})
          queue = Legion::Transport::Local.declare_queue(name: queue_name, owner: @connection || self)
          Legion::Transport::Local.bind(queue: queue, exchange_name: exchange_name, routing_key: options.fetch(:routing_key, ''))
        end

        def acknowledge(*); end

        def reject(*); end

        def exchange_delete(name, *)
          Legion::Transport::Local.delete_exchange(name: name)
        end

        def queue_delete(name, *)
          Legion::Transport::Local.delete_queue(name: name)
        end
      end

      class Exchange
        attr_reader :name, :type, :channel

        def initialize(channel, type, name, _opts = {})
          raise ChannelAlreadyClosed, 'local exchange channel is closed' unless channel.open?

          @channel = channel
          @type = type
          @name = name
        end

        def publish(payload, routing_key: '', **properties)
          raise ChannelAlreadyClosed, 'local exchange channel is closed' unless @channel.open?

          Legion::Transport::Local.publish(@name, routing_key, payload, exchange_type: @type, implicit_queue: false, **properties)
        end

        def delete(_options = {}, **)
          Legion::Transport::Local.delete_exchange(name: @name)
        end
      end

      class Queue
        attr_reader :name, :channel

        def initialize(channel, name, _opts = {})
          raise ChannelAlreadyClosed, 'local queue channel is closed' unless channel.open?

          @channel = channel
          @name = name
          @local_queue = Legion::Transport::Local.declare_queue(name: name, owner: channel.connection || channel)
        end

        def bind(exchange, options = {}, **kwargs)
          exchange_name = exchange.respond_to?(:name) ? exchange.name : exchange
          routing_key = kwargs.fetch(:routing_key) { options.fetch(:routing_key, '#') }
          Legion::Transport::Local.bind(queue: @local_queue, exchange_name: exchange_name, routing_key: routing_key)
          self
        end

        def unbind(exchange, options = {}, **kwargs)
          exchange_name = exchange.respond_to?(:name) ? exchange.name : exchange
          routing_key = kwargs.fetch(:routing_key) { options.fetch(:routing_key, '#') }
          Legion::Transport::Local.unbind(queue: @local_queue, exchange_name: exchange_name, routing_key: routing_key)
          self
        end

        def subscribe(manual_ack: true, _block: false, consumer_tag: nil, _on_cancellation: nil, **, &callback)
          raise ArgumentError, 'subscriber callback required' unless callback

          tag = consumer_tag || SecureRandom.uuid
          consumer = Consumer.new(@channel, self, tag, !manual_ack, false)
          consumer.register(queue: @local_queue, owner: @channel) do |message|
            delivery_info = DeliveryInfo.new(delivery_tag: SecureRandom.uuid, routing_key: message.routing_key, exchange: message.exchange)
            callback.call(delivery_info, MessageProperties.new(**message.properties), message.payload)
          end
          consumer
        end

        def acknowledge(*); end

        def reject(*); end

        def delete(_options = {}, **)
          Legion::Transport::Local.delete_queue(name: @name)
        end
      end

      class Consumer
        attr_reader :consumer_tag

        def initialize(_channel, _queue, consumer_tag, *_rest)
          @consumer_tag = consumer_tag
          @cancelled = false
        end

        def register(queue:, owner:, &callback)
          @subscription = Legion::Transport::Local.add_subscription(queue: queue, owner: owner, &callback)
          Legion::Transport::Local.deliver_pending(queue: queue)
        end

        def cancel
          Legion::Transport::Local.cancel(subscription: @subscription) if @subscription
          @cancelled = true
        end

        def cancelled?
          @subscription ? Legion::Transport::Local.cancelled?(subscription: @subscription) : @cancelled
        end
      end
    end
  end
end
