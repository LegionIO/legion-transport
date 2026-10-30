# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'legion/transport/in_process'
require 'legion/transport/connection'
require 'legion/transport/publisher'

RSpec.describe Legion::Transport::Spool, 'automatic replay' do
  let(:spool_dir) { Dir.mktmpdir('legion-spool-replay') }
  let(:channel) { Legion::Transport::InProcess::Channel.new }
  let(:deliveries) { Queue.new }

  before do
    described_class.reset!
    described_class.setup(directory: spool_dir)
    @topology_settings = Legion::Settings[:transport][:tenant_topology]
    Legion::Settings[:transport][:tenant_topology] = { enabled: false }
    Legion::Transport::TenantQuota.reset!
    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
  end

  after do
    described_class.reset!
    Legion::Transport::Local.reset!
    Legion::Settings[:transport][:tenant_topology] = @topology_settings
    Legion::Transport::TenantQuota.reset!
    FileUtils.rm_rf(spool_dir)
  end

  def finish_replay
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while (worker = described_class.instance_variable_get(:@replay_thread))
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(worker.join([remaining, 0].max)).to eq(worker)
    end
  end

  def subscribe_to_replay(&callback)
    exchange = channel.exchange('t.alpha.task', type: :topic)
    queue = Legion::Transport::InProcess::Queue.new(channel, 'replay.received')
    queue.bind(exchange, routing_key: 'run')
    queue.subscribe do |_delivery, properties, payload|
      deliveries << [payload, properties, Thread.current]
      callback&.call(payload)
    end
  end

  def spool_wire(payload: 'ciphertext')
    described_class.write(exchange: 't.alpha.task', exchange_type: 'topic', tenant_id: 'alpha',
                          routing_key: 'run', payload: payload, content_encoding: 'encrypted/cs',
                          headers: { iv: 'preserved-iv' }, persistent: true)
  end

  it 'retains work during an outage and delivers the same encrypted wire envelope after reconnect' do
    subscribe_to_replay
    spool_wire
    allow(Legion::Transport::Connection).to receive(:channel).and_raise(IOError, 'disconnected')
    described_class.replay_async
    finish_replay
    expect(described_class.count).to eq(1)
    expect(deliveries).to be_empty

    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
    described_class.replay_async
    finish_replay
    payload, properties, thread = deliveries.pop(timeout: 2)
    expect(payload).to eq('ciphertext')
    expect(properties.content_encoding).to eq('encrypted/cs')
    expect(properties.headers).to include(iv: 'preserved-iv')
    expect(thread).not_to eq(Thread.current)
    expect(described_class.count).to eq(0)
  end

  it 'keeps unroutable work until a subsequent trigger can route it' do
    spool_wire
    described_class.replay_async
    finish_replay
    expect(described_class.count).to eq(1)

    subscribe_to_replay
    described_class.replay_async
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('ciphertext')
    expect(described_class.count).to eq(0)
  end

  it 'coalesces concurrent replay triggers and includes writes arriving during replay' do
    entered = Queue.new
    release = Queue.new
    subscribe_to_replay do |payload|
      next unless payload == 'first'

      entered << true
      release.pop
    end
    spool_wire(payload: 'first')
    expect(described_class.replay_async).to be true
    expect(entered.pop(timeout: 2)).to be true
    expect(described_class.replay_async).to be false
    spool_wire(payload: 'second')
    expect(described_class.count).to eq(2)
    expect(deliveries.size).to eq(1)
    release << true
    finish_replay
    expect(2.times.map { deliveries.pop(timeout: 2).first }).to eq(%w[first second])
    expect(described_class.count).to eq(0)
  ensure
    release << true if release
  end

  it 'bounds cancellation and retains a publication interrupted before acceptance completes' do
    entered = Queue.new
    release = Queue.new
    pause = true
    subscribe_to_replay do |_payload|
      next unless pause

      pause = false
      entered << true
      release.pop
    end
    spool_wire
    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.stop_replay(deadline: started + 0.02)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    finish_replay
    expect(described_class.count).to eq(1)

    described_class.replay_async
    finish_replay
    expect(described_class.count).to eq(0)
    # The first delivery may already have reached a consumer: replay is at least once.
    expect(2.times.map { deliveries.pop(timeout: 2).first }).to eq(%w[ciphertext ciphertext])
  ensure
    release << true if release
  end

  it 'preserves a startup trigger arriving while the cancelled worker is releasing its claim' do
    entered = Queue.new
    cleanup_started = Queue.new
    cleanup_release = Queue.new
    pause = true
    subscribe_to_replay do |_payload|
      next unless pause

      pause = false
      entered << true
      begin
        Queue.new.pop
      ensure
        cleanup_started << true
        cleanup_release.pop
      end
    end
    spool_wire
    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    described_class.stop_replay(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    expect(cleanup_started.pop(timeout: 2)).to be true
    expect(described_class.replay_async).to be false
    expect(deliveries.size).to eq(1)
    cleanup_release << true
    finish_replay

    expect(described_class.count).to eq(0)
    expect(2.times.map { deliveries.pop(timeout: 2).first }).to eq(%w[ciphertext ciphertext])
  ensure
    cleanup_release << true if cleanup_release
  end

  it 'finishes cancellation cleanup before resetting and reopening the spool' do
    entered = Queue.new
    pause = true
    subscribe_to_replay do |_payload|
      next unless pause

      pause = false
      entered << true
      Queue.new.pop
    end
    spool_wire
    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    described_class.reset!
    described_class.setup(directory: spool_dir)
    expect(described_class.count).to eq(1)

    described_class.replay_async
    finish_replay
    expect(described_class.count).to eq(0)
    expect(2.times.map { deliveries.pop(timeout: 2).first }).to eq(%w[ciphertext ciphertext])
  end

  it 'charges the persisted tenant encoded-byte quota per attempt, not the replay thread tenant' do
    Legion::Settings[:transport][:tenant_topology] = {
      enabled: true,
      quotas:  { alpha: { messages_per_second: 1, bytes_per_second: 2 }, beta: { bytes_per_second: 0 } }
    }
    allow(Legion::Transport::TenantTopology).to receive(:current_tenant_id).and_return('beta')
    allow(Legion::Transport::TenantQuota).to receive(:current_window).and_return(1000)
    subscribe_to_replay
    2.times { spool_wire(payload: 'é') }
    described_class.replay_async
    finish_replay
    expect(deliveries.size).to eq(1)
    expect(deliveries.pop(timeout: 2).first).to eq('é')
    expect(described_class.count).to eq(1)

    allow(Legion::Transport::TenantQuota).to receive(:current_window).and_return(1001)
    described_class.replay_async
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('é')
    expect(described_class.count).to eq(0)
  end
end
