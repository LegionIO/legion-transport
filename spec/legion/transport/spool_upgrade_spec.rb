# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'fileutils'
require 'openssl'
require 'tmpdir'
require 'legion/transport/in_process'
require 'legion/transport/connection'
require 'legion/transport/publisher'

RSpec.describe Legion::Transport::Spool, 'historical spool upgrades' do
  let(:spool_dir) { Dir.mktmpdir('legion-spool-upgrade') }
  let(:channel) { Legion::Transport::InProcess::Channel.new }
  let(:deliveries) { Queue.new }
  let(:crypt) { Module.new }
  let(:key) { 'k' * 32 }
  let(:configured_encrypt) { false }
  let(:ready) { true }

  before do
    described_class.reset!
    described_class.setup(directory: spool_dir)
    @topology_settings = Legion::Settings[:transport][:tenant_topology]
    @message_settings = Legion::Settings[:transport][:messages]
    Legion::Settings[:transport][:tenant_topology] = { enabled: false }
    Legion::Settings[:transport][:messages] = @message_settings.merge(encrypt: configured_encrypt)
    Legion::Transport::Local.reset!
    Legion::Transport::TenantQuota.reset!
    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
    allow(Legion::Settings).to receive(:dig).and_call_original
    allow(Legion::Settings).to receive(:dig).with(:crypt, :cs_encrypt_ready).and_return(ready)
    stub_const('Legion::Crypt', crypt)
    allow(crypt).to receive(:encrypt) { |plaintext| encrypt_payload(plaintext: plaintext) }
  end

  after do
    described_class.reset!
    Legion::Transport::Local.reset!
    Legion::Settings[:transport][:tenant_topology] = @topology_settings
    Legion::Settings[:transport][:messages] = @message_settings
    Legion::Transport::TenantQuota.reset!
    FileUtils.rm_rf(spool_dir)
  end

  def finish_replay
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
    while (worker = described_class.instance_variable_get(:@replay_thread))
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(worker.join([remaining, 0].max)).to eq(worker)
    end
  end

  def subscribe_to_upgrade(exchange: 'task', routing_key: 'run', &callback)
    destination = channel.exchange(exchange, type: :topic)
    queue = Legion::Transport::InProcess::Queue.new(channel, "upgrade.#{exchange}.#{routing_key}")
    queue.bind(destination, routing_key: routing_key)
    queue.subscribe do |delivery, properties, payload|
      deliveries << [payload, properties, delivery]
      callback&.call(payload)
    end
  end

  def historical_record(payload:, exchange: 'task', routing_key: 'run', **envelope)
    { exchange: exchange, routing_key: routing_key, payload: payload, spooled_at: '2026-10-01T12:00:00Z' }.merge(envelope)
  end

  def seed_historical(records:)
    File.binwrite(File.join(spool_dir, 'legacy.jsonl'), records.map { |record| "#{Legion::JSON.dump(record)}\n" }.join)
  end

  def pending_bytes
    Dir.glob(File.join(spool_dir, '*.jsonl')).map { |path| File.binread(path) }.join
  end

  def persisted_records
    pending_bytes.lines.map { |line| Legion::JSON.load(line) }
  end

  def encrypt_payload(plaintext:)
    cipher = OpenSSL::Cipher.new('aes-256-gcm')
    cipher.encrypt
    cipher.key = key
    iv = cipher.random_iv
    ciphertext = cipher.update(plaintext) + cipher.final
    { enciphered_message: "gcm:#{Base64.strict_encode64(ciphertext)}:#{Base64.strict_encode64(cipher.auth_tag)}",
      iv:                 Base64.strict_encode64(iv) }
  end

  def decrypt_payload(payload:, initialization_vector:)
    prefix, ciphertext, tag = payload.split(':', 3)
    expect(prefix).to eq('gcm')
    cipher = OpenSSL::Cipher.new('aes-256-gcm')
    cipher.decrypt
    cipher.key = key
    cipher.iv = Base64.strict_decode64(initialization_vector)
    cipher.auth_tag = Base64.strict_decode64(tag)
    cipher.update(Base64.strict_decode64(ciphertext)) + cipher.final
  end

  def intercept_migration_file(&intercept)
    allow(File).to receive(:open).and_wrap_original do |original, path, *args, &block|
      next original.call(path, *args, &block) unless path.to_s.start_with?(spool_dir) && path.to_s.end_with?('.tmp')

      if block
        original.call(path, *args) do |file|
          intercept.call(file)
          block.call(file)
        end
      else
        original.call(path, *args).tap(&intercept)
      end
    end
  end

  it 'delivers historical raw Hash and String bodies without dropping false or zero metadata' do
    subscribe_to_upgrade
    body = { function: 'run', encrypt: false, tenant_id: 'alpha', enabled: false, attempt: 0 }
    seed_historical(records: [historical_record(payload: body, headers: { enabled: false, attempt: 0 },
                                                persistent: false, priority: 0, message_id: 'message-1', correlation_id: 'request-1'),
                              historical_record(payload: "raw string\nwith unicode é")])

    described_class.replay_async
    finish_replay

    payload, properties, delivery = deliveries.pop(timeout: 2)
    expect(Legion::JSON.load(payload)).to eq(body)
    expect(properties).to include(persistent: false, priority: 0, message_id: 'message-1', correlation_id: 'request-1',
                                  content_encoding: 'identity')
    expect(properties.headers).to include(enabled: false, attempt: 0)
    expect(delivery.exchange).to eq('task')
    expect(delivery.routing_key).to eq('run')
    expect(deliveries.pop(timeout: 2).first).to eq("raw string\nwith unicode é")
    expect(described_class.count).to eq(0)
  end

  it 'upgrades public drain records on disk before exposing their wire payload to a callback' do
    body = { function: 'run', encrypt: true }
    seed_historical(records: [historical_record(payload: body)])
    observed = []

    expect(described_class.drain do |record|
      disk_record = persisted_records.fetch(0)
      expect(disk_record[:spool_version]).to eq(2)
      expect(Base64.strict_decode64(disk_record.fetch(:payload))).to eq(record.fetch(:payload))
      expect(disk_record[:envelope]).to eq(record[:envelope])
      expect(disk_record[:spooled_at]).to eq('2026-10-01T12:00:00Z')
      observed << record
      false
    end).to be false

    record = observed.fetch(0)
    expect(Legion::JSON.load(decrypt_payload(payload: record[:payload], initialization_vector: record[:envelope][:headers][:iv]))).to eq(body)
    expect(described_class.count).to eq(1)
    subscribe_to_upgrade
    described_class.replay_async
    finish_replay
    payload, properties = deliveries.pop(timeout: 2)
    expect(payload).to eq(record[:payload])
    expect(properties.headers[:iv]).to eq(record[:envelope][:headers][:iv])
    expect(described_class.count).to eq(0)
  end

  it 'resolves a historical exchange class using the saved tenant rather than the replay thread tenant' do
    Legion::Settings[:transport][:tenant_topology] = { enabled: true }
    allow(Legion::Transport::TenantTopology).to receive(:current_tenant_id).and_return('beta')
    subscribe_to_upgrade(exchange: 't.alpha.task')
    body = { function: 'run', tenant_id: 'alpha', encrypt: false }
    seed_historical(records: [historical_record(exchange: 'Legion::Transport::Exchanges::Task', payload: body)])

    described_class.replay_async
    finish_replay

    payload, _properties, delivery = deliveries.pop(timeout: 2)
    expect(Legion::JSON.load(payload)).to eq(body)
    expect(delivery.exchange).to eq('t.alpha.task')
    expect(described_class.count).to eq(0)
  end

  it 'automatically resumes when an extension exchange class loads after transport startup' do
    subscribe_to_upgrade
    name = 'Legion::Transport::Exchanges::LateSpoolUpgrade'
    seed_historical(records: [historical_record(exchange: name, payload: 'extension payload')])
    waiting = Queue.new
    allow(described_class).to receive(:handle_exception).and_wrap_original do |handle, error, **options|
      waiting << error if error.is_a?(described_class::LegacyDependencyNotReady)
      handle.call(error, **options)
    end
    described_class.replay_async
    expect(waiting.pop(timeout: 2)).to be_a(described_class::LegacyDependencyNotReady)
    expect(deliveries).to be_empty
    klass = Class.new(Legion::Transport::Exchange) do
      def exchange_name
        'task'
      end
    end
    stub_const(name, klass)

    expect(deliveries.pop(timeout: 3).first).to eq('extension payload')
    finish_replay
    expect(described_class.count).to eq(0)
  end

  it 'preserves order and existing wire bytes in a file mixing historical and v2 records' do
    subscribe_to_upgrade
    described_class.write(exchange: 'task', routing_key: 'run', payload: 'confirmed-prefix')
    described_class.write(exchange: 'task', routing_key: 'run', payload: 'existing-wire',
                          content_encoding: 'encrypted/cs', headers: { iv: 'existing-iv' })
    path = Dir.glob(File.join(spool_dir, '*.jsonl')).fetch(0)
    prefix_line, wire_line = File.readlines(path)
    first = "#{Legion::JSON.dump(historical_record(payload: 'first'))}\n"
    last = "#{Legion::JSON.dump(historical_record(payload: 'last'))}\n"
    File.binwrite(path, prefix_line + first + wire_line + last)

    described_class.replay_async
    finish_replay

    received = 4.times.map { deliveries.pop(timeout: 2) }
    expect(received.map(&:first)).to eq(%w[confirmed-prefix first existing-wire last])
    expect(received[2][1]).to include(content_encoding: 'encrypted/cs', headers: include(iv: 'existing-iv'))
    expect(described_class.count).to eq(0)
  end

  it 'honors a raw payload encryption requirement even when the current default is plaintext' do
    subscribe_to_upgrade
    body = { secret: 'sensitive', encrypt: true }
    seed_historical(records: [historical_record(payload: body)])

    described_class.replay_async
    finish_replay

    payload, properties = deliveries.pop(timeout: 2)
    expect(properties.content_encoding).to eq('encrypted/cs')
    expect(payload).not_to include('sensitive')
    expect(Legion::JSON.load(decrypt_payload(payload: payload, initialization_vector: properties.headers[:iv]))).to eq(body)
    expect(described_class.count).to eq(0)
  end

  it 'retains the raw file without publishing when encryption fails and retries after the key recovers' do
    subscribe_to_upgrade
    body = { secret: 'never publish in the clear', encrypt: true }
    seed_historical(records: [historical_record(payload: body)])
    original = pending_bytes
    allow(crypt).to receive(:encrypt).and_raise(OpenSSL::Cipher::CipherError, 'key unavailable')

    described_class.replay_async
    finish_replay
    expect(deliveries).to be_empty
    expect(pending_bytes).to eq(original)

    allow(crypt).to receive(:encrypt) { |plaintext| encrypt_payload(plaintext: plaintext) }
    described_class.replay_async
    finish_replay
    payload, properties = deliveries.pop(timeout: 2)
    expect(properties.content_encoding).to eq('encrypted/cs')
    expect(Legion::JSON.load(decrypt_payload(payload: payload, initialization_vector: properties.headers[:iv]))).to eq(body)
    expect(described_class.count).to eq(0)
  end

  it 'treats a saved IV as evidence to encrypt the raw body again, not as its current ciphertext IV' do
    subscribe_to_upgrade
    body = { secret: 'saved raw plaintext' }
    seed_historical(records: [historical_record(payload: body, headers: { iv: 'stale-attempt-iv', traced: false })])

    described_class.replay_async
    finish_replay

    payload, properties = deliveries.pop(timeout: 2)
    expect(properties.content_encoding).to eq('encrypted/cs')
    expect(properties.headers[:iv]).not_to eq('stale-attempt-iv')
    expect(properties.headers[:traced]).to be false
    expect(Legion::JSON.load(decrypt_payload(payload: payload, initialization_vector: properties.headers[:iv]))).to eq(body)
    expect(described_class.count).to eq(0)
  end

  context 'when encryption is configured but the cluster secret is not ready' do
    let(:configured_encrypt) { true }
    let(:ready) { false }

    it 'preserves an explicit false payload policy without waiting for a secret' do
      subscribe_to_upgrade
      body = { function: 'public', encrypt: false }
      seed_historical(records: [historical_record(payload: body)])

      described_class.replay_async
      finish_replay

      payload, properties = deliveries.pop(timeout: 2)
      expect(Legion::JSON.load(payload)).to eq(body)
      expect(properties.content_encoding).to eq('identity')
      expect(properties.headers).not_to have_key(:iv)
      expect(described_class.count).to eq(0)
    end

    it 'replays the historical cluster-secret bootstrap request as plaintext' do
      subscribe_to_upgrade(exchange: 'node', routing_key: 'node.crypt.push_cluster_secret')
      body = { function: 'push_cluster_secret', runner_class: 'Legion::Extensions::Node::Runners::Crypt',
               node_name: 'worker', queue_name: 'node.worker', public_key: 'public-key' }
      seed_historical(records: [historical_record(exchange: 'Legion::Transport::Exchanges::Node',
                                                  routing_key: 'node.crypt.push_cluster_secret', payload: body)])

      described_class.replay_async
      finish_replay

      payload, properties = deliveries.pop(timeout: 2)
      expect(Legion::JSON.load(payload)).to eq(body)
      expect(properties.content_encoding).to eq('identity')
      expect(properties.headers).not_to have_key(:iv)
      expect(described_class.count).to eq(0)
    end

    it 'retries automatically until readiness changes without publishing plaintext or needing another trigger' do
      subscribe_to_upgrade
      body = { secret: 'waiting for a real key' }
      seed_historical(records: [historical_record(payload: body)])
      original = pending_bytes
      readiness_checks = Queue.new
      encryption_ready = false
      allow(Legion::Settings).to receive(:dig).with(:crypt, :cs_encrypt_ready) do
        readiness_checks << true
        encryption_ready
      end

      described_class.replay_async
      2.times { expect(readiness_checks.pop(timeout: 3)).to be true }
      expect(deliveries).to be_empty
      expect(pending_bytes).to eq(original)
      encryption_ready = true

      received = deliveries.pop(timeout: 3)
      expect(received).not_to be_nil
      payload, properties = received
      expect(properties.content_encoding).to eq('encrypted/cs')
      expect(Legion::JSON.load(decrypt_payload(payload: payload, initialization_vector: properties.headers[:iv]))).to eq(body)
      finish_replay
      expect(described_class.count).to eq(0)
    end
  end

  context 'when encryption is configured and ready' do
    let(:configured_encrypt) { true }

    it 'encrypts ciphertext-looking legacy Strings instead of guessing they are already encoded' do
      subscribe_to_upgrade
      body = 'gcm:literal-user-data:not-an-authentication-tag'
      seed_historical(records: [historical_record(payload: body)])

      described_class.replay_async
      finish_replay

      payload, properties = deliveries.pop(timeout: 2)
      expect(payload).not_to eq(body)
      expect(properties.content_encoding).to eq('encrypted/cs')
      expect(decrypt_payload(payload: payload, initialization_vector: properties.headers[:iv])).to eq(body)
      expect(described_class.count).to eq(0)
    end
  end

  it 'retains the original bytes and publishes nothing when replacement rename fails, then retries safely' do
    subscribe_to_upgrade
    seed_historical(records: [historical_record(payload: 'first'), historical_record(payload: 'second')])
    original = pending_bytes
    failed = false
    allow(File).to receive(:rename).and_wrap_original do |rename, source, destination|
      if destination.start_with?(spool_dir) && File.exist?(destination)
        failed = true
        raise Errno::EIO, 'migration replacement failed'
      end
      rename.call(source, destination)
    end

    described_class.replay_async
    finish_replay
    expect(failed).to be true
    expect(deliveries).to be_empty
    expect(pending_bytes).to eq(original)

    allow(File).to receive(:rename).and_call_original
    described_class.replay_async
    finish_replay
    expect(2.times.map { deliveries.pop(timeout: 2).first }).to eq(%w[first second])
    expect(described_class.count).to eq(0)
  end

  %i[write fsync].each do |operation|
    it "keeps the historical file and publishes nothing if migration #{operation} fails" do
      subscribe_to_upgrade
      seed_historical(records: [historical_record(payload: 'retained')])
      original = pending_bytes
      failed = false
      intercept_migration_file do |file|
        allow(file).to receive(operation) do
          failed = true
          raise Errno::ENOSPC, 'migration persistence failed'
        end
      end

      described_class.replay_async
      finish_replay
      expect(failed).to be true
      expect(deliveries).to be_empty
      expect(pending_bytes).to eq(original)

      allow(File).to receive(:open).and_call_original
      described_class.replay_async
      finish_replay
      expect(deliveries.pop(timeout: 2).first).to eq('retained')
      expect(described_class.count).to eq(0)
    end
  end

  it 'retains every original record when shutdown interrupts a partially written migration' do
    subscribe_to_upgrade
    seed_historical(records: [historical_record(payload: 'first'), historical_record(payload: 'second')])
    original = pending_bytes
    entered = Queue.new
    release = Queue.new
    intercept_migration_file do |file|
      allow(file).to receive(:write).and_wrap_original do |write, *args|
        result = write.call(*args)
        entered << true
        release.pop
        result
      end
    end

    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    described_class.stop_replay(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.02)
    finish_replay
    expect(deliveries).to be_empty
    expect(pending_bytes).to eq(original)

    allow(File).to receive(:open).and_call_original
    described_class.replay_async
    finish_replay
    expect(2.times.map { deliveries.pop(timeout: 2).first }).to eq(%w[first second])
    expect(described_class.count).to eq(0)
  ensure
    release << true if release
  end

  it 'reuses the persisted ciphertext and IV after restarting before the broker can accept it' do
    subscribe_to_upgrade
    body = { secret: 'encrypt exactly once', encrypt: true }
    seed_historical(records: [historical_record(payload: body)])
    entered = Queue.new
    release = Queue.new
    allow(Legion::Transport::Connection).to receive(:channel) do
      entered << true
      release.pop
      channel
    end

    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    persisted = persisted_records.fetch(0)
    expect(persisted[:spool_version]).to eq(2)
    ciphertext = Base64.strict_decode64(persisted.fetch(:payload))
    iv = persisted.fetch(:envelope).fetch(:headers).fetch(:iv)
    expect(Legion::JSON.load(decrypt_payload(payload: ciphertext, initialization_vector: iv))).to eq(body)
    expect(deliveries).to be_empty
    original = pending_bytes
    described_class.reset!
    described_class.setup(directory: spool_dir)
    expect(pending_bytes).to eq(original)

    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
    allow(crypt).to receive(:encrypt).and_raise(IOError, 'a restart must not need the original encryption key')
    described_class.replay_async
    finish_replay
    payload, properties = deliveries.pop(timeout: 2)
    expect(payload).to eq(ciphertext)
    expect(properties.headers[:iv]).to eq(iv)
    expect(described_class.count).to eq(0)
  ensure
    release << true if release
  end

  it 'keeps an append made by another thread while legacy encryption is blocked' do
    subscribe_to_upgrade
    body = { secret: 'first', encrypt: true }
    seed_historical(records: [historical_record(payload: body)])
    entered = Queue.new
    release = Queue.new
    allow(crypt).to receive(:encrypt) do |plaintext|
      entered << true
      release.pop
      encrypt_payload(plaintext: plaintext)
    end

    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    writer = Thread.new { described_class.write(exchange: 'task', routing_key: 'run', payload: 'second') }
    expect(writer.join(2)).to eq(writer)
    expect(writer.value).to be true
    expect(described_class.count).to eq(2)
    expect(deliveries).to be_empty
    release << true
    finish_replay

    payload, properties = deliveries.pop(timeout: 2)
    expect(Legion::JSON.load(decrypt_payload(payload: payload, initialization_vector: properties.headers[:iv]))).to eq(body)
    expect(deliveries.pop(timeout: 2).first).to eq('second')
    expect(described_class.count).to eq(0)
  ensure
    release << true if release
    writer&.kill&.join(1)
  end

  it 'prevents an independent drainer from claiming the replacement inode while its owner is delivering' do
    entered = Queue.new
    release = Queue.new
    subscribe_to_upgrade do |_payload|
      entered << true
      release.pop
    end
    seed_historical(records: [historical_record(payload: 'owned')])
    described_class.replay_async
    expect(entered.pop(timeout: 2)).to be true
    expect(persisted_records.fetch(0)[:spool_version]).to eq(2)
    stolen = Queue.new
    drainer = Thread.new do
      described_class.drain do |record|
        stolen << record
        true
      end
    end
    expect(drainer.join(2)).to eq(drainer)
    expect(drainer.value).to be false
    expect(stolen).to be_empty
    expect(described_class.count).to eq(1)
    release << true
    finish_replay
    expect(deliveries.pop(timeout: 2).first).to eq('owned')
    expect(deliveries).to be_empty
    expect(described_class.count).to eq(0)
  ensure
    release << true if release
    drainer&.kill&.join(1)
  end

  it 'retains the original lost-destination Direct fallback with a concrete error instead of guessing an exchange' do
    subscribe_to_upgrade
    seed_historical(records: [historical_record(exchange: 'Legion::Transport::Messages::Direct',
                                                payload:  { secret: 'destination lost', encrypt: false })])
    original = pending_bytes
    errors = Queue.new
    allow(described_class).to receive(:handle_exception).and_wrap_original do |handle, error, **options|
      errors << error
      handle.call(error, **options)
    end

    described_class.replay_async
    finish_replay

    expect(deliveries).to be_empty
    expect(pending_bytes).to eq(original)
    error = errors.pop(timeout: 2)
    expect(error).to be_a(described_class::LegacyRecordError)
    expect(error.message).to match(/exchange|destination/i)
    expect(described_class.count).to eq(1)
  end

  it 'does not publish a valid prefix when a malformed historical tail cannot be migrated' do
    subscribe_to_upgrade
    malformed = historical_record(payload: 'missing').except(:payload)
    seed_historical(records: [historical_record(payload: 'valid'), malformed])
    original = pending_bytes

    described_class.replay_async
    finish_replay

    expect(deliveries).to be_empty
    expect(pending_bytes).to eq(original)
    expect(described_class.count).to eq(2)
  end
end
