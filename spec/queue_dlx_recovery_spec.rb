# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Required queue DLX declarations' do
  let(:queue_instance) { Legion::Transport::Queue.allocate }
  let(:mock_session) { instance_double('Bunny::Session', open?: true, create_channel: mock_channel) }
  let(:mock_channel) do
    instance_double('Bunny::Channel', open?: true, close: nil,
                                      exchange_declare_without_recording_topology: nil,
                                      queue_declare_without_recording_topology: nil,
                                      queue_bind: nil)
  end
  let(:merged) { { arguments: { 'x-dead-letter-exchange': 'test.dlx' } } }

  before do
    allow(Legion::Transport::Connection).to receive(:session).and_return(mock_session)
    allow(queue_instance).to receive(:credential_scoping_enabled?).and_return(false)
  end

  it 'preserves the declaration failure when closing its temporary channel also fails' do
    declaration_error = IOError.new('declaration interrupted')
    cleanup_error = IOError.new('connection dropped during cleanup')
    allow(mock_channel).to receive(:exchange_declare_without_recording_topology).and_raise(declaration_error)
    allow(mock_channel).to receive(:close).and_raise(cleanup_error)
    expect(queue_instance).to receive(:handle_exception).with(declaration_error, hash_including(handled: false))
    expect(queue_instance).to receive(:handle_exception).with(cleanup_error, hash_including(handled: true))

    expect { queue_instance.ensure_dlx(merged) }.to(raise_error { |error| expect(error).to equal(declaration_error) })
  end

  it 'logs a cleanup-only failure without making successful DLX declarations fail' do
    cleanup_error = IOError.new('connection dropped during cleanup')
    allow(mock_channel).to receive(:close).and_raise(cleanup_error)
    expect(queue_instance).to receive(:handle_exception).with(cleanup_error, hash_including(handled: true))

    expect { queue_instance.ensure_dlx(merged) }.not_to raise_error
  end

  it 'surfaces unavailable transport instead of claiming required DLX provisioning succeeded' do
    allow(mock_session).to receive(:open?).and_return(false)
    expect(mock_session).not_to receive(:create_channel)

    expect { queue_instance.ensure_dlx(merged) }.to raise_error(IOError, /required DLX test\.dlx/)
  end

  it 'never deletes an incompatible DLX exchange or its queued messages', :rabbitmq do
    mismatch = Bunny::PreconditionFailed.new('inequivalent exchange type', mock_channel, 406)
    allow(mock_channel).to receive(:exchange_declare_without_recording_topology).and_raise(mismatch)
    expect(mock_channel).not_to receive(:exchange_delete)
    expect(mock_channel).not_to receive(:queue_delete)
    expect(mock_session).to receive(:create_channel).once.and_return(mock_channel)

    expect { queue_instance.ensure_dlx(merged) }.to(raise_error { |error| expect(error).to equal(mismatch) })
  end

  it 'does not declare a source queue after its dead-letter binding fails', :rabbitmq do
    source_channel = instance_double('Bunny::Channel', connection: mock_session)
    binding_error = IOError.new('binding refused')
    allow(mock_channel).to receive(:queue_bind).and_raise(binding_error)
    expect(source_channel).not_to receive(:queue_declare)

    expect do
      Legion::Transport::Queue.new('required.dlx.source', channel: source_channel)
    end.to(raise_error { |error| expect(error).to equal(binding_error) })
  end

  it 'does not provision topology for passive or no-declare consumers' do
    expect(mock_session).not_to receive(:create_channel)
    queue_instance.ensure_dlx(merged.merge(passive: true))
    queue_instance.ensure_dlx(merged.merge(no_declare: true))
    queue_instance.ensure_dlx(arguments: {})
  end
end
