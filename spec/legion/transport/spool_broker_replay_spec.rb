# frozen_string_literal: true

require 'spec_helper'
require 'bunny'
require 'fileutils'
require 'securerandom'
require 'tmpdir'
require 'legion/transport/connection'
require 'legion/transport/publisher'

RSpec.describe Legion::Transport::Spool, 'confirmed broker replay', rabbitmq: true do
  let(:spool_dir) { Dir.mktmpdir('legion-spool-broker') }

  before do
    described_class.reset!
    described_class.setup(directory: spool_dir)
    @session = Bunny.new(ENV.fetch('RABBITMQ_URL', 'amqp://guest:guest@127.0.0.1:5672'),
                         automatically_recover: false).start
    @channels = []
  end

  after do
    described_class.reset!
    @channels.each do |channel|
      channel.close if channel.open?
      channel.work_pool.kill
      Array(channel.work_pool.threads).each { |thread| thread.join(2) }
    end
    @session.close if @session&.open?
    FileUtils.rm_rf(spool_dir)
  end

  def broker_channel
    @session.create_channel.tap { |channel| @channels << channel }
  end

  def finish_broker_replay
    worker = described_class.instance_variable_get(:@replay_thread)
    expect(worker.join(5)).to eq(worker) if worker
  end

  it 'survives an outage and an interrupted confirmation without losing pending work' do
    topology = broker_channel
    exchange = topology.exchange("legion.spool.#{SecureRandom.uuid}", type: :topic, auto_delete: true)
    queue = topology.queue('', exclusive: true)
    queue.bind(exchange, routing_key: 'run')
    wire_payload = 'gcm:ciphertext:tag'
    timestamp = '2026-07-22 22:34:26 -0500'
    expected_timestamp = Time.new(2026, 7, 22, 22, 34, 26, '-05:00').to_i
    described_class.write(exchange: exchange.name, exchange_type: :topic, tenant_id: 'default', routing_key: 'run',
                          payload: wire_payload, content_encoding: 'encrypted/cs', headers: { iv: 'original-iv' }, timestamp: timestamp)

    disconnected = broker_channel
    disconnected.close
    allow(Legion::Transport::Connection).to receive(:channel).and_return(disconnected)
    described_class.replay_async
    finish_broker_replay
    expect(described_class.count).to eq(1)
    expect(queue.message_count).to eq(0)

    publisher = broker_channel
    allow(Legion::Transport::Connection).to receive(:channel).and_return(publisher)
    confirmed = Queue.new
    release = Queue.new
    allow(publisher).to receive(:wait_for_confirms).and_wrap_original do |original|
      result = original.call
      confirmed << result
      release.pop
      result
    end
    described_class.replay_async
    expect(confirmed.pop(timeout: 5)).to be true
    expect(described_class.count).to eq(1)
    _delivery, properties, payload = queue.pop
    expect(payload).to eq(wire_payload)
    expect(properties.content_encoding).to eq('encrypted/cs')
    expect(properties.headers).to include('iv' => 'original-iv')
    expect(properties.timestamp.to_i).to eq(expected_timestamp)

    described_class.stop_replay(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.02)
    finish_broker_replay
    expect(described_class.count).to eq(1)
    allow(publisher).to receive(:wait_for_confirms).and_call_original
    described_class.replay_async
    finish_broker_replay
    expect(described_class.count).to eq(0)
    # A broker may accept a send whose confirmation the process never observes.
    _delivery, properties, payload = queue.pop
    expect(payload).to eq(wire_payload)
    expect(properties.timestamp.to_i).to eq(expected_timestamp)
  ensure
    release << true if release
  end

  it 'quarantines a missing broker exchange without blocking healthy work and repairs its unchanged wire bytes' do
    topology = broker_channel
    exchange = topology.topic("legion.spool.#{SecureRandom.uuid}", auto_delete: true)
    queue = topology.queue('', exclusive: true)
    queue.bind(exchange, routing_key: 'run')
    allow(Legion::Transport::Connection).to receive(:channel) { broker_channel }
    described_class.write(exchange: "missing.#{SecureRandom.uuid}", routing_key: 'run', payload: 'retained-ciphertext',
                          content_encoding: 'encrypted/cs', headers: { iv: 'retained-iv' })
    described_class.write(exchange: exchange.name, routing_key: 'run', payload: 'healthy tail')

    described_class.replay_async
    finish_broker_replay
    expect(queue.pop.last).to eq('healthy tail')
    expect(described_class.status).to include(pending: 0, quarantined: 1)
    id = described_class.recovery_entries.fetch(0).fetch(:id)
    described_class.repair_record(id: id, changes: { exchange: exchange.name })
    finish_broker_replay

    _delivery, properties, payload = queue.pop
    expect(payload).to eq('retained-ciphertext')
    expect(properties.headers['iv']).to eq('retained-iv')
    expect(properties.content_encoding).to eq('encrypted/cs')
    expect(described_class.recovery_record(id: id)[:status]).to eq('delivered')
  end
end
