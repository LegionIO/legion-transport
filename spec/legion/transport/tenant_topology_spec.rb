# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/tenant_topology'
require 'legion/transport/exchanges/task'

RSpec.describe Legion::Transport::TenantTopology do
  before do
    Legion::Settings[:transport][:tenant_topology] ||= {}
    Legion::Settings[:transport][:tenant_topology][:enabled] = false
    Legion::Settings[:transport][:tenant_topology].delete(:shared_exchanges)
    Legion::Settings[:transport][:tenant_topology].delete(:prefix_format)
  end

  after do
    Legion::Settings[:transport][:tenant_topology][:enabled] = false
    Legion::Settings[:transport][:tenant_topology].delete(:shared_exchanges)
    Legion::Settings[:transport][:tenant_topology].delete(:prefix_format)
  end

  describe '.enabled?' do
    context 'when disabled (default)' do
      it 'returns false' do
        expect(described_class.enabled?).to be false
      end
    end

    context 'when enabled via settings' do
      before { Legion::Settings[:transport][:tenant_topology][:enabled] = true }

      it 'returns true' do
        expect(described_class.enabled?).to be true
      end
    end
  end

  describe '.shared?' do
    it 'returns true for exact legion.control match' do
      expect(described_class.shared?('legion.control')).to be true
    end

    it 'returns true for legion.control sub-path' do
      expect(described_class.shared?('legion.control.sub')).to be true
    end

    it 'returns true for legion.health prefix' do
      expect(described_class.shared?('legion.health')).to be true
    end

    it 'returns true for legion.audit prefix' do
      expect(described_class.shared?('legion.audit')).to be true
    end

    it 'returns false for non-shared names' do
      expect(described_class.shared?('tasks')).to be false
      expect(described_class.shared?('results')).to be false
    end

    it 'does not over-match names that merely start with a shared prefix string' do
      expect(described_class.shared?('legion.controlled')).to be false
      expect(described_class.shared?('legion.controls')).to be false
    end

    context 'when shared_exchanges is configured in settings' do
      before do
        Legion::Settings[:transport][:tenant_topology][:shared_exchanges] = %w[custom.shared another.shared]
      end

      it 'uses configured list instead of defaults' do
        expect(described_class.shared?('custom.shared')).to be true
        expect(described_class.shared?('another.shared')).to be true
        expect(described_class.shared?('custom.shared.sub')).to be true
        expect(described_class.shared?('legion.control')).to be false
      end
    end
  end

  describe '.exchange_name' do
    context 'when disabled' do
      it 'passes name through unchanged regardless of tenant_id' do
        expect(described_class.exchange_name('tasks', tenant_id: 'abc123')).to eq('tasks')
      end

      it 'passes name through unchanged with no tenant_id' do
        expect(described_class.exchange_name('tasks')).to eq('tasks')
      end
    end

    context 'when enabled' do
      before { Legion::Settings[:transport][:tenant_topology][:enabled] = true }

      it 'prefixes with tenant_id when provided' do
        expect(described_class.exchange_name('tasks', tenant_id: 'abc123')).to eq('t.abc123.tasks')
      end

      it 'returns base name when tenant_id is nil' do
        expect(described_class.exchange_name('tasks', tenant_id: nil)).to eq('tasks')
      end

      it 'returns base name when tenant_id is "default"' do
        expect(described_class.exchange_name('tasks', tenant_id: 'default')).to eq('tasks')
      end

      it 'does not prefix shared exchanges' do
        expect(described_class.exchange_name('legion.control', tenant_id: 'abc123')).to eq('legion.control')
        expect(described_class.exchange_name('legion.health', tenant_id: 'abc123')).to eq('legion.health')
        expect(described_class.exchange_name('legion.audit', tenant_id: 'abc123')).to eq('legion.audit')
      end

      it 'does not prefix shared exchange subnames' do
        expect(described_class.exchange_name('legion.control.something', tenant_id: 'abc123')).to eq('legion.control.something')
      end

      it 'prefixes exchanges that merely start with a shared prefix string (not a real subpath)' do
        expect(described_class.exchange_name('legion.controlled', tenant_id: 'abc123')).to eq('t.abc123.legion.controlled')
      end

      context 'when prefix_format is configured' do
        before do
          Legion::Settings[:transport][:tenant_topology][:prefix_format] = 'tenants/%<tenant_id>s/%<name>s'
        end

        it 'uses the configured prefix format' do
          expect(described_class.exchange_name('tasks', tenant_id: 'abc123')).to eq('tenants/abc123/tasks')
        end
      end
    end
  end

  describe '.queue_name' do
    context 'when disabled' do
      it 'passes name through unchanged regardless of tenant_id' do
        expect(described_class.queue_name('my.queue', tenant_id: 'abc123')).to eq('my.queue')
      end
    end

    context 'when enabled' do
      before { Legion::Settings[:transport][:tenant_topology][:enabled] = true }

      it 'prefixes with tenant_id when provided' do
        expect(described_class.queue_name('my.queue', tenant_id: 'abc123')).to eq('t.abc123.my.queue')
      end

      it 'returns base name when tenant_id is nil' do
        expect(described_class.queue_name('my.queue', tenant_id: nil)).to eq('my.queue')
      end

      it 'returns base name when tenant_id is "default"' do
        expect(described_class.queue_name('my.queue', tenant_id: 'default')).to eq('my.queue')
      end
    end
  end

  describe '.current_tenant_id' do
    context 'when Legion::TenantContext is not defined' do
      it 'returns nil' do
        expect(described_class.current_tenant_id).to be_nil
      end
    end

    context 'when Legion::TenantContext is defined' do
      before do
        stub_const('Legion::TenantContext', Module.new do
          def self.current
            'ctx123'
          end
        end)
      end

      it 'reads the active Legion tenant context' do
        expect(described_class.current_tenant_id).to eq('ctx123')
      end
    end

    context 'when Legion::TenantContext raises' do
      before do
        stub_const('Legion::TenantContext', Module.new do
          def self.current
            raise StandardError, 'context error'
          end
        end)
      end

      it 'returns nil' do
        expect(described_class.current_tenant_id).to be_nil
      end
    end
  end

  describe '.exchange_name with current_tenant_id fallback' do
    context 'when enabled and TenantContext provides tenant_id' do
      before do
        Legion::Settings[:transport][:tenant_topology][:enabled] = true
        stub_const('Legion::TenantContext', Module.new do
          def self.current
            'ctx456'
          end
        end)
      end

      it 'uses current_tenant_id when no explicit tenant_id given' do
        expect(described_class.exchange_name('tasks')).to eq('t.ctx456.tasks')
      end

      it 'uses explicit tenant_id over current_tenant_id' do
        expect(described_class.exchange_name('tasks', tenant_id: 'override')).to eq('t.override.tasks')
      end
    end
  end

  describe 'idempotent resource naming' do
    before { Legion::Settings[:transport][:tenant_topology][:enabled] = true }

    it 'does not prefix an already resolved exchange or queue twice' do
      expect(described_class.exchange_name('t.alpha.task', tenant_id: 'alpha')).to eq('t.alpha.task')
      expect(described_class.queue_name('t.alpha.task.update', tenant_id: 'alpha')).to eq('t.alpha.task.update')
    end

    it 'preserves the default exchange and server-named queue requests' do
      expect(described_class.exchange_name('', tenant_id: 'alpha')).to eq('')
      expect(described_class.queue_name('', tenant_id: 'alpha')).to eq('')
    end

    it 'recognizes resolved names with a configured prefix and suffix' do
      Legion::Settings[:transport][:tenant_topology][:prefix_format] = 'tenant/%<tenant_id>s/%<name>s/end'
      name = described_class.queue_name('jobs', tenant_id: 'alpha')
      expect(name).to eq('tenant/alpha/jobs/end')
      expect(described_class.queue_name(name, tenant_id: 'alpha')).to eq(name)
    end
  end

  describe 'offline exchange declarations' do
    before do
      Legion::Settings[:transport][:tenant_topology][:enabled] = true
      expect(Legion::Transport::Connection).not_to receive(:channel)
      expect(Legion::Transport::Connection).not_to receive(:session)
    end

    it 'resolves built-in class and explicit names before any network construction' do
      expect(Legion::Transport::Exchanges::Task.declaration(tenant_id: 'alpha')).to eq(name: 't.alpha.task', type: 'topic')
      expect(Legion::Transport::Exchanges::Task.declaration(name: 'custom', tenant_id: 'beta'))
        .to eq(name: 't.beta.custom', type: 'topic')
    end

    it 'respects inherited name and default option overrides' do
      parent = Class.new(Legion::Transport::Exchange) do
        def exchange_name
          'custom.events'
        end

        def default_options
          super.merge(type: 'fanout')
        end
      end
      klass = Class.new(parent)
      expect(klass.declaration(tenant_id: 'alpha')).to eq(name: 't.alpha.custom.events', type: 'fanout')
      expect(klass.declaration(options: { type: 'direct' }, tenant_id: 'alpha'))
        .to eq(name: 't.alpha.custom.events', type: 'direct')
    end
  end

  describe 'actual wrapper declarations', :rabbitmq do
    let(:channel) do
      instance_double('Bunny::Channel', open?: true, close: nil,
                                        exchange_declare: nil, register_exchange: nil, record_exchange: nil,
                                        register_queue: nil, record_queue: nil, queue_bind: nil, queue_unbind: nil,
                                        exchange_bind: nil, exchange_unbind: nil)
    end
    let(:dlx_channel) do
      instance_double('Bunny::Channel', open?: true, close: nil,
                                        exchange_declare_without_recording_topology: nil,
                                        queue_declare_without_recording_topology: nil, queue_bind: nil)
    end
    let(:session) { instance_double('Bunny::Session', open?: true, create_channel: dlx_channel) }

    before do
      Legion::Settings[:transport][:tenant_topology][:enabled] = true
      allow(described_class).to receive(:current_tenant_id).and_return('alpha')
      allow(channel).to receive(:connection).and_return(session)
      allow(channel).to receive(:queue_declare) { |name, _options| Struct.new(:queue).new(name) }
      allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
      Legion::Transport::Exchange.clear_cache
    end

    after { Legion::Transport::Exchange.clear_cache }

    it 'isolates explicit and subclass-provided exchange and queue names' do
      alpha_exchange = Legion::Transport::Exchanges::Task.new
      alpha_queue = Legion::Transport::Queues::TaskUpdate.new(channel: channel)
      allow(described_class).to receive(:current_tenant_id).and_return('beta')
      beta_exchange = Legion::Transport::Exchange.new('task')
      beta_queue = Legion::Transport::Queue.new('task.update', channel: channel)

      expect([alpha_exchange.name, alpha_queue.name]).to eq(%w[t.alpha.task t.alpha.task.update])
      expect([beta_exchange.name, beta_queue.name]).to eq(%w[t.beta.task t.beta.task.update])
    end

    it 'scopes convention-derived names as well as explicit overrides' do
      stub_const('Legion::Extensions::Billing::Transport::Exchanges::Billing', Class.new(Legion::Transport::Exchange))
      stub_const('Legion::Extensions::Billing::Transport::Queues::Worker', Class.new(Legion::Transport::Queue))
      expect(Legion::Extensions::Billing::Transport::Exchanges::Billing.new.name).to eq('t.alpha.billing')
      expect(Legion::Extensions::Billing::Transport::Queues::Worker.new(channel: channel).name).to eq('t.alpha.billing.worker')
    end

    it 'keeps bindings and required DLX resources in the queue tenant after context switches' do
      queue = Legion::Transport::Queues::TaskUpdate.new(channel: channel)
      allow(described_class).to receive(:current_tenant_id).and_return('beta')
      queue.bind('task', routing_key: 'task.update')
      queue.unbind('task', routing_key: 'task.update')

      expect(channel).to have_received(:queue_bind).with('t.alpha.task.update', 't.alpha.task', routing_key: 'task.update')
      expect(channel).to have_received(:queue_unbind).with('t.alpha.task.update', 't.alpha.task', routing_key: 'task.update')
      expect(channel).to have_received(:queue_declare).with('t.alpha.task.update', hash_including(
                                                                                     arguments: hash_including('x-dead-letter-exchange': 't.alpha.task.dlx')
                                                                                   ))
      expect(dlx_channel).to have_received(:queue_bind).with('t.alpha.task.dlx.queue', 't.alpha.task.dlx', routing_key: '#')
    end

    it 'does not double-prefix bindings given an exchange instance or already-resolved name' do
      exchange = Legion::Transport::Exchanges::Task.new
      queue = Legion::Transport::Queues::TaskUpdate.new(channel: channel)
      queue.bind(exchange, routing_key: 'first')
      queue.bind(exchange.name, routing_key: 'second')
      expect(channel).to have_received(:queue_bind).with(queue.name, exchange.name, routing_key: 'first')
      expect(channel).to have_received(:queue_bind).with(queue.name, exchange.name, routing_key: 'second')
    end

    it 'scopes exchange-to-exchange bindings using the destination tenant' do
      exchange = Legion::Transport::Exchange.new('events')
      allow(described_class).to receive(:current_tenant_id).and_return('beta')
      exchange.bind('task', routing_key: 'task.update')
      expect(channel).to have_received(:exchange_bind).with('t.alpha.task', exchange, routing_key: 'task.update')
    end

    it 'keeps shared exchanges global while their consumer queues remain tenant scoped' do
      Legion::Settings[:transport][:tenant_topology][:shared_exchanges] = ['task']
      exchange = Legion::Transport::Exchanges::Task.new
      queue = Legion::Transport::Queues::TaskUpdate.new(channel: channel)
      queue.bind('task')
      expect(exchange.name).to eq('task')
      expect(queue.name).to eq('t.alpha.task.update')
      expect(dlx_channel).to have_received(:queue_bind).with('task.dlx.queue', 'task.dlx', routing_key: '#')
      expect(channel).to have_received(:queue_bind).with(queue.name, 'task', {})
    end

    it 'preserves disabled topology and default tenant declarations' do
      Legion::Settings[:transport][:tenant_topology][:enabled] = false
      expect(Legion::Transport::Exchanges::Task.new.name).to eq('task')
      expect(Legion::Transport::Queues::TaskUpdate.new(channel: channel).name).to eq('task.update')
      Legion::Settings[:transport][:tenant_topology][:enabled] = true
      expect(Legion::Transport::Exchanges::Task.new(nil, tenant_id: 'default').name).to eq('task')
      expect(Legion::Transport::Queues::TaskUpdate.new(nil, tenant_id: 'default', channel: channel).name).to eq('task.update')
    end

    it 'does not reuse another tenant exchange when one thread alternates tenants' do
      klass = Legion::Transport::Exchanges::Task
      alpha = klass.new
      allow(described_class).to receive(:current_tenant_id).and_return('beta')
      expect(klass.cached_instance).to be_nil
      beta = klass.new
      expect(klass.cached_instance).to equal(beta)
      allow(described_class).to receive(:current_tenant_id).and_return('alpha')
      expect(klass.cached_instance(name: 't.alpha.task')).to equal(alpha)
    end

    it 'distinguishes explicit names, declaration options, passive state and caller channels in the cache' do
      klass = Legion::Transport::Exchanges::Task
      original = klass.new
      expect(klass.cached_instance(name: 'other')).to be_nil
      expect(klass.cached_instance(options: { durable: false })).to be_nil
      expect(klass.cached_instance(options: { passive: true })).to be_nil
      expect(klass.cached_instance(options: { channel: channel })).to be_nil
      explicit = klass.new('task', channel: channel)
      expect(klass.cached_instance(options: { channel: channel })).to equal(explicit)
      expect(klass.cached_instance).to equal(original)
      allow(channel).to receive(:open?).and_return(false)
      expect(klass.cached_instance).to be_nil
    end
  end
end
