# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Legion::Transport::Message, 'spool fallback' do
  let(:spool_dir) { Dir.mktmpdir('legion-spool') }
  let(:channel) { instance_double(Bunny::Channel, using_publisher_confirmations?: false) }
  let(:exchange) { instance_double(Bunny::Exchange, name: 'custom.events', type: :topic, channel: channel) }
  let(:message) { described_class.new(routing_key: 'test.run', function: 'test', encrypt: false) }

  around do |example|
    original = Legion::Settings[:transport]
    Legion::Settings.loader.settings[:transport] = original.merge(tenant_topology: original.fetch(:tenant_topology).dup)
    example.run
  ensure
    Legion::Settings.loader.settings[:transport] = original
  end

  before do
    Legion::Transport::Spool.reset!
    Legion::Transport::Spool.setup(directory: spool_dir)
    Legion::Transport::Exchange.clear_cache
    allow(message).to receive(:exchange).and_return(exchange)
    allow(exchange).to receive(:publish).and_raise(IOError, 'connection closed')
  end

  after do
    Legion::Transport::Spool.reset!
    FileUtils.rm_rf(spool_dir)
  end

  def stored_records
    records = []
    Legion::Transport::Spool.drain do |record|
      records << record
      true
    end
    records
  end

  it 'reports spooled only after the encoded wire message was persisted' do
    result = message.publish
    record = stored_records.fetch(0)

    expect(result).to include(status: :spooled, accepted: false)
    expect(record).to include(exchange: 'custom.events', exchange_type: 'topic', payload: '{"function":"test"}')
    expect(record[:envelope]).to include(routing_key: 'test.run', content_encoding: 'identity')
  end

  it 'does not claim persistence when a spool writer returns false' do
    allow(Legion::Transport::Spool).to receive(:write).and_return(false)

    expect(message.publish).to include(status: :failed, accepted: false)
    expect(Legion::Transport::Spool.count).to eq(0)
  end

  it 'reports the persistence failure when the filesystem rejects the spool write' do
    allow(Legion::Transport::Spool).to receive(:write).and_raise(Errno::ENOSPC)

    expect(message.publish).to include(status: :failed, accepted: false, error_class: 'Errno::ENOSPC')
    expect(Legion::Transport::Spool.count).to eq(0)
  end

  it 'does not write a spool record when fallback is disabled' do
    expect(message.publish(spool: false)).to include(status: :failed, accepted: false)
    expect(Legion::Transport::Spool.count).to eq(0)
  end

  it 'preserves the normal legacy successful return value' do
    allow(exchange).to receive(:publish).and_return(exchange)

    expect(message.publish).to be_nil
    expect(message.publish(return_result: true)).to include(status: :accepted, accepted: true)
  end

  it 'persists every replay envelope property, including explicit non-persistence' do
    result = message.publish(headers: { 'trace' => 'abc' }, content_type: 'text/plain', type: 'event',
                             priority: 4, expiration: '1000', persistent: false, message_id: 'message-1',
                             correlation_id: 'request-1', reply_to: 'reply', app_id: 'tests', timestamp: 1234,
                             user_id: 'sender', tenant_id: 'alpha')
    record = stored_records.fetch(0)

    expect(result[:status]).to eq(:spooled)
    expect(record[:tenant_id]).to eq('alpha')
    expect(record[:envelope]).to include(content_type: 'text/plain', content_encoding: 'identity', type: 'event',
                                         priority: 4, expiration: '1000', persistent: false, message_id: 'message-1',
                                         correlation_id: 'request-1', reply_to: 'reply', app_id: 'tests', timestamp: 1234,
                                         user_id: 'sender', routing_key: 'test.run')
    expect(record[:envelope][:headers]).to include(trace: 'abc')
  end

  it 'records broker exchange names for class-based messages before any connection is available' do
    allow(Legion::Transport::Connection).to receive(:channel).and_raise(IOError, 'offline')
    messages = [
      Legion::Transport::Messages::Task.new(function: 'run', queue: 'worker', encrypt: false),
      Legion::Transport::Messages::CheckSubtask.new(encrypt: false),
      Legion::Transport::Messages::TaskUpdate.new(task_id: 7, status: 'task.completed', encrypt: false)
    ]

    expect(messages.map { |entry| entry.publish[:status] }).to eq(%i[spooled spooled spooled])
    expect(stored_records.map { |record| record[:exchange] }).to eq(%w[task task task])
  end

  it 'preserves an explicit destination without retrying network construction in the failure path' do
    Legion::Settings[:transport][:tenant_topology][:enabled] = true
    expect(Legion::Transport::Connection).to receive(:channel).once.and_raise(IOError, 'offline')
    direct = Legion::Transport::Messages::Direct.new(exchange: 'custom.audit', routing_key: 'audit.created', tenant_id: 'alpha', encrypt: false)

    result = direct.publish
    record = stored_records.fetch(0)

    expect(result[:status]).to eq(:spooled)
    expect(record).to include(exchange: 't.alpha.custom.audit', exchange_type: 'topic', tenant_id: 'alpha')
    expect(record[:envelope][:routing_key]).to eq('audit.created')
  end

  it 'preserves the Dynamic destination and routing key while the broker is unavailable' do
    allow(Legion::Transport::Connection).to receive(:channel).and_raise(IOError, 'offline')
    extension = double('extension', values: { exchange: 'dynamic.events', name: 'widgets' })
    runner = double('runner', extension: extension, values: { name: 'execute' })
    function = double('function', runner: runner, values: { name: 'run' })
    dynamic = Legion::Transport::Messages::Dynamic.new(function_id: 7, encrypt: false)
    allow(dynamic).to receive(:function).and_return(function)

    expect(dynamic.publish).to include(status: :spooled)
    record = stored_records.fetch(0)
    expect(record[:exchange]).to eq('dynamic.events')
    expect(record[:envelope][:routing_key]).to eq('widgets.execute.run')
  end
end
