# frozen_string_literal: true

require 'spec_helper'
require 'bunny'
require 'securerandom'
require 'timeout'
require 'legion/transport/exchanges/task'

RSpec.describe 'Tenant topology broker isolation', :rabbitmq do
  before do
    @previous_topology = Legion::Settings[:transport][:tenant_topology]
    Legion::Settings[:transport][:tenant_topology] = { enabled: true }
    @namespace = SecureRandom.hex(8)
    @queues = []
    @exchanges = []
    @session = Bunny.new(ENV.fetch('RABBITMQ_URL', 'amqp://guest:guest@127.0.0.1:5672'), automatically_recover: false).start
    allow(Legion::Transport::Connection).to receive(:session).and_return(@session)
    allow(Legion::Transport::Connection).to receive(:channel) { @session.create_channel }
    Legion::Transport::Exchange.clear_cache
  end

  after do
    if @session&.open?
      channel = @session.create_channel
      @queues.uniq.each { |name| channel.queue_delete(name) }
      @exchanges.uniq.reverse_each { |name| channel.exchange_delete(name) }
      @session.close
    end
    Legion::Transport::Exchange.clear_cache
    Legion::Settings[:transport][:tenant_topology] = @previous_topology
  end

  def broker_tenant(label:)
    "#{@namespace}-#{label}"
  end

  def task_topology(tenant_id:)
    exchange = Legion::Transport::Exchanges::Task.new(nil, tenant_id: tenant_id)
    @exchanges << exchange.name
    dlx = Legion::Transport::TenantTopology.exchange_name('task.dlx', tenant_id: tenant_id)
    @exchanges << dlx
    @queues << "#{dlx}.queue"
    queue = Legion::Transport::Queues::TaskUpdate.new(nil, tenant_id: tenant_id, durable: false, exclusive: true,
                                                      arguments: { 'x-queue-type': 'classic' })
    @queues << queue.name
    queue.bind('task', routing_key: 'work')
    [exchange, queue, dlx]
  end

  def confirmed_publish(exchange:, payload:, routing_key: 'work')
    exchange.channel.confirm_select
    exchange.publish(payload, routing_key: routing_key)
    expect(exchange.channel.wait_for_confirms).to be(true)
  end

  it 'delivers identical routing keys only to the matching tenant consumer' do
    alpha = broker_tenant(label: 'alpha')
    beta = broker_tenant(label: 'beta')
    allow(Legion::Transport::TenantTopology).to receive(:current_tenant_id).and_return(alpha)
    alpha_exchange, alpha_queue = task_topology(tenant_id: alpha)
    allow(Legion::Transport::TenantTopology).to receive(:current_tenant_id).and_return(beta)
    beta_exchange, beta_queue = task_topology(tenant_id: beta)
    deliveries = Queue.new
    alpha_queue.subscribe { |_delivery, _properties, payload| deliveries << [:alpha, payload] }
    beta_queue.subscribe { |_delivery, _properties, payload| deliveries << [:beta, payload] }

    confirmed_publish(exchange: alpha_exchange, payload: 'alpha message')
    confirmed_publish(exchange: beta_exchange, payload: 'beta message')

    received = Timeout.timeout(5) { [deliveries.pop, deliveries.pop] }
    expect(received).to contain_exactly([:alpha, 'alpha message'], [:beta, 'beta message'])
  end

  it 'delivers rejected source messages to the same tenant dead-letter queue' do
    exchange, queue, dlx = task_topology(tenant_id: broker_tenant(label: 'dlx'))
    deliveries = Queue.new
    dead_letters = @session.create_channel.queue("#{dlx}.queue", passive: true)
    dead_letters.subscribe { |_delivery, _properties, payload| deliveries << payload }
    queue.subscribe(manual_ack: true) { |delivery, _properties, _payload| queue.reject(delivery.delivery_tag, requeue: false) }

    confirmed_publish(exchange: exchange, payload: 'rejected payload')

    expect(Timeout.timeout(5) { deliveries.pop }).to eq('rejected payload')
  end

  it 'preserves existing queue contents when a consumer requests incompatible options' do
    tenant = broker_tenant(label: 'queue-mismatch')
    name = Legion::Transport::TenantTopology.queue_name('retained', tenant_id: tenant)
    channel = @session.create_channel
    queue = channel.queue(name, durable: true, arguments: { 'x-queue-type': 'classic', 'x-max-priority': 2 })
    @queues << queue.name
    channel.confirm_select
    channel.default_exchange.publish('retained payload', routing_key: queue.name)
    expect(channel.wait_for_confirms).to be(true)

    expect do
      Legion::Transport::Queue.new('retained', tenant_id: tenant, durable: true,
                                   arguments: { 'x-queue-type': 'classic', 'x-max-priority': 5,
                                                'x-dead-letter-exchange': nil })
    end.to raise_error(Bunny::PreconditionFailed)

    expect(queue.pop.last).to eq('retained payload')
  end

  it 'preserves exchange bindings after an incompatible exchange declaration' do
    tenant = broker_tenant(label: 'exchange-mismatch')
    name = Legion::Transport::TenantTopology.exchange_name('retained', tenant_id: tenant)
    channel = @session.create_channel
    exchange = channel.topic(name, durable: false)
    @exchanges << name
    queue = channel.queue('', exclusive: true)
    @queues << queue.name
    queue.bind(exchange, routing_key: 'work')

    expect do
      Legion::Transport::Exchange.new('retained', tenant_id: tenant, type: 'fanout', durable: false)
    end.to raise_error(Bunny::PreconditionFailed)

    confirmed_publish(exchange: exchange, payload: 'binding retained')
    expect(queue.pop.last).to eq('binding retained')
  end

  it 'preserves incompatible DLX resources and dead-letter contents' do
    tenant = broker_tenant(label: 'dlx-mismatch')
    name = Legion::Transport::TenantTopology.exchange_name('task.dlx', tenant_id: tenant)
    channel = @session.create_channel
    exchange = channel.topic(name, durable: true)
    @exchanges << name
    queue = channel.queue("#{name}.queue", durable: true, arguments: { 'x-queue-type': 'classic' })
    @queues << queue.name
    queue.bind(exchange, routing_key: '#')
    confirmed_publish(exchange: exchange, payload: 'dead letter retained')

    expect do
      Legion::Transport::Queues::TaskUpdate.new(nil, tenant_id: tenant)
    end.to raise_error(Bunny::PreconditionFailed)

    expect(queue.pop.last).to eq('dead letter retained')
  end
end
