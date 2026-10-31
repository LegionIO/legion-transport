# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Legion::Transport::Spool, 'capacity and wire envelopes' do
  let(:spool_dir) { Dir.mktmpdir('legion-spool-limits') }

  before do
    described_class.reset!
    described_class.setup(directory: spool_dir)
  end

  after do
    described_class.reset!
    FileUtils.rm_rf(spool_dir)
  end

  def drain_payloads
    payloads = []
    described_class.drain do |record|
      payloads << record[:payload]
      true
    end
    payloads
  end

  it 'rejects new records at the file limit without evicting previously persisted work' do
    described_class.setup(directory: spool_dir, max_file_bytes: 1, max_files: 2)
    %w[first second].each { |payload| described_class.write(exchange: 'task', routing_key: 'run', payload: payload) }
    expect do
      described_class.write(exchange: 'task', routing_key: 'run', payload: 'third')
    end.to raise_error(described_class::CapacityExceededError)
    expect(drain_payloads).to eq(%w[first second])
  end

  it 'checks prospective encoded record bytes before an append exceeds the total limit' do
    described_class.write(exchange: 'task', routing_key: 'run', payload: 'same')
    record_size = Dir.glob(File.join(spool_dir, '*.jsonl')).sum { |file| File.size(file) }
    described_class.setup(directory: spool_dir, max_total_bytes: record_size * 2)
    described_class.write(exchange: 'task', routing_key: 'run', payload: 'same')
    expect do
      described_class.write(exchange: 'task', routing_key: 'run', payload: 'same')
    end.to raise_error(described_class::CapacityExceededError)
    expect(Dir.glob(File.join(spool_dir, '*.jsonl')).sum { |file| File.size(file) }).to eq(record_size * 2)
    expect(drain_payloads).to eq(%w[same same])
  end

  it 'includes claimed records in capacity and never evicts a claim during its callback' do
    described_class.setup(directory: spool_dir, max_files: 1, max_age_seconds: 1)
    described_class.write(exchange: 'task', routing_key: 'run', payload: 'pending')
    Dir.glob(File.join(spool_dir, '*.jsonl')).each { |file| FileUtils.touch(file, mtime: Time.now - 60) }
    described_class.drain do |_record|
      described_class.evict_stale
      expect do
        described_class.write(exchange: 'task', routing_key: 'run', payload: 'would evict')
      end.to raise_error(described_class::CapacityExceededError)
      false
    end
    expect(drain_payloads).to eq(['pending'])
  end

  it 'expires only sealed unclaimed files, not the active writer file' do
    described_class.setup(directory: spool_dir, max_file_bytes: 1, max_age_seconds: 1)
    %w[sealed active].each { |payload| described_class.write(exchange: 'task', routing_key: 'run', payload: payload) }
    Dir.glob(File.join(spool_dir, '*.jsonl')).each { |file| FileUtils.touch(file, mtime: Time.now - 60) }
    described_class.evict_stale
    expect(drain_payloads).to eq(['active'])
  end

  it 'round-trips the full AMQP envelope, tenant, destination type and encrypted wire bytes' do
    envelope = {
      headers:          { iv: 'original-iv', 'x-priority': 5 },
      content_type:     'application/json',
      content_encoding: 'encrypted/cs',
      priority:         10,
      message_id:       'message-123',
      correlation_id:   'correlation-456',
      persistent:       false,
      expiration:       '3000',
      app_id:           'legion',
      user_id:          'publisher',
      reply_to:         'reply.queue',
      type:             'task',
      timestamp:        1_700_000_000,
      mandatory:        true
    }
    payload = "\x00\xFFciphertext".b
    described_class.write(exchange: 't.alpha.task', exchange_type: 'direct', tenant_id: 'alpha',
                          routing_key: 'test.run', payload: payload, **envelope)
    records = []
    described_class.drain do |record|
      records << record
      true
    end

    expect(records).to contain_exactly(include(exchange: 't.alpha.task', exchange_type: 'direct', tenant_id: 'alpha',
                                               payload: payload, envelope: envelope.merge(routing_key: 'test.run')))
  end
end
