# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'weakref'
require 'legion/transport/in_process'

RSpec.describe Legion::Transport::InProcess do
  let(:channel) { described_class::Channel.new }
  let(:exchange) { described_class::Exchange.new(channel, 'topic', 'tasks') }
  let(:queue) { described_class::Queue.new(channel, 'work') }

  before do
    Legion::Transport::Local.reset!
    @workers = []
    @sessions = []
  end

  after do
    @workers.each do |worker|
      worker.kill if worker.alive?
      worker.join
    end
    @sessions.each(&:close)
    channel.close
    Legion::Transport::Local.reset!
  end

  def start_worker(&)
    Thread.new(&).tap { |worker| @workers << worker }
  end

  def start_session
    described_class::Session.new.tap do |session|
      @sessions << session
      session.start
    end
  end

  def subscribe_weak_callback(queue:, **)
    receiver = Object.new
    receiver.define_singleton_method(:call) { |_info, _properties, _payload| nil }
    [queue.subscribe(&receiver.method(:call)), WeakRef.new(receiver)]
  end

  it 'accepts all four Bunny channel arguments and uses the resulting channel' do
    session = start_session
    local_channel = session.create_channel(nil, 2, false, 10)
    local_exchange = local_channel.exchange('contract', type: :topic)
    local_queue = described_class::Queue.new(local_channel, 'contract.queue')
    local_queue.bind(local_exchange, routing_key: 'work')
    received = []
    local_queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(local_exchange.publish('accepted', routing_key: 'work')).to include(routed: true)
    expect(received).to eq(['accepted'])
  end

  it 'routes only through the named exchange even when routing keys are identical' do
    other = described_class::Exchange.new(channel, 'topic', 'other')
    queue.bind(exchange, routing_key: 'work')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(other.publish('wrong', routing_key: 'work')).to include(routed: false)
    expect(exchange.publish('right', routing_key: 'work')).to include(routed: true)
    expect(received).to eq(['right'])
  end

  it 'reports no route without creating a hidden backlog or reaching default-exchange Local subscribers' do
    default_deliveries = []
    Legion::Transport::Local.subscribe('work') { |payload| default_deliveries << payload }
    expect(exchange.publish('unroutable', routing_key: 'work')).to include(routed: false)
    queue.bind(exchange, routing_key: 'work')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(received).to be_empty
    expect(default_deliveries).to be_empty
    expect(Legion::Transport::Local.queue_depth('work')).to eq(0)
  end

  it 'unbinds only the requested exchange and key using the Bunny options hash contract' do
    other = described_class::Exchange.new(channel, 'topic', 'other')
    queue.bind(exchange, { routing_key: 'work' })
    queue.bind(other, routing_key: 'work')
    queue.unbind(exchange, { routing_key: 'work' })
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(exchange.publish('wrong', routing_key: 'work')).to include(routed: false)
    other.publish('right', routing_key: 'work')
    expect(received).to eq(['right'])
  end

  {
    'work.run' => { matches: ['work.run'], misses: ['work', 'work.run.extra', 'other.run'] },
    'work.*'   => { matches: ['work.run'], misses: ['work', 'work.run.extra', 'other.run'] },
    'work.#'   => { matches: ['work', 'work.run', 'work.run.extra'], misses: ['worker', 'other.work'] },
    '#.done'   => { matches: ['done', 'work.done', 'work.run.done'], misses: ['work', 'done.extra'] },
    'a.#.b'    => { matches: ['a.b', 'a.one.two.b'], misses: ['a', 'a.one.c', 'a.b.c'] },
    '#'        => { matches: ['', 'one', 'one.two'], misses: [] },
    '#.#'      => { matches: ['', 'one', 'one.two'], misses: [] },
    'task.+'   => { matches: ['task.+'], misses: ['task.x', 'task.xx'] },
    ''         => { matches: [''], misses: ['work'] }
  }.each do |pattern, cases|
    it "matches AMQP topic words for #{pattern.inspect}" do
      queue.bind(exchange, routing_key: pattern)
      received = []
      queue.subscribe(manual_ack: false) { |info, _properties, payload| received << [info.routing_key, payload] }
      cases[:matches].each do |key|
        expect(exchange.publish(key, routing_key: key)).to include(routed: true)
      end
      cases[:misses].each do |key|
        expect(exchange.publish(key, routing_key: key)).to include(routed: false)
      end

      expect(received).to eq(cases[:matches].map { |key| [key, key] })
    end
  end

  it 'does not interpret topic wildcards on a direct exchange' do
    direct = described_class::Exchange.new(channel, 'direct', 'direct')
    queue.bind(direct, routing_key: 'work.*')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(direct.publish('wrong', routing_key: 'work.run')).to include(routed: false)
    direct.publish('literal', routing_key: 'work.*')
    expect(received).to eq(['literal'])
  end

  it 'routes fanout bindings regardless of key without crossing exchange identity' do
    fanout = described_class::Exchange.new(channel, 'fanout', 'fanout')
    other = described_class::Exchange.new(channel, 'fanout', 'other')
    queue.bind(fanout, routing_key: 'ignored')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    fanout.publish('routed', routing_key: 'anything')
    expect(other.publish('wrong', routing_key: 'anything')).to include(routed: false)
    expect(received).to eq(['routed'])
  end

  it 'binds unbound queues only through the default exchange' do
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(exchange.publish('wrong', routing_key: queue.name)).to include(routed: false)
    expect(channel.default_exchange.publish('right', routing_key: queue.name)).to include(routed: true)
    expect(received).to eq(['right'])
  end

  it 'delivers once per queue even when several bindings match' do
    queue.bind(exchange, routing_key: '#').bind(exchange, routing_key: 'work.*').bind(exchange, routing_key: '#')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }
    exchange.publish('once', routing_key: 'work.run')

    expect(received).to eq(['once'])
  end

  it 'preserves the actual exchange, routing key, and full encrypted publication envelope' do
    queue.bind(exchange, routing_key: 'work.#')
    deliveries = []
    queue.subscribe(manual_ack: false) { |info, properties, payload| deliveries << [info, properties, payload] }
    envelope = {
      content_type: 'application/octet-stream', content_encoding: 'aes-256-gcm',
      headers: { 'iv' => 'base64-iv', 'auth_tag' => 'base64-tag', 'tenant_id' => 'alpha' },
      timestamp: 123, correlation_id: 'correlation', message_id: 'message', reply_to: 'reply',
      type: 'task', priority: 7, expiration: '1000', app_id: 'spec', persistent: false,
      delivery_mode: 1, user_id: 'worker', mandatory: true
    }
    exchange.publish("\x00\xFF".b, routing_key: 'work.run', **envelope)
    info, properties, payload = deliveries.fetch(0)

    expect(info.exchange).to eq('tasks')
    expect(info.routing_key).to eq('work.run')
    expect(properties.to_h).to include(envelope)
    expect(properties.content_encoding).to eq('aes-256-gcm')
    expect(properties.headers).to eq(envelope.fetch(:headers))
    expect(payload).to eq("\x00\xFF".b)
  end

  it 'retains pre-subscription backlog, not completed history, for competing consumers' do
    queue.bind(exchange, routing_key: 'work')
    exchange.publish('backlog', routing_key: 'work')
    first = []
    second = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| first << payload }
    exchange.publish('live', routing_key: 'work')
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| second << payload }
    expect(second).to be_empty
    exchange.publish('next', routing_key: 'work')
    exchange.publish('last', routing_key: 'work')

    expect(first + second).to contain_exactly('backlog', 'live', 'next', 'last')
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(0)
  end

  it 'cancels idempotently and leaves undelivered work for replacement consumers' do
    queue.bind(exchange, routing_key: 'work')
    cancelled_deliveries = []
    5.times do
      consumer = queue.subscribe(manual_ack: false) { |_info, _properties, payload| cancelled_deliveries << payload }
      consumer.cancel
      consumer.cancel
      expect(consumer.cancelled?).to be true
    end
    exchange.publish('pending', routing_key: 'work')
    replacement = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| replacement << payload }

    expect(cancelled_deliveries).to be_empty
    expect(replacement).to eq(['pending'])
  end

  it 'releases the cancelled callback even while the consumer object remains retained' do
    consumer, receiver = subscribe_weak_callback(queue: queue)
    consumer.cancel
    GC.start(full_mark: true, immediate_sweep: true)

    expect(consumer.cancelled?).to be true
    expect(receiver.weakref_alive?).to be_falsey
  end

  it 'allows a callback to cancel itself without deadlocking or receiving queued messages' do
    queue.bind(exchange, routing_key: 'work')
    received = []
    consumer = queue.subscribe(manual_ack: false) do |_info, _properties, payload|
      received << payload
      consumer.cancel
      exchange.publish('pending', routing_key: 'work')
    end
    exchange.publish('first', routing_key: 'work')
    expect(received).to eq(['first'])
    expect(consumer.cancelled?).to be true
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(1)
  end

  it 'waits for an in-flight callback during cancellation without locking unrelated queues' do
    queue.bind(exchange, routing_key: 'work')
    entered = Thread::Queue.new
    release = Thread::Queue.new
    cancelled = Thread::Queue.new
    received = []
    consumer = queue.subscribe(manual_ack: false) do |_info, _properties, payload|
      received << payload
      entered << :entered
      release.pop
    end
    publisher = start_worker { exchange.publish('first', routing_key: 'work') }
    expect(entered.pop(timeout: 2)).to eq(:entered)
    cancellation = start_worker do
      consumer.cancel
      cancelled << :completed
    end
    Timeout.timeout(2) { Thread.pass until consumer.cancelled? }
    expect(cancelled).to be_empty

    independent = start_worker do
      other_queue = described_class::Queue.new(channel, 'other')
      other_queue.bind(exchange, routing_key: 'other')
      other_queue.subscribe(manual_ack: false) { |_info, _properties, payload| cancelled << payload }
      exchange.publish('independent', routing_key: 'other')
      exchange.publish('pending', routing_key: 'work')
    end
    expect(cancelled.pop(timeout: 2)).to eq('independent')
    expect(independent.join(2)).to eq(independent)
    release << :continue
    expect(cancellation.join(2)).to eq(cancellation)
    expect(publisher.join(2)).to eq(publisher)
    expect(cancelled.pop(timeout: 2)).to eq(:completed)
    exchange.publish('later', routing_key: 'work')
    expect(received).to eq(['first'])
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(2)
  end

  it 'queue deletion cancels all consumers and removes bindings and pending work' do
    queue.bind(exchange, routing_key: '#')
    received = []
    consumer = queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }
    queue.delete

    expect(consumer.cancelled?).to be true
    expect(exchange.publish('unroutable', routing_key: 'work')).to include(routed: false)
    expect(received).to be_empty
    replacement = described_class::Queue.new(channel, queue.name)
    replacement.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }
    expect(received).to be_empty
  end

  it 'exchange deletion removes its bindings without deleting the queue' do
    queue.bind(exchange, routing_key: '#')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }
    exchange.delete

    expect(exchange.publish('wrong', routing_key: 'work')).to include(routed: false)
    channel.default_exchange.publish('right', routing_key: queue.name)
    expect(received).to eq(['right'])
  end

  it 'channel close cancels its consumers but retains session-owned queue backlog' do
    session = start_session
    subscriber_channel = session.create_channel
    subscriber_queue = described_class::Queue.new(subscriber_channel, 'owned')
    subscriber_queue.bind('tasks', routing_key: 'work')
    received = []
    consumer = subscriber_queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }
    subscriber_channel.close
    publisher_channel = session.create_channel
    publisher_exchange = publisher_channel.exchange('tasks', type: :topic)
    expect(publisher_exchange.publish('pending', routing_key: 'work')).to include(routed: true)
    replacement = described_class::Queue.new(publisher_channel, 'owned')
    replacement.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(consumer.cancelled?).to be true
    expect(received).to eq(['pending'])
  end

  it 'session close cleans up its queues without resetting another session' do
    first = start_session
    second = start_session
    first_channel = first.create_channel
    second_channel = second.create_channel
    first_queue = described_class::Queue.new(first_channel, 'first')
    second_queue = described_class::Queue.new(second_channel, 'second')
    first_queue.bind('tasks', routing_key: 'work')
    second_queue.bind('tasks', routing_key: 'work')
    first_consumer = first_queue.subscribe(manual_ack: false) { |_info, _properties, _payload| raise 'closed consumer called' }
    received = []
    second_queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }
    first.close
    first.close
    second_channel.exchange('tasks', type: :topic).publish('survives', routing_key: 'work')

    expect(first_consumer.cancelled?).to be true
    expect(first_channel.open?).to be false
    expect(received).to eq(['survives'])
    expect(Legion::Transport::Local.queue_depth('first')).to eq(0)
    expect { first.create_channel }.to raise_error(IOError)
  end

  it 'keeps DLX topology declared on temporary channels until the session closes' do
    session = start_session
    temporary = session.create_channel
    temporary.exchange_declare_without_recording_topology('tasks.dlx', 'fanout', durable: true)
    temporary.queue_declare_without_recording_topology('tasks.dlx.queue', durable: true)
    temporary.queue_bind('tasks.dlx.queue', 'tasks.dlx', routing_key: '#')
    temporary.close
    current = session.create_channel
    current.exchange('tasks.dlx', type: :fanout).publish('failed', routing_key: 'any')
    received = []
    described_class::Queue.new(current, 'tasks.dlx.queue').subscribe(manual_ack: false) { |_info, _properties, payload| received << payload }

    expect(received).to eq(['failed'])
  end

  it 'requeues only unacknowledged messages when a manual consumer is cancelled' do
    queue.bind(exchange, routing_key: 'work')
    first = []
    consumer = queue.subscribe do |info, _properties, payload|
      first << payload
      queue.acknowledge(info.delivery_tag) if payload == 'acknowledged'
    end
    exchange.publish('acknowledged', routing_key: 'work')
    exchange.publish('unacknowledged', routing_key: 'work')
    consumer.cancel
    recovered = []
    queue.subscribe do |info, _properties, payload|
      recovered << [payload, info.redelivered]
      queue.acknowledge(info.delivery_tag)
    end

    expect(first).to eq(%w[acknowledged unacknowledged])
    expect(recovered).to eq([['unacknowledged', true]])
  end

  it 'retains synchronous rejects without a hot redelivery loop and preserves retry metadata' do
    queue.bind(exchange, routing_key: 'work')
    attempts = []
    consumer = queue.subscribe do |info, _properties, payload|
      attempts << payload
      queue.reject(info.delivery_tag, requeue: true)
    end
    exchange.publish('retry', routing_key: 'work', message_id: 'same-task', headers: { retry_count: 2 })
    expect(attempts).to eq(['retry'])
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(1)
    consumer.cancel
    recovered = []
    queue.subscribe do |info, properties, payload|
      recovered << [info.redelivered, properties.message_id, properties.headers, payload]
      queue.acknowledge(info.delivery_tag)
    end

    expect(recovered).to eq([[true, 'same-task', { retry_count: 2 }, 'retry']])
  end

  it 'discards a rejected message when requeue is false' do
    queue.bind(exchange, routing_key: 'work')
    consumer = queue.subscribe { |info, _properties, _payload| queue.reject(info.delivery_tag, requeue: false) }
    exchange.publish('discard', routing_key: 'work')
    consumer.cancel
    recovered = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| recovered << payload }

    expect(recovered).to be_empty
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(0)
  end

  it 'refuses acknowledgements from another channel without losing the outstanding delivery' do
    queue.bind(exchange, routing_key: 'work')
    tags = []
    consumer = queue.subscribe { |info, _properties, _payload| tags << info.delivery_tag }
    exchange.publish('owned', routing_key: 'work')
    other_channel = described_class::Channel.new
    expect { other_channel.acknowledge(tags.fetch(0)) }.to raise_error(ArgumentError, /Unknown local delivery tag/)
    consumer.cancel
    recovered = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| recovered << payload }
    expect(recovered).to eq(['owned'])
  ensure
    other_channel&.close
  end

  it 'returns unacknowledged work to session-owned queues after a channel closes' do
    session = start_session
    subscriber_channel = session.create_channel
    owned = described_class::Queue.new(subscriber_channel, 'manual.owned')
    owned.bind('manual', routing_key: 'work')
    owned.subscribe { |_info, _properties, _payload| nil }
    publisher = session.create_channel
    publisher.exchange('manual', type: :topic).publish('interrupted', routing_key: 'work')
    subscriber_channel.close
    recovered = []
    described_class::Queue.new(publisher, 'manual.owned').subscribe do |info, _properties, payload|
      recovered << [payload, info.redelivered]
      publisher.acknowledge(info.delivery_tag)
    end

    expect(recovered).to eq([['interrupted', true]])
  end

  it 'supports multiple acknowledgements without acknowledging another channel deliveries' do
    queue.bind(exchange, routing_key: 'work')
    tags = []
    consumer = queue.subscribe { |info, _properties, _payload| tags << info.delivery_tag }
    exchange.publish('first', routing_key: 'work')
    exchange.publish('second', routing_key: 'work')
    queue.acknowledge(tags.last, multiple: true)
    consumer.cancel
    recovered = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| recovered << payload }

    expect(recovered).to be_empty
  end
end
