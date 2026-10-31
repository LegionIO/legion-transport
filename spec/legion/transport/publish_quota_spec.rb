# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tenant publish quota enforcement' do
  let(:channel) { instance_double(Bunny::Channel, using_publisher_confirmations?: false) }
  let(:exchange) { instance_double(Bunny::Exchange, name: 'events', type: :topic, channel: channel) }
  let(:sent) { [] }
  let(:quotas) { { alpha: { messages_per_second: 1 }, beta: { messages_per_second: 1 } } }
  let(:message) { Legion::Transport::Message.new(encrypt: false, routing_key: 'events.run') }
  let(:helper) { Object.new.extend(Legion::Transport::Helper) }
  let(:exchange_class) do
    Class.new(Legion::Transport::Exchange) do
      def exchange_name
        'events'
      end
    end
  end

  before do
    settings = Legion::Settings[:transport]
    allow(Legion::Settings).to receive(:[]).and_call_original
    allow(Legion::Settings).to receive(:[]).with(:transport).and_return(
      settings.merge(tenant_topology: { enabled: true, quotas: quotas }, messages: settings[:messages].merge(encrypt: false))
    )
    allow(Legion::Settings).to receive(:dig).and_call_original
    allow(Legion::Settings).to receive(:dig).with(:transport, :tenant_topology, :quotas, :alpha).and_return(quotas[:alpha])
    allow(Legion::Settings).to receive(:dig).with(:transport, :tenant_topology, :quotas, :beta).and_return(quotas[:beta])
    allow(Legion::Transport::TenantTopology).to receive(:current_tenant_id).and_return('alpha')
    allow(Time).to receive(:now).and_return(Time.at(1000))
    Legion::Transport::TenantQuota.reset!
    allow(message).to receive(:exchange).and_return(exchange)
    allow(exchange).to receive(:publish) do |payload, **_envelope|
      sent << payload
      exchange
    end
    allow(helper).to receive(:transport_connected?).and_return(true)
    allow(helper).to receive(:default_exchange).and_return(exchange_class)
    allow(exchange_class).to receive(:cached_instance).and_return(exchange)
  end

  after { Legion::Transport::TenantQuota.reset! }

  it 'charges a Message send once and rejects excess sends without sending or spooling' do
    expect(Legion::Transport::Spool).not_to receive(:write)

    expect(message.publish(return_result: true)).to include(status: :accepted)
    expect { message.publish(return_result: true) }.to raise_error(Legion::Transport::TenantQuota::QuotaExceededError)
    expect(message.publish(tenant_id: 'beta', return_result: true)).to include(status: :accepted)
    expect(sent).to eq(['{}', '{}'])
  end

  it 'does not bypass an exhausted quota through an offline spool fallback' do
    expect(Legion::Transport::Spool).not_to receive(:write)
    expect(message.publish(return_result: true)).to include(status: :accepted)
    allow(message).to receive(:exchange).and_return(exchange_class)
    allow(exchange_class).to receive(:cached_instance).and_raise(IOError, 'offline')

    expect { message.publish }.to raise_error(Legion::Transport::TenantQuota::QuotaExceededError)
    expect(sent).to eq(['{}'])
  end

  it 'shares quota accounting between the helper and Message without charging either twice' do
    expect(Legion::Transport::Spool).not_to receive(:write)

    expect(helper.transport_publish(routing_key: 'events.run', payload: 'first')).to be true
    expect { message.publish }.to raise_error(Legion::Transport::TenantQuota::QuotaExceededError)
    rejected = helper.transport_publish(routing_key: 'events.run', payload: 'second', return_result: true)
    expect(rejected).to include(status: :failed, accepted: false, error_class: 'Legion::Transport::TenantQuota::QuotaExceededError')
    expect(helper.transport_publish(routing_key: 'events.run', payload: 'other', tenant_id: 'beta')).to be true
    expect(sent).to eq(%w[first other])
  end

  context 'with encoded byte limits' do
    let(:quotas) { { alpha: { bytes_per_second: 3 }, beta: { bytes_per_second: 3 } } }

    it 'measures the final Message wire bytes, not character count or JSON encoding of a string' do
      allow(message).to receive(:message).and_return('é')

      expect(message.publish(return_result: true)).to include(status: :accepted)
      expect { message.publish }.to raise_error(Legion::Transport::TenantQuota::QuotaExceededError)
      expect(sent).to eq(['é'])
    end

    it 'measures helper JSON bytes before sending and never spools quota rejection' do
      expect(Legion::Transport::Spool).not_to receive(:write)

      expect(helper.transport_publish(routing_key: 'events.run', payload: { text: 'é' })).to be false
      expect(helper.transport_publish(routing_key: 'events.run', payload: 'é')).to be true
      expect(helper.transport_publish(routing_key: 'events.run', payload: 'é')).to be false
      expect(sent).to eq(['é'])
    end

    it 'applies the quota to ciphertext expansion rather than the shorter plaintext' do
      allow(message).to receive(:encode_message).and_return('encrypted-wire-payload')
      expect(Legion::Transport::Spool).not_to receive(:write)

      expect { message.publish }.to raise_error(Legion::Transport::TenantQuota::QuotaExceededError)
      expect(sent).to eq([])
    end
  end
end
