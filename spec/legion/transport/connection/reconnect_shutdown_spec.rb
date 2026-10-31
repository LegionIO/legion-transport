# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Transport::Connection, 'reconnect cancellation', :rabbitmq do
  let(:connection) do
    described_class.clone.tap do |copy|
      copy.instance_variables.each { |name| copy.remove_instance_variable(name) }
    end
  end
  let(:deliveries) { Queue.new }
  let(:subscribed_queue) do
    connection.channel.queue('', exclusive: true).tap do |queue|
      queue.subscribe(manual_ack: true) do |info, _properties, body|
        queue.channel.acknowledge(info.delivery_tag)
        deliveries << body
      end
    end
  end

  before do
    @connected = Legion::Settings[:transport][:connected]
    @threads = []
    @releases = []
    allow(connection).to receive(:handle_exception)
    allow(connection).to receive(:settings).and_return(Legion::Settings[:transport].merge(connection_pool_size: 1))
    connection.setup
  end

  after do
    @releases.each { |release| release << true }
    @threads.each { |thread| thread.kill.join }
    connection.shutdown
  ensure
    Legion::Settings[:transport][:connected] = @connected
  end

  def start_reconnect
    Thread.new { connection.force_reconnect }.tap { |thread| @threads << thread }
  end

  def pause_capture
    captured = Queue.new
    allow(Legion::Transport::Connection::Recovery).to receive(:capture).and_wrap_original do |original, **options|
      snapshot = original.call(**options)
      release = Queue.new
      @releases << release
      captured << release
      release.pop
      snapshot
    end
    captured
  end

  it 'preserves the session and subscription after a snapshot deadline and delivers again after retry' do
    queue = subscribed_queue
    original_session = connection.session
    locked = Queue.new
    release = Queue.new
    @releases << release
    holder = Thread.new do
      original_session.instance_variable_get(:@channel_mutex).synchronize do
        locked << true
        release.pop
      end
    end
    @threads << holder
    Timeout.timeout(3) { locked.pop }

    entered = Queue.new
    allow(Legion::Transport::Connection::Recovery).to receive(:capture).and_wrap_original do |original, **options|
      entered << true
      original.call(**options)
    end
    shutdown_timeout = described_class::SHUTDOWN_TIMEOUT
    stub_const('Legion::Transport::Connection::SHUTDOWN_TIMEOUT', 0.1)
    reconnect = start_reconnect
    Timeout.timeout(3) { entered.pop }

    expect(Timeout.timeout(2) { reconnect.value }).to be false
    expect(connection.session).to equal(original_session)
    expect(connection.session_open?).to be true

    release << true
    Timeout.timeout(3) { holder.join }
    stub_const('Legion::Transport::Connection::SHUTDOWN_TIMEOUT', shutdown_timeout)
    queue.publish('original subscription')
    expect(Timeout.timeout(3) { deliveries.pop }).to eq('original subscription')

    expect(connection.force_reconnect).to be true
    expect(connection.session).not_to equal(original_session)
    queue.publish('retried subscription')
    expect(Timeout.timeout(3) { deliveries.pop }).to eq('retried subscription')
  end

  it 'does not reopen transport when a capture returns after shutdown' do
    captured = pause_capture
    original_session = connection.session
    reconnect = start_reconnect
    release = Timeout.timeout(3) { captured.pop }

    connection.shutdown
    expect(original_session.transport).not_to be_open
    release << true

    expect(Timeout.timeout(3) { reconnect.value }).to be false
    expect(connection.session).to be_nil
    expect(connection.session_open?).to be false
    expect(Legion::Settings[:transport][:connected]).to be false
  end

  it 'leaves an explicitly started fresh session usable when cancelled capture returns' do
    captured = pause_capture
    reconnect = start_reconnect
    release = Timeout.timeout(3) { captured.pop }

    connection.shutdown
    connection.setup
    fresh_session = connection.session
    queue = subscribed_queue
    release << true

    expect(Timeout.timeout(3) { reconnect.value }).to be false
    expect(connection.session).to equal(fresh_session)
    expect(fresh_session).to be_open
    queue.publish('fresh session survives')
    expect(Timeout.timeout(3) { deliveries.pop }).to eq('fresh session survives')
  end

  it 'does not tear down a fresh session when an old reconnect fails after detaching its session' do
    original_session = connection.session
    start = Queue.new
    entered = Queue.new
    release = Queue.new
    @releases.push(start, release)
    reconnect = Thread.new do
      start.pop
      connection.force_reconnect
    end
    @threads << reconnect
    allow(connection).to receive(:setup).and_wrap_original do |original, **options|
      if Thread.current.equal?(reconnect)
        entered << true
        release.pop
      end
      original.call(**options)
    end
    start << true
    Timeout.timeout(3) { entered.pop }
    expect(original_session.transport).not_to be_open

    connection.shutdown
    connection.setup
    fresh_session = connection.session
    queue = subscribed_queue
    release << true

    expect(Timeout.timeout(3) { reconnect.value }).to be false
    expect(connection.session).to equal(fresh_session)
    expect(fresh_session).to be_open
    queue.publish('fresh session survives stale rescue')
    expect(Timeout.timeout(3) { deliveries.pop }).to eq('fresh session survives stale rescue')
  end

  it 'keeps a newer reconnect exclusive when the cancelled owner finishes' do
    captured = pause_capture
    cancelled = start_reconnect
    release_cancelled = Timeout.timeout(3) { captured.pop }

    connection.shutdown
    connection.setup
    queue = subscribed_queue
    current = start_reconnect
    release_current = Timeout.timeout(3) { captured.pop }

    release_cancelled << true
    expect(Timeout.timeout(3) { cancelled.value }).to be false
    rejected = start_reconnect
    expect(Timeout.timeout(3) { rejected.value }).to be_falsey

    release_current << true
    expect(Timeout.timeout(5) { current.value }).to be true
    queue.publish('new owner restored subscription')
    expect(Timeout.timeout(3) { deliveries.pop }).to eq('new owner restored subscription')
  end
end
