# frozen_string_literal: true

require 'spec_helper'
require 'bunny'
require 'digest'
require 'securerandom'
require 'timeout'
require 'legion/transport/tenant_migration'

RSpec.describe Legion::Transport::TenantMigration, :rabbitmq do
  before do
    @previous_topology = Legion::Settings[:transport][:tenant_topology]
    Legion::Settings[:transport][:tenant_topology] = { enabled: true }
    @namespace = "legion.migration.spec.#{SecureRandom.hex(8)}"
    @tenant = "tenant-#{SecureRandom.hex(8)}"
    @source_name = "#{@namespace}.jobs"
    @exchange_name = "#{@namespace}.events"
    @queues = []
    @exchanges = []
    @migration_sessions = []
    @session = open_broker_session
    @channel = @session.create_channel
    allow(Legion::Transport::Connection).to receive(:create_dedicated_session) do
      open_broker_session.tap do |session|
        @migration_sessions << session
        @migration_session_hook&.call(session)
      end
    end
    Legion::Transport::TenantQuota.reset!
  end

  after do
    @migration_sessions.each { |session| Legion::Transport::Connection.send(:tear_down_session, session) if session.open? }
    if @session&.open?
      cleanup = @session.create_channel
      @queues.uniq.each { |name| cleanup.queue_delete(name) }
      @exchanges.uniq.reverse_each { |name| cleanup.exchange_delete(name) }
      Legion::Transport::Connection.send(:tear_down_session, @session)
    end
    Legion::Transport::Exchange.clear_cache
    Legion::Transport::TenantQuota.reset!
    Legion::Settings[:transport][:tenant_topology] = @previous_topology
  end

  def open_broker_session
    Bunny.new(ENV.fetch('RABBITMQ_URL', 'amqp://guest:guest@127.0.0.1:5672'), automatically_recover: false).start
  end

  def target_queue_name(name: @source_name, tenant: @tenant)
    Legion::Transport::TenantTopology.queue_name(name, tenant_id: tenant)
  end

  def target_exchange_name(name: @exchange_name, tenant: @tenant)
    Legion::Transport::TenantTopology.exchange_name(name, tenant_id: tenant)
  end

  def legacy_topology(with_dlx: false)
    @exchange = @channel.topic(@exchange_name, durable: true)
    @exchanges.push(@exchange_name, target_exchange_name)
    @queues.push(@source_name, target_queue_name)
    arguments = { 'x-queue-type' => 'classic' }
    if with_dlx
      @dlx_name = "#{@namespace}.dlx"
      @dlx = @channel.fanout(@dlx_name, durable: true)
      @dead_letters = @channel.queue("#{@dlx_name}.queue", durable: true, arguments: { 'x-queue-type' => 'classic' })
      @dead_letters.bind(@dlx)
      @exchanges.push(@dlx_name, target_exchange_name(name: @dlx_name))
      @queues.push(@dead_letters.name, "#{target_exchange_name(name: @dlx_name)}.queue")
      arguments['x-dead-letter-exchange'] = @dlx_name
    end
    @source = @channel.queue(@source_name, durable: true, arguments: arguments)
    @source.bind(@exchange, routing_key: 'work.#')
    @manifest = [{ name: @source_name, options: { durable: true, arguments: arguments },
                   bindings: [{ exchange: @exchange_name, exchange_type: 'topic', routing_key: 'work.#' }] }]
    @manifest.first[:source_dlx] = @dlx_name if with_dlx
  end

  def publish_source(payload: 'original ciphertext', exchange: @exchange, routing_key: 'work.invoke', **properties)
    @channel.confirm_select unless @channel.using_publisher_confirmations?
    exchange.publish(payload, **properties, routing_key: routing_key)
    expect(@channel.wait_for_confirms).to be true
  end

  def migrate(**)
    described_class.migrate(tenant_id: @tenant, queues: @manifest, **)
  end

  def target_queue(name: target_queue_name)
    @session.create_channel.queue(name, passive: true)
  end

  it 'moves queue and DLQ ciphertext exactly once per selected target while preserving routing and properties' do
    Legion::Settings[:transport][:tenant_topology][:prefix_format] = 'tenant/%<tenant_id>s/%<name>s/end'
    legacy_topology(with_dlx: true)
    unrelated = @channel.queue("#{@namespace}.unrelated", durable: true, arguments: { 'x-queue-type' => 'classic' })
    @queues << unrelated.name
    scoped_exchange = @channel.topic(target_exchange_name, durable: true)
    unrelated.bind(scoped_exchange, routing_key: 'work.#')
    transfer_name = "legion.tenant-migration.transfer.#{Digest::SHA256.hexdigest(@source_name)}"
    stale_transfer = @channel.fanout(transfer_name, auto_delete: true)
    unrelated.bind(stale_transfer)
    @exchanges << transfer_name
    wire_payload = "gcm:\x00\xFF:ciphertext:tag".b
    headers = { 'iv' => 'original-iv', 'tenant_id' => @tenant, 'nested' => { 'value' => 7 },
                'x-legion-publish-attempt' => 'preserved-original-attempt' }
    properties = { content_type: 'application/json', content_encoding: 'encrypted/cs', headers: headers,
                   message_id: 'message-1', correlation_id: 'parent-1', reply_to: 'reply.destination',
                   app_id: 'original-app', type: 'original-type', delivery_mode: 2, priority: 0 }
    publish_source(payload: wire_payload, **properties)
    publish_source(payload: wire_payload, exchange: @dlx, routing_key: 'work.retry', **properties.merge(message_id: 'dead-letter-1'))

    result = migrate

    expect(result).to include(status: :completed, moved: 2, errors: [])
    expect(result[:queues].map { |entry| entry[:remaining] }).to eq([0, 0])
    delivery, received, payload = target_queue.pop
    expect(payload.b).to eq(wire_payload)
    expect(delivery.routing_key).to eq('work.invoke')
    expect(received.to_h).to include(properties.except(:headers))
    expect(received.headers).to include(headers.merge(described_class::ORIGINAL_EXCHANGE_HEADER => @exchange.name))
    dlq_delivery, dlq_properties, dlq_payload = target_queue(name: "#{target_exchange_name(name: @dlx_name)}.queue").pop
    expect(dlq_payload.b).to eq(wire_payload)
    expect(dlq_delivery.routing_key).to eq('work.retry')
    expect(dlq_properties.headers).to include(headers)
    expect(dlq_properties.message_id).to eq('dead-letter-1')
    expect(unrelated.message_count).to eq(0)
    expect(@session.exchange_exists?(transfer_name)).to be false
    expect(@source.message_count).to eq(0)
    expect(@dead_letters.message_count).to eq(0)
    expect(@session.exchange_exists?(@exchange_name)).to be true
    expect(@session.exchange_exists?(@dlx_name)).to be true
    publish_source(payload: 'source topology survived')
    expect(@source.pop.last).to eq('source topology survived')
  end

  it 'uses registered declarations and retains bindings across wrappers of the same effective queue' do
    legacy_topology
    exchange = Legion::Transport::Exchange.new(@exchange_name, tenant_id: @tenant, channel: @channel)
    options = { tenant_id: @tenant, channel: @channel, arguments: { 'x-queue-type': 'classic', 'x-dead-letter-exchange': nil } }
    first = Legion::Transport::Queue.new(@source_name, **options)
    expect(first.bind(exchange, routing_key: 'work.first')).to equal(first)
    second = Legion::Transport::Queue.new(target_queue_name, **options)
    expect(second.bind(exchange.name, routing_key: 'work.second')).to equal(second)
    second.bind(exchange, routing_key: 'work.removed')
    second.unbind(exchange, routing_key: 'work.removed')
    publish_source(payload: 'first', routing_key: 'work.first')
    publish_source(payload: 'second', routing_key: 'work.second')

    result = described_class.migrate(tenant_id: @tenant)

    expect(result).to include(status: :completed, moved: 2)
    expect(result[:queues].first[:bindings].map { |entry| entry[:routing_key] }).to contain_exactly('work.first', 'work.second')
    expect([first.pop.last, first.pop.last]).to contain_exactly('first', 'second')
    publish_source(payload: 'future first', exchange: exchange, routing_key: 'work.first')
    publish_source(payload: 'future second', exchange: exchange, routing_key: 'work.second')
    publish_source(payload: 'removed binding', exchange: exchange, routing_key: 'work.removed')
    expect([second.pop.last, second.pop.last]).to contain_exactly('future first', 'future second')
    expect(second.message_count).to eq(0)
  end

  it 'plans counts and destinations without creating topology or consuming source data' do
    legacy_topology(with_dlx: true)
    publish_source
    publish_source(exchange: @dlx)

    result = migrate(dry_run: true)

    expect(result).to include(status: :planned, moved: 0, errors: [])
    expect(result[:queues].map { |entry| entry.values_at(:remaining, :consumers) }).to eq([[1, 0], [1, 0]])
    expect(@source.message_count).to eq(1)
    expect(@dead_letters.message_count).to eq(1)
    expect(@session.queue_exists?(target_queue_name)).to be false
    expect(@session.exchange_exists?(target_exchange_name)).to be false
    expect(@session.queue_exists?("legion.tenant-migration.lock.#{Digest::SHA256.hexdigest(@source_name)}")).to be false
    expect(@session.exchange_exists?("legion.tenant-migration.transfer.#{Digest::SHA256.hexdigest(@source_name)}")).to be false
  end

  it 'rejects truthy non-boolean dry-run input rather than silently changing execution semantics' do
    legacy_topology
    publish_source

    result = migrate(dry_run: 'false')

    expect(result).to include(status: :failed, moved: 0)
    expect(result[:errors].first[:error_class]).to eq('ArgumentError')
    expect(@source.message_count).to eq(1)
    expect(@session.queue_exists?(target_queue_name)).to be false
  end

  it 'refuses active source consumers before creating targets in both planning and execution' do
    legacy_topology
    consumer = @source.subscribe(manual_ack: true) { |_delivery, _properties, _payload| nil }

    [true, false].each do |dry_run|
      result = migrate(dry_run: dry_run)
      expect(result).to include(status: :blocked, moved: 0)
      expect(result[:queues].first[:consumers]).to eq(1)
      expect(@session.queue_exists?(target_queue_name)).to be false
    end
    expect(@session.queue_exists?(@source_name)).to be true
  ensure
    consumer&.cancel
  end

  it 'requeues messages whose explicit tenant headers contradict the requested owner' do
    legacy_topology
    publish_source(content_encoding: 'encrypted/cs', headers: { tenant_id: 'another-tenant', iv: 'untouched' })

    result = migrate

    expect(result).to include(status: :blocked, moved: 0)
    expect(result[:queues].first).to include(remaining: 1)
    expect(target_queue.message_count).to eq(0)
    _delivery, properties, payload = @source.pop
    expect(payload).to eq('original ciphertext')
    expect(properties.headers).to include('tenant_id' => 'another-tenant', 'iv' => 'untouched')
  end

  it 'does not let a matching header override contradictory cleartext payload identity' do
    legacy_topology
    payload = Legion::JSON.dump(tenant_id: 'another-tenant', body: 'unchanged')
    publish_source(payload: payload, content_encoding: 'identity', headers: { tenant_id: @tenant })

    expect(migrate).to include(status: :blocked, moved: 0)
    expect(@source.pop.last).to eq(payload)
    expect(target_queue.message_count).to eq(0)
  end

  it 'preserves opaque non-JSON bodies while still enforcing their tenant headers' do
    legacy_topology
    payload = "{opaque binary \xFF".b
    publish_source(payload: payload, headers: { tenant_id: @tenant })

    expect(migrate).to include(status: :completed, moved: 1)
    expect(target_queue.pop.last.b).to eq(payload)

    publish_source(payload: payload, headers: { tenant_id: 'another-tenant' })
    expect(migrate).to include(status: :blocked, moved: 0)
    expect(@source.pop.last.b).to eq(payload)
    expect(target_queue.message_count).to eq(0)
  end

  it 'retains the source until confirmation completes and safely retries an interrupted acknowledgement' do
    legacy_topology
    publish_source(message_id: 'stable-id', headers: { iv: 'stable-iv' })
    interrupt = true
    @migration_session_hook = lambda do |session|
      allow(session).to receive(:create_channel).and_wrap_original do |original|
        original.call.tap do |channel|
          allow(channel).to receive(:wait_for_confirms).and_wrap_original do |wait|
            confirmed = wait.call
            if interrupt
              interrupt = false
              channel.close
              raise IOError, 'connection interrupted after broker confirmation'
            end
            confirmed
          end
        end
      end
    end

    interrupted = migrate

    expect(interrupted).to include(status: :failed, moved: 0)
    expect(interrupted[:queues].first[:remaining]).to eq(1)
    expect(@source.message_count).to eq(1)
    expect(target_queue.message_count).to eq(1)
    expect(migrate).to include(status: :completed, moved: 1)
    expect(@source.message_count).to eq(0)
    # At-least-once delivery includes a duplicate when the confirmation is lost.
    copies = [target_queue.pop, target_queue.pop]
    expect(copies.map(&:last)).to eq(['original ciphertext', 'original ciphertext'])
    expect(copies.map { |entry| entry[1].message_id }).to eq(%w[stable-id stable-id])
  end

  it 'excludes a concurrent migration on another connection even when it requests a different tenant' do
    legacy_topology
    publish_source
    entered = Queue.new
    release = Queue.new
    first_session = true
    @migration_session_hook = lambda do |session|
      next unless first_session

      first_session = false
      allow(session).to receive(:create_channel).and_wrap_original do |original|
        original.call.tap do |channel|
          allow(channel).to receive(:wait_for_confirms).and_wrap_original do |wait|
            confirmed = wait.call
            entered << true
            release.pop
            confirmed
          end
        end
      end
    end
    owner = Thread.new { migrate }
    expect(entered.pop(timeout: 5)).to be true
    other_tenant = "#{@tenant}-other"
    @queues << target_queue_name(tenant: other_tenant)
    @exchanges << target_exchange_name(tenant: other_tenant)

    contender = described_class.migrate(tenant_id: other_tenant, queues: @manifest)

    expect(contender).to include(status: :blocked, moved: 0)
    expect(contender[:errors].first[:error]).to include('Another migration owns source')
    expect(@session.queue_exists?(target_queue_name(tenant: other_tenant))).to be false
    release << true
    expect(owner.join(5)).to eq(owner)
    expect(owner.value).to include(status: :completed, moved: 1)
    expect(target_queue.message_count).to eq(1)
  ensure
    release << true if release
    owner&.join(5)
  end

  it 'reports partial work at the message bound and resumes without deleting legacy resources' do
    legacy_topology
    publish_source(payload: 'first')
    publish_source(payload: 'second')

    first = migrate(max_messages: 1)

    expect(first).to include(status: :pending, moved: 1)
    expect(first[:queues].first).to include(remaining: 1, status: :pending)
    expect(migrate).to include(status: :completed, moved: 1)
    expect([target_queue.pop.last, target_queue.pop.last]).to eq(%w[first second])
    expect(@session.queue_exists?(@source_name)).to be true
  end

  it 'checks tenant byte quotas against the existing encoded wire payload' do
    legacy_topology
    payload = 'already-encrypted-wire-payload'
    Legion::Settings[:transport][:tenant_topology][:quotas] = { @tenant.to_sym => { bytes_per_second: payload.bytesize - 1 } }
    publish_source(payload: payload, content_encoding: 'encrypted/cs', headers: { iv: 'original-iv' })

    result = migrate

    expect(result).to include(status: :pending, moved: 0)
    expect(result[:queues].first[:remaining]).to eq(1)
    expect(target_queue.message_count).to eq(0)
    expect(@source.pop.last).to eq(payload)
  end

  it 'checks every source before touching data or creating any target' do
    legacy_topology
    publish_source
    missing = "#{@namespace}.missing"
    @manifest << { name: missing, options: { durable: true }, bindings: [] }
    @queues << target_queue_name(name: missing)

    result = migrate

    expect(result).to include(status: :blocked, moved: 0)
    expect(result[:errors].first[:error]).to include(missing)
    expect(@source.message_count).to eq(1)
    expect(@session.queue_exists?(target_queue_name)).to be false
  end

  it 'leaves incompatible target declarations and their contents intact' do
    legacy_topology
    existing = @channel.queue(target_queue_name, durable: true, arguments: { 'x-queue-type' => 'classic', 'x-max-priority' => 2 })
    @channel.default_exchange.publish('existing target data', routing_key: existing.name)
    publish_source
    @manifest.first[:options][:arguments]['x-max-priority'] = 3

    expect(migrate).to include(status: :failed, moved: 0)
    expect(existing.pop.last).to eq('existing target data')
    expect(@source.pop.last).to eq('original ciphertext')
  end
end

RSpec.describe Legion::Transport::TenantMigration do
  it 'rejects execution in lite mode instead of claiming broker data was migrated' do
    allow(Legion::Transport::Connection).to receive(:lite_mode?).and_return(true)
    allow(Legion::Transport::TenantTopology).to receive(:enabled?).and_return(true)
    expect(Legion::Transport::Connection).not_to receive(:create_dedicated_session)

    result = described_class.migrate(tenant_id: 'explicit-owner', queues: [{ name: 'legacy', options: {}, bindings: [] }])

    expect(result).to include(status: :blocked, moved: 0)
    expect(result[:errors].first[:error]).to include('Lite mode has no persisted broker topology')
  end

  it 'never obtains migration ownership from the ambient tenant context' do
    allow(Legion::Transport::TenantTopology).to receive(:current_tenant_id).and_return('ambient-tenant')
    expect(Legion::Transport::Connection).not_to receive(:create_dedicated_session)

    result = described_class.migrate(tenant_id: nil, queues: [{ name: 'legacy', options: {}, bindings: [] }])

    expect(result).to include(status: :blocked, moved: 0)
    expect(result[:errors].first[:error]).to include('explicit non-default tenant_id')
  end
end
