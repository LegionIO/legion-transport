# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/tenant_provisioner'

RSpec.describe Legion::Transport::TenantProvisioner do
  let(:channel) do
    instance_double('Bunny::Channel', topic: nil,
                                      exchange_declare_without_recording_topology: nil,
                                      queue_declare_without_recording_topology: nil, queue_bind: nil,
                                      exchange_delete: nil, close: nil)
  end

  before do
    @previous_topology = Legion::Settings[:transport][:tenant_topology]
    Legion::Settings[:transport][:tenant_topology] = { enabled: true }
  end

  after do
    Legion::Settings[:transport][:tenant_topology] = @previous_topology
    Legion::Transport::Exchange.clear_cache
  end

  describe '.provision' do
    it 'provisions the same exchange and DLX used by built-in task producers and consumers', :rabbitmq do
      allow(channel).to receive(:register_exchange)
      allow(channel).to receive(:record_exchange)
      allow(channel).to receive(:register_queue)
      allow(channel).to receive(:record_queue)
      producer = Legion::Transport::Exchanges::Task.new(nil, tenant_id: 'alpha', channel: channel, no_declare: true)
      consumer = Legion::Transport::Queues::TaskUpdate.new(nil, tenant_id: 'alpha', channel: channel, no_declare: true)

      described_class.provision('alpha', channel: channel)

      expect(channel).to have_received(:topic).with(producer.name, durable: true, auto_delete: false)
      expect(producer.name).to eq('t.alpha.task')
      expect(consumer.name).to eq('t.alpha.task.update')
      dlx = consumer.options[:arguments][:'x-dead-letter-exchange']
      expect(dlx).to eq('t.alpha.task.dlx')
      expect(channel).to have_received(:exchange_declare_without_recording_topology)
        .with(dlx, 'fanout', durable: true, auto_delete: false)
      expect(channel).to have_received(:queue_bind).with("#{dlx}.queue", dlx, routing_key: '#')
    end

    it 'provisions scoped task, results and events exchanges rather than an unused plural tasks exchange' do
      described_class.provision('alpha', channel: channel)
      %w[task results events].each do |name|
        expect(channel).to have_received(:topic).with("t.alpha.#{name}", durable: true, auto_delete: false)
        expect(channel).to have_received(:queue_bind).with("t.alpha.#{name}.dlx.queue", "t.alpha.#{name}.dlx", routing_key: '#')
      end
      expect(channel).not_to have_received(:topic).with('t.alpha.tasks', anything)
    end

    it 'retains unprefixed resources when disabled or using the default tenant' do
      Legion::Settings[:transport][:tenant_topology][:enabled] = false
      described_class.provision('alpha', channel: channel)
      Legion::Settings[:transport][:tenant_topology][:enabled] = true
      described_class.provision('default', channel: channel)
      expect(channel).to have_received(:topic).with('task', durable: true, auto_delete: false).twice
      expect(channel).to have_received(:queue_bind).with('task.dlx.queue', 'task.dlx', routing_key: '#').twice
    end

    it 'does not close a caller-owned channel' do
      expect(channel).not_to receive(:close)
      described_class.provision('alpha', channel: channel)
    end

    it 'preserves the provisioning error even if owned channel cleanup fails' do
      primary = IOError.new('provision failed')
      cleanup = IOError.new('close failed')
      allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
      allow(channel).to receive(:topic).and_raise(primary)
      allow(channel).to receive(:close).and_raise(cleanup)
      expect(described_class).to receive(:handle_exception).with(cleanup, hash_including(handled: true))
      expect(described_class).to receive(:handle_exception).with(primary, hash_including(handled: false))
      expect { described_class.provision('alpha') }.to(raise_error { |error| expect(error).to equal(primary) })
    end
  end

  describe '.deprovision' do
    it 'only deletes tenant-prefixed exchanges, preserving old global names and all queued data' do
      expect(channel).not_to receive(:queue_delete)
      described_class.deprovision('alpha', channel: channel)
      %w[task results events].each do |name|
        expect(channel).to have_received(:exchange_delete).with("t.alpha.#{name}")
        expect(channel).to have_received(:exchange_delete).with("t.alpha.#{name}.dlx")
        expect(channel).not_to have_received(:exchange_delete).with(name)
      end
    end

    it 'never deletes configured shared exchanges or their shared DLX' do
      Legion::Settings[:transport][:tenant_topology][:shared_exchanges] = ['task']
      expect(channel).not_to receive(:exchange_delete).with('task')
      expect(channel).not_to receive(:exchange_delete).with('task.dlx')
      described_class.deprovision('alpha', channel: channel)
    end

    it 'refuses global resource deletion for missing, blank or default tenants' do
      expect(channel).not_to receive(:exchange_delete)
      [nil, '', 'default'].each { |tenant| described_class.deprovision(tenant, channel: channel) }
    end

    it 'does not delete anything when tenant topology is disabled' do
      Legion::Settings[:transport][:tenant_topology][:enabled] = false
      expect(channel).not_to receive(:exchange_delete)
      described_class.deprovision('alpha', channel: channel)
    end
  end
end
