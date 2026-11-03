# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'openssl'
require 'tmpdir'
require 'legion/transport/in_process'

RSpec.describe Legion::Transport::Spool, 'recoverable invalid records' do
  let(:directory) { Dir.mktmpdir('legion-recovery-workflow') }
  let(:channel) { Legion::Transport::InProcess::Channel.new }
  let(:deliveries) { Queue.new }

  before do
    described_class.reset!
    described_class.setup(directory: directory)
    @topology = Legion::Settings[:transport][:tenant_topology]
    @messages = Legion::Settings[:transport][:messages]
    Legion::Settings[:transport][:tenant_topology] = { enabled: false }
    Legion::Settings[:transport][:messages] = @messages.merge(encrypt: false)
    Legion::Transport::Local.reset!
    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
    destination = channel.exchange('recovered.task', type: :topic)
    queue = Legion::Transport::InProcess::Queue.new(channel, 'recovered.received')
    queue.bind(destination, routing_key: 'run')
    queue.subscribe { |_delivery, properties, payload| deliveries << [payload, properties] }
  end

  after do
    described_class.reset!
    Legion::Transport::Local.reset!
    Legion::Settings[:transport][:tenant_topology] = @topology
    Legion::Settings[:transport][:messages] = @messages
    FileUtils.rm_rf(directory)
  end

  def historical_line(payload:, exchange: 'Legion::Transport::Messages::Direct')
    "#{Legion::JSON.dump({ exchange: exchange, routing_key: 'run', payload: payload, spooled_at: '2026-10-01T00:00:00Z' })}\n"
  end

  def finish_replay
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while (worker = described_class.instance_variable_get(:@replay_thread))
      expect(worker.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)).to eq(worker)
    end
  end

  it 'delivers healthy work past a missing destination, then repairs and confirms the preserved record' do
    body = { secret: 'original payload', encrypt: false }
    broken = historical_line(payload: body)
    healthy = historical_line(payload: 'healthy', exchange: 'recovered.task')
    File.write(File.join(directory, 'legacy.jsonl'), broken + healthy)

    described_class.replay_async
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('healthy')
    expect(described_class.status).to include(pending: 0, quarantined: 1)
    entry = described_class.recovery_entries.fetch(0)
    expect(entry).not_to have_key(:record)
    original = described_class.recovery_record(id: entry[:id])
    expect(Base64.strict_decode64(original[:raw_line])).to eq(broken)
    expect(original[:record][:payload]).to eq(body)

    expect(described_class.repair_record(id: entry[:id], changes: { exchange: 'recovered.task' })).to include(status: 'ready')
    finish_replay
    expect(Legion::JSON.load(deliveries.pop(timeout: 2).first)).to eq(body)
    expect(described_class.recovery_record(id: entry[:id])).to include(status: 'delivered', record: nil, raw_line: nil, wire_record: nil)
    expect(described_class.status).to include(pending: 0, quarantined: 0, delivered_recoveries: 1)
    expect(described_class.retry_recovery(id: entry[:id])).to include(status: 'delivered')
    expect(deliveries).to be_empty
  end

  it 'preserves malformed input bytes while continuing and accepts an explicit complete repair' do
    raw = "{this was truncated\n"
    File.write(File.join(directory, 'legacy.jsonl'), raw + historical_line(payload: 'unblocked', exchange: 'recovered.task'))
    described_class.replay_async
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('unblocked')
    entry = described_class.recovery_entries.fetch(0)
    expect(Base64.strict_decode64(described_class.recovery_record(id: entry[:id])[:raw_line])).to eq(raw)

    described_class.repair_record(id: entry[:id], changes: { exchange: 'recovered.task', routing_key: 'run',
                                                            payload: { repaired: true }, encrypt: false })
    finish_replay
    expect(Legion::JSON.load(deliveries.pop(timeout: 2).first)).to eq(repaired: true)
    expect(described_class.recovery_record(id: entry[:id])[:status]).to eq('delivered')
  end

  it 'repairs an unroutable encrypted wire destination without changing ciphertext or its IV' do
    described_class.write(exchange: 'missing.route', routing_key: 'run', payload: 'original-ciphertext',
                          content_encoding: 'encrypted/cs', headers: { iv: 'original-iv', trace: 'retained' })
    described_class.write(exchange: 'recovered.task', routing_key: 'run', payload: 'following work')
    described_class.replay_async
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('following work')
    entry = described_class.recovery_entries.fetch(0)
    expect(entry[:error_class]).to eq('Legion::Transport::Spool::UnroutableRecordError')
    stub_const('Legion::Crypt', Module.new)
    expect(Legion::Crypt).not_to receive(:encrypt)

    expect do
      described_class.repair_record(id: entry[:id], changes: { headers: { iv: 'replacement-iv' } })
    end.to raise_error(ArgumentError)
    described_class.repair_record(id: entry[:id], changes: { exchange: 'recovered.task' })
    finish_replay
    payload, properties = deliveries.pop(timeout: 2)
    expect(payload).to eq('original-ciphertext')
    expect(properties.headers).to include(iv: 'original-iv', trace: 'retained')
    expect(properties.content_encoding).to eq('encrypted/cs')
  end

  it 'quarantines an invalid timestamp while replaying a numeric-string timestamp behind it' do
    described_class.write(exchange: 'recovered.task', routing_key: 'run', payload: 'retained-ciphertext',
                          timestamp: 'not-a-timestamp', content_encoding: 'encrypted/cs', headers: { iv: 'retained-iv' })
    described_class.write(exchange: 'recovered.task', routing_key: 'run', payload: 'healthy tail', timestamp: '0')

    described_class.replay_async
    finish_replay

    payload, properties = deliveries.pop(timeout: 2)
    expect(payload).to eq('healthy tail')
    expect(properties.timestamp).to eq(0)
    expect(deliveries).to be_empty
    expect(described_class.status).to include(pending: 0, quarantined: 1)
    entry = described_class.recovery_entries.fetch(0)
    retained = described_class.recovery_record(id: entry[:id]).fetch(:record)
    expect(retained[:envelope]).to include(timestamp: 'not-a-timestamp', headers: { iv: 'retained-iv' })
    expect(Base64.strict_decode64(retained[:payload])).to eq('retained-ciphertext')
  end

  it 'does not let a key-dependent record block plaintext work and retries readiness automatically' do
    crypt = Module.new
    stub_const('Legion::Crypt', crypt)
    ready = false
    checks = Queue.new
    allow(Legion::Settings).to receive(:dig).and_call_original
    allow(Legion::Settings).to receive(:dig).with(:crypt, :cs_encrypt_ready) {
      checks << true
      ready
    }
    allow(crypt).to receive(:encrypt) do |plaintext|
      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.encrypt
      cipher.key = 'k' * 32
      initialization_vector = cipher.random_iv
      ciphertext = cipher.update(plaintext) + cipher.final
      { enciphered_message: "gcm:#{Base64.strict_encode64(ciphertext)}:#{Base64.strict_encode64(cipher.auth_tag)}",
        iv:                 Base64.strict_encode64(initialization_vector) }
    end
    body = { secret: 'needs encryption', encrypt: true }
    File.write(File.join(directory, 'legacy.jsonl'),
               historical_line(payload: body, exchange: 'recovered.task') +
               historical_line(payload: 'available immediately', exchange: 'recovered.task'))
    described_class.replay_async
    expect(checks.pop(timeout: 2)).to be true
    expect(deliveries.pop(timeout: 2).first).to eq('available immediately')
    ready = true
    payload, properties = deliveries.pop(timeout: 3)
    prefix, ciphertext, tag = payload.split(':', 3)
    expect(prefix).to eq('gcm')
    decipher = OpenSSL::Cipher.new('aes-256-gcm')
    decipher.decrypt
    decipher.key = 'k' * 32
    decipher.iv = Base64.strict_decode64(properties.headers[:iv])
    decipher.auth_tag = Base64.strict_decode64(tag)
    expect(Legion::JSON.load(decipher.update(Base64.strict_decode64(ciphertext)) + decipher.final)).to eq(body)
    finish_replay
    expect(described_class.status).to include(pending: 0, waiting: 0, quarantined: 0)
  end

  it 'does not lose quarantined data if materializing the recovery entry fails' do
    File.write(File.join(directory, 'legacy.jsonl'), historical_line(payload: 'retained') +
                                                     historical_line(payload: 'later', exchange: 'recovered.task'))
    store = described_class.instance_variable_get(:@recovery_store)
    allow(store).to receive(:store).and_raise(Errno::ENOSPC)
    described_class.replay_async
    finish_replay
    expect(deliveries).to be_empty
    expect(described_class.count).to eq(2)
    expect(described_class.recovery_entries).to be_empty

    allow(store).to receive(:store).and_call_original
    described_class.replay_async
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('later')
    entry = described_class.recovery_entries.fetch(0)
    expect(described_class.recovery_record(id: entry[:id])[:record][:payload]).to eq('retained')
  end

  it 'does not resurrect a delivered repair when a stale journal marker is recovered after a crash' do
    File.write(File.join(directory, 'legacy.jsonl'), historical_line(payload: 'once repaired'))
    marker = nil
    allow(described_class).to receive(:compact_claim).and_wrap_original do |compact, **options|
      marker = File.read(options[:file])
      compact.call(**options)
    end
    described_class.replay_async
    finish_replay
    entry = described_class.recovery_entries.fetch(0)
    described_class.repair_record(id: entry[:id], changes: { exchange: 'recovered.task' })
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('once repaired')

    File.write(File.join(directory, 'interrupted-compaction.jsonl'), marker)
    described_class.replay_async
    finish_replay
    expect(deliveries).to be_empty
    expect(described_class.recovery_record(id: entry[:id])[:status]).to eq('delivered')
    expect(described_class.count).to eq(0)
  end
end
