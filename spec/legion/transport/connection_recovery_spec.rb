# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Legion::Transport::Connection, 'recovery lifecycle' do
  let(:connection) do
    described_class.clone.tap do |copy|
      copy.instance_variables.each { |name| copy.remove_instance_variable(name) }
    end
  end
  let(:snapshot) { instance_double(Legion::Transport::Connection::Recovery, restore: nil) }

  before do
    stub_const('Legion::Transport::TYPE', 'bunny')
    stub_const('Legion::Transport::CONNECTOR', Bunny)
    @connected = Legion::Settings[:transport][:connected]
    allow(Legion::Transport::Connection::Recovery).to receive(:capture).and_return(snapshot)
  end

  after do
    Legion::Settings[:transport][:connected] = @connected
  end

  describe '.force_reconnect' do
    it 'keeps the first reconnect exclusive after a second caller is rejected' do
      entered = Queue.new
      release = Queue.new
      replacements = Queue.new
      allow(connection).to receive(:setup) do |**|
        replacements << Object.new
        entered << true
        release.pop
      end
      first = Thread.new { connection.force_reconnect }
      Timeout.timeout(2) { entered.pop }

      connection.force_reconnect
      third = Thread.new { connection.force_reconnect }
      expect(third.join(0.5)).to eq(third)
      expect(replacements.size).to eq(1)
      release << true
      expect(first.value).to be true
    ensure
      release&.<< true
      [first, third].compact.each { |thread| thread.kill.join }
    end

    it 'runs restoration before notification and continues after a notification fails' do
      events = []
      allow(connection).to receive(:setup) { |**| events << :connected }
      allow(snapshot).to receive(:restore) { |**| events << :restored }
      connection.on_force_reconnect { raise IOError, 'observer failed' }
      connection.on_force_reconnect { events << :notified }

      expect(connection.force_reconnect).to be true
      expect(events).to eq(%i[connected restored notified])
    end

    it 'retains the original subscription snapshot after failed restoration' do
      allow(connection).to receive(:setup)
      attempts = 0
      allow(snapshot).to receive(:restore) do |**|
        attempts += 1
        raise IOError, 'broker disappeared during restoration' if attempts == 1
      end

      expect(connection.force_reconnect).to be false
      expect(Legion::Settings[:transport][:connected]).to be false
      expect(connection.force_reconnect).to be true
      expect(Legion::Transport::Connection::Recovery).to have_received(:capture).once
      expect(attempts).to eq(2)
    end

    it 'recovers closed consumer channels and survives repeated pooled reconnects', :rabbitmq do
      allow(Legion::Transport::Connection::Recovery).to receive(:capture).and_call_original
      allow(connection).to receive(:settings).and_return(Legion::Settings[:transport].merge(connection_pool_size: 3))
      connection.setup
      publisher = connection.channel
      queue = publisher.queue('', exclusive: true)
      deliveries = Queue.new
      consumer = queue.subscribe(manual_ack: true) do |info, _properties, body|
        queue.channel.acknowledge(info.delivery_tag)
        deliveries << body
      end
      channel_count = connection.session.instance_variable_get(:@channels).values.count(&:open?)
      publisher.connection_closed! # Bunny marks channels closed when network recovery starts.

      3.times do |round|
        old_session = connection.session
        expect(connection.force_reconnect).to be true
        expect(old_session.transport).not_to be_open
        expect(connection.channel).to equal(publisher)
        expect(connection.session.instance_variable_get(:@channels).values.count(&:open?)).to eq(channel_count)
        expect(queue.consumer_count).to eq(1)
        queue.publish(round.to_s)
        expect(Timeout.timeout(3) { deliveries.pop }).to eq(round.to_s)
      end
      consumer.cancel
      expect(connection.force_reconnect).to be true
      expect(queue.consumer_count).to eq(0)
    ensure
      connection.shutdown
    end
  end

  describe '.shutdown' do
    it 'bounds all sessions by one deadline and closes sockets even after it expires' do
      stub_const('Legion::Transport::Connection::SHUTDOWN_TIMEOUT', 0.05)
      sockets = [StringIO.new, StringIO.new]
      sessions = sockets.map do |socket|
        instance_double(Bunny::Session, open?: true).tap do |session|
          session.instance_variable_set(:@transport, socket)
          allow(session).to receive(:close) { Queue.new.pop }
        end
      end
      connection.instance_variable_set(:@session, Concurrent::AtomicReference.new(sessions.first))
      connection.instance_variable_set(:@build_session, Concurrent::AtomicReference.new(sessions.last))
      Legion::Settings[:transport][:connected] = true
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      connection.shutdown

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      expect(sockets).to all(be_closed)
      expect(connection.session_open?).to be false
      expect(connection.build_session_open?).to be false
      expect(Legion::Settings[:transport][:connected]).to be false
    end

    it 'stops old consumer workers before their channels can be reused' do
      entered = Queue.new
      worker = Thread.new do
        entered << true
        Queue.new.pop
      end
      entered.pop
      work_pool = instance_double(Bunny::ConsumerWorkPool, threads: [worker])
      channel = instance_double(Bunny::Channel, work_pool: work_pool)
      session = instance_double(Bunny::Session, close: nil)
      socket = StringIO.new
      session.instance_variable_set(:@transport, socket)
      session.instance_variable_set(:@channels, { 1 => channel })
      connection.instance_variable_set(:@session, Concurrent::AtomicReference.new(session))

      connection.shutdown

      expect(worker).not_to be_alive
      expect(socket).to be_closed
    ensure
      worker&.kill&.join
    end

    it 'does not inject an intentional socket-close failure into the session owner' do
      finish = Queue.new
      read_released = Queue.new
      reading = Queue.new
      owner = Thread.new { finish.pop }
      owner.report_on_exception = false
      reader = Thread.new do
        reading << true
        read_released.pop
        owner.raise(Bunny::NetworkFailure, 'socket closed during read')
      end
      Timeout.timeout(2) { reading.pop }
      socket = StringIO.new
      socket.define_singleton_method(:close) do
        read_released << true
        reader.join(0.1)
        super()
      end
      reader_loop = Object.new
      reader_loop.instance_variable_set(:@thread, reader)
      session = instance_double(Bunny::Session, close: nil)
      session.instance_variable_set(:@reader_loop, reader_loop)
      session.instance_variable_set(:@transport, socket)
      connection.instance_variable_set(:@session, Concurrent::AtomicReference.new(session))

      connection.shutdown
      finish << :finished

      expect(Timeout.timeout(2) { owner.value }).to eq(:finished)
      expect(socket).to be_closed
    ensure
      finish&.<< :finished
      reader&.kill&.join
      owner&.kill
      owner.join if owner&.alive?
    end

    it 'closes a channel created concurrently with shutdown instead of registering it' do
      entered = Queue.new
      release = Queue.new
      channel = instance_double(Bunny::Channel, open?: true, prefetch: nil, close: nil)
      session = instance_double(Bunny::Session, open?: true, close: nil)
      allow(session).to receive(:create_channel) {
        entered << true
        release.pop
        channel
      }
      connection.instance_variable_set(:@session, Concurrent::AtomicReference.new(session))
      creator = Thread.new do
        connection.channel
      rescue IOError => e
        e
      end
      Timeout.timeout(2) { entered.pop }

      connection.shutdown
      release << true

      expect(creator.value).to be_a(IOError)
      expect(channel).to have_received(:close)
      expect(connection.channel_registry_size).to eq(0)
    ensure
      release&.<< true
      creator&.kill&.join
    end

    it 'rejects setup that started before shutdown and closes its newly created session' do
      entered = Queue.new
      release = Queue.new
      qos = instance_double(Bunny::Channel, basic_qos: nil, open?: true, close: nil)
      session = instance_double(Bunny::Session, create_channel: qos, close: nil)
      socket = StringIO.new
      session.instance_variable_set(:@transport, socket)
      allow(connection).to receive(:create_session_with_failover) {
        entered << true
        release.pop
        session
      }
      creator = Thread.new do
        connection.setup
      rescue IOError => e
        e
      end
      Timeout.timeout(2) { entered.pop }

      connection.shutdown
      release << true

      expect(creator.value).to be_a(IOError)
      expect(socket).to be_closed
      expect(connection.session_open?).to be false
    ensure
      release&.<< true
      creator&.kill&.join
    end
  end

  describe '.tear_down_session' do
    it 'closes the socket before attempting potentially blocking protocol cleanup' do
      socket = StringIO.new
      session = instance_double(Bunny::Session)
      session.instance_variable_set(:@transport, socket)
      allow(session).to receive(:close) { raise 'socket still open' unless socket.closed? }

      connection.send(:tear_down_session, sess: session)

      expect(socket).to be_closed
    end

    it 'closes the socket even when session cleanup raises' do
      socket = StringIO.new
      session = instance_double(Bunny::Session)
      session.instance_variable_set(:@transport, socket)
      allow(session).to receive(:close).and_raise(IOError, 'broken close')

      connection.send(:tear_down_session, sess: session)

      expect(socket).to be_closed
    end
  end
end
