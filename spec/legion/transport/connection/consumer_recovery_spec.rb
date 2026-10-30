# frozen_string_literal: true

require 'spec_helper'
require 'bunny'
require 'securerandom'
require 'timeout'
require 'legion/transport/connection/recovery'

RSpec.describe Legion::Transport::Connection::Recovery, rabbitmq: true do
  before do
    @sessions = []
    @queues = []
    @exchanges = []
    @deliveries = Queue.new
    @original = recovery_session
  end

  after do
    @sessions.each { |session| disconnect_recovery_session(session: session) }
    cleanup = Bunny.new(ENV.fetch('RABBITMQ_URL', 'amqp://guest:guest@127.0.0.1:5672'), automatically_recover: false).start
    begin
      channel = cleanup.create_channel
      @queues.each { |name| channel.queue_delete(name) }
      @exchanges.reverse_each { |name| channel.exchange_delete(name) }
    ensure
      cleanup.close
    end
  end

  def recovery_session
    Bunny.new(ENV.fetch('RABBITMQ_URL', 'amqp://guest:guest@127.0.0.1:5672'), automatically_recover: false).start.tap do |session|
      @sessions << session
    end
  end

  def recovery_name(kind:)
    name = "legion.consumer-recovery.#{SecureRandom.uuid}"
    (kind == :queue ? @queues : @exchanges) << name
    name
  end

  def disconnect_recovery_session(session:, stop_workers: true)
    channels = session.instance_variable_get(:@channels).values.dup
    session.close if session.open?
    return unless stop_workers

    channels.each do |channel|
      pool = channel.work_pool
      pool.kill
      Array(pool.threads).each { |thread| thread.join(2) }
    end
  end

  def recovery_consumer(queue:, label: 'active', tag: SecureRandom.uuid)
    consumer = Bunny::Consumer.new(queue.channel, queue, tag, false, false, 'x-priority' => 3)
    consumer.on_delivery { |info, _properties, payload| @deliveries << [label, info, payload] }
    queue.subscribe_with(consumer)
  end

  def next_recovery_delivery
    Timeout.timeout(5) { @deliveries.pop }
  end

  def await_recovery_condition
    Timeout.timeout(5) do
      sleep 0.01 until yield
    end
  end

  %i[channel_mutex consumer_mutex].each do |lock_name|
    it "bounds capture waiting on the old #{lock_name} without losing consumers" do
      channel = @original.create_channel
      queue = channel.queue('', exclusive: true)
      consumer = recovery_consumer(queue: queue)
      owner = lock_name == :channel_mutex ? @original : channel
      lock = owner.instance_variable_get(:"@#{lock_name}")
      entered = Queue.new
      release = Queue.new
      holder = Thread.new do
        lock.synchronize do
          entered << true
          release.pop
        end
      end
      Timeout.timeout(5) { entered.pop }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Timeout.timeout(2) do
        expect { described_class.capture(sessions: [@original], timeout: 0.05) }.to raise_error(Timeout::Error)
      end
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      release << true
      Timeout.timeout(5) { holder.join }

      snapshot = described_class.capture(sessions: [@original])
      disconnect_recovery_session(session: @original)
      replacement = recovery_session
      snapshot.restore(session: replacement)
      queue.publish('after capture timeout')
      label, info, payload = next_recovery_delivery
      expect([label, payload]).to eq(['active', 'after capture timeout'])
      consumer.channel.acknowledge(info.delivery_tag)
      consumer.cancel
      expect(queue.consumer_count).to eq(0)
    ensure
      release&.push(true)
      holder&.kill
      holder&.join(2)
    end
  end

  it 'keeps actor queue references, exchange bindings, raw consumers and prefetch working on a new session' do
    declaration_channel = @original.create_channel
    source = declaration_channel.direct(recovery_name(kind: :exchange), auto_delete: true)
    destination = declaration_channel.direct(recovery_name(kind: :exchange), auto_delete: true)
    destination.bind(source, routing_key: 'work')
    queue = declaration_channel.queue('', exclusive: true)
    queue.bind(destination, routing_key: 'work')
    original_name = queue.name

    # This is the framework Subscription#reassign_queue_channel + subscribe_with path.
    dedicated = @original.create_channel
    declaration_channel.deregister_queue(queue)
    queue.instance_variable_set(:@channel, dedicated)
    dedicated.register_queue(queue)
    dedicated.prefetch(1)
    consumer = recovery_consumer(queue: queue)
    snapshot = described_class.capture(sessions: [@original])
    disconnect_recovery_session(session: @original)
    replacement = recovery_session
    snapshot.restore(session: replacement)

    expect(queue.name).not_to eq(original_name)
    source.publish('first', routing_key: 'work')
    source.publish('second', routing_key: 'work')
    _, first, payload = next_recovery_delivery
    expect(payload).to eq('first')
    await_recovery_condition { queue.message_count == 1 }
    queue.channel.acknowledge(first.delivery_tag)
    _, second, payload = next_recovery_delivery
    expect(payload).to eq('second')
    queue.channel.acknowledge(second.delivery_tag)

    consumer.cancel
    snapshot.restore(session: replacement)
    expect(queue.consumer_count).to eq(0)
    source.publish('after cancel', routing_key: 'work')
    await_recovery_condition { queue.message_count == 1 }
    expect(queue.pop.last).to eq('after cancel')
  end

  it 'recreates named exclusive auto-delete queues and keeps cancellation on the original consumer effective' do
    channel = @original.create_channel
    name = recovery_name(kind: :queue)
    queue = channel.queue(name, exclusive: true, auto_delete: true)
    consumer = recovery_consumer(queue: queue, tag: '')
    snapshot = described_class.capture(sessions: [@original])
    disconnect_recovery_session(session: @original)
    replacement = recovery_session
    snapshot.restore(session: replacement)

    queue.publish('restored')
    _, info, payload = next_recovery_delivery
    expect(payload).to eq('restored')
    queue.channel.acknowledge(info.delivery_tag)
    consumer.cancel
    inspector = replacement.create_channel
    expect { inspector.queue(name, passive: true) }.to raise_error(Bunny::NotFound)
  end

  it 'does not revive consumers cancelled before or after capture, or duplicate subscriptions on repeated restore' do
    queue = @original.create_channel.queue('', exclusive: true)
    cancelled = recovery_consumer(queue: queue, label: 'cancelled before capture')
    cancelled.cancel
    cancelled_later = recovery_consumer(queue: queue, label: 'cancelled after capture')
    active = recovery_consumer(queue: queue)
    snapshot = described_class.capture(sessions: [@original, @original])
    cancelled_later.cancel
    disconnect_recovery_session(session: @original)
    replacement = recovery_session
    snapshot.restore(session: replacement)
    snapshot.restore(session: replacement)

    expect(queue.consumer_count).to eq(1)
    queue.publish('only active')
    label, info, payload = next_recovery_delivery
    expect([label, payload]).to eq(['active', 'only active'])
    active.channel.acknowledge(info.delivery_tag)
  end

  it 'recovers colliding channel numbers from multiple sessions without replacing setup channels' do
    source_channel = @original.create_channel
    source = source_channel.direct(recovery_name(kind: :exchange), auto_delete: true)
    other = recovery_session
    queue = other.create_channel.queue('', exclusive: true, auto_delete: true)
    queue.bind(source.name, routing_key: 'work')
    recovery_consumer(queue: queue)
    snapshot = described_class.capture(sessions: [other, @original])
    disconnect_recovery_session(session: other)
    disconnect_recovery_session(session: @original)
    replacement = recovery_session
    setup_channel = replacement.create_channel
    snapshot.restore(session: replacement)

    source.publish('cross-session binding', routing_key: 'work')
    _, first, payload = next_recovery_delivery
    expect(payload).to eq('cross-session binding')
    queue.channel.acknowledge(first.delivery_tag)
    setup_channel.default_exchange.publish('setup channel still usable', routing_key: queue.name)
    _, second, payload = next_recovery_delivery
    expect(payload).to eq('setup channel still usable')
    queue.channel.acknowledge(second.delivery_tag)
  end

  it 'refuses to rebind while an old callback can still acknowledge a reused delivery tag' do
    queue = @original.create_channel(nil, 1, false, 0.05).queue('', exclusive: true)
    entered = Queue.new
    release = Queue.new
    consumer = Bunny::Consumer.new(queue.channel, queue, SecureRandom.uuid, false)
    consumer.on_delivery do |info, _properties, payload|
      if payload == 'old callback'
        entered << true
        release.pop
      else
        queue.channel.acknowledge(info.delivery_tag)
        @deliveries << payload
      end
    end
    queue.subscribe_with(consumer)
    queue.publish('old callback')
    Timeout.timeout(5) { entered.pop }
    snapshot = described_class.capture(sessions: [@original])
    workers = queue.channel.work_pool.threads.dup
    disconnect_recovery_session(session: @original, stop_workers: false)
    replacement = recovery_session
    expect { snapshot.restore(session: replacement) }.to raise_error(IOError, /workers/)
    release << true
    workers.each { |worker| worker.join(2) }
    snapshot.restore(session: replacement)

    queue.publish('new callback')
    expect(next_recovery_delivery).to eq('new callback')
    expect(queue.message_count).to eq(0)
  ensure
    workers&.each(&:kill)
    workers&.each { |worker| worker.join(2) }
  end

  it 'propagates topology failures instead of claiming restored subscriptions' do
    name = recovery_name(kind: :queue)
    queue = @original.create_channel.queue(name, durable: true, arguments: { 'x-max-priority' => 2 })
    recovery_consumer(queue: queue)
    snapshot = described_class.capture(sessions: [@original])
    disconnect_recovery_session(session: @original)
    replacement = recovery_session
    channel = replacement.create_channel
    channel.queue_delete(name)
    channel.queue(name, durable: true, arguments: { 'x-max-priority' => 3 })

    expect { snapshot.restore(session: replacement) }.to raise_error(Bunny::PreconditionFailed)
    expect(channel.queue(name, passive: true).consumer_count).to eq(0)
    expect { snapshot.restore(session: replacement) }.to raise_error(IOError, /torn down/)

    disconnect_recovery_session(session: replacement)
    retry_session = recovery_session
    retry_session.create_channel.queue_delete(name)
    snapshot.restore(session: retry_session)
    queue.publish('after retry')
    _, info, payload = next_recovery_delivery
    expect(payload).to eq('after retry')
    queue.channel.acknowledge(info.delivery_tag)
  end
end
