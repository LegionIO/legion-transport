# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Queue DLX channel recovery' do
  let(:queue_instance) { Legion::Transport::Queue.allocate }

  let(:mock_session) do
    instance_double('Bunny::Session', open?: true, create_channel: mock_channel)
  end

  let(:mock_channel) do
    instance_double('Bunny::Channel', open?: true, close: nil).tap do |ch|
      allow(ch).to receive(:exchange_declare_without_recording_topology)
      allow(ch).to receive(:queue_declare_without_recording_topology)
      allow(ch).to receive(:queue_bind)
    end
  end

  before do
    allow(Legion::Transport::Connection).to receive(:session).and_return(mock_session)
  end

  describe '#declare_dlx' do
    it 'uses exchange_declare_without_recording_topology to avoid recovery tracking' do
      queue_instance.declare_dlx('test.dlx', mock_channel)

      expect(mock_channel).to have_received(:exchange_declare_without_recording_topology)
        .with('test.dlx', 'fanout', durable: true, auto_delete: false)
    end

    it 'uses queue_declare_without_recording_topology to avoid recovery tracking' do
      queue_instance.declare_dlx('test.dlx', mock_channel)

      expect(mock_channel).to have_received(:queue_declare_without_recording_topology)
        .with('test.dlx.queue', durable: true, auto_delete: false,
                                arguments: { 'x-queue-type': 'classic' })
    end

    it 'binds the DLX queue to the DLX exchange' do
      queue_instance.declare_dlx('test.dlx', mock_channel)

      expect(mock_channel).to have_received(:queue_bind)
        .with('test.dlx.queue', 'test.dlx', routing_key: '#')
    end
  end

  describe '#ensure_dlx' do
    let(:closed_channel) do
      instance_double('Bunny::Channel', open?: false, close: nil)
    end

    let(:closed_session) do
      instance_double('Bunny::Session', open?: true, create_channel: closed_channel)
    end

    context 'when the created channel is already closed' do
      let(:channel_closed_error) do
        klass = Legion::Transport::CONNECTOR::ChannelAlreadyClosed
        if klass.instance_method(:initialize).arity.abs > 1
          klass.new('cannot use a closed channel', closed_channel)
        else
          klass.new('cannot use a closed channel')
        end
      end

      before do
        allow(Legion::Transport::Connection).to receive(:session).and_return(closed_session)
        allow(closed_channel).to receive(:exchange_declare_without_recording_topology)
          .and_raise(channel_closed_error)
      end

      it 'handles the error without looping' do
        merged = { arguments: { 'x-dead-letter-exchange': 'test.dlx' } }
        expect { queue_instance.ensure_dlx(merged) }.not_to raise_error
      end
    end

    context 'when the session is not open' do
      before do
        allow(Legion::Transport::Connection).to receive(:session).and_return(
          instance_double('Bunny::Session', open?: false)
        )
      end

      it 'returns early without attempting DLX declaration' do
        merged = { arguments: { 'x-dead-letter-exchange': 'test.dlx' } }
        queue_instance.ensure_dlx(merged)

        expect(mock_session).not_to have_received(:create_channel)
      end
    end

    context 'when DLX name is nil' do
      it 'returns early' do
        merged = { arguments: {} }
        expect { queue_instance.ensure_dlx(merged) }.not_to raise_error
      end
    end
  end
end
