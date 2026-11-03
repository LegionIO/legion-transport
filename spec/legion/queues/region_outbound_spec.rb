# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/queues/region_outbound'

RSpec.describe Legion::Transport::Queues::RegionOutbound do
  around do |example|
    original = Legion::Settings[:region]
    Legion::Settings.loader.settings[:region] = original.dup
    example.run
  ensure
    Legion::Settings.loader.settings[:region] = original
  end

  it 'is a module' do
    expect(described_class).to be_a Module
  end

  it 'is defined under Legion::Transport::Queues' do
    expect(described_class.name).to eq 'Legion::Transport::Queues::RegionOutbound'
  end

  describe '.queue_name_for' do
    it 'returns the correct outbound queue name format' do
      expect(described_class.queue_name_for('us-east-1')).to eq 'legion.tasks.outbound.us-east-1'
    end

    it 'includes the target region in the queue name' do
      expect(described_class.queue_name_for('eu-west-2')).to include('eu-west-2')
    end

    it 'uses the legion.tasks.outbound prefix' do
      expect(described_class.queue_name_for('ap-southeast-1')).to start_with('legion.tasks.outbound.')
    end
  end

  describe '.declare_all' do
    context 'when peers is nil' do
      it 'returns an empty array' do
        Legion::Settings[:region][:peers] = nil
        expect(described_class.declare_all).to eq []
      end
    end

    context 'when peers is an empty array' do
      it 'returns an empty array' do
        Legion::Settings[:region][:peers] = []
        expect(described_class.declare_all).to eq []
      end
    end

    context 'when peers are configured' do
      let(:mock_channel) { instance_double('Bunny::Channel') }
      let(:mock_queue)   { instance_double('Bunny::Queue') }

      before do
        Legion::Settings[:region][:peers] = %w[us-east-1 eu-west-2]
        allow(Legion::Transport::Connection).to receive(:channel).and_return(mock_channel)
        allow(mock_channel).to receive(:queue).and_return(mock_queue)
      end

      it 'returns an array of queue objects' do
        result = described_class.declare_all
        expect(result).to be_an Array
        expect(result).not_to be_empty
      end

      it 'declares a queue for each peer' do
        described_class.declare_all
        expect(mock_channel).to have_received(:queue).twice
      end

      it 'declares queues as durable' do
        described_class.declare_all
        expect(mock_channel).to have_received(:queue).with(
          anything,
          hash_including(durable: true)
        ).at_least(:once)
      end
    end

    context 'when current region matches a peer' do
      let(:mock_channel) { instance_double('Bunny::Channel') }
      let(:mock_queue)   { instance_double('Bunny::Queue') }

      before do
        Legion::Settings[:region][:peers] = %w[us-east-1 eu-west-2]
        allow(Legion::Transport::Connection).to receive(:channel).and_return(mock_channel)
        allow(mock_channel).to receive(:queue).and_return(mock_queue)
        stub_const('Legion::Region', Module.new)
        allow(Legion::Region).to receive(:current).and_return('us-east-1')
      end

      it 'skips the current region' do
        result = described_class.declare_all
        expect(result.length).to eq 1
      end

      it 'only declares queues for remote peers' do
        described_class.declare_all
        expect(mock_channel).to have_received(:queue).with(
          'legion.tasks.outbound.eu-west-2',
          anything
        )
      end
    end
  end

  describe '.declare_outbound' do
    let(:mock_channel) { instance_double('Bunny::Channel') }
    let(:mock_queue)   { instance_double('Bunny::Queue') }

    before do
      allow(Legion::Transport::Connection).to receive(:channel).and_return(mock_channel)
      allow(mock_channel).to receive(:queue).and_return(mock_queue)
    end

    it 'uses the correct queue name' do
      described_class.declare_outbound('us-west-2')
      expect(mock_channel).to have_received(:queue).with('legion.tasks.outbound.us-west-2', anything)
    end

    it 'sets the tasks dead-letter exchange' do
      described_class.declare_outbound('us-west-2')
      expect(mock_channel).to have_received(:queue).with(
        anything,
        hash_including(arguments: hash_including('x-dead-letter-exchange' => 'tasks.dlx'))
      )
    end

    it 'returns nil and does not raise when connection fails' do
      allow(mock_channel).to receive(:queue).and_raise(StandardError, 'connection refused')
      expect { described_class.declare_outbound('us-east-1') }.not_to raise_error
      expect(described_class.declare_outbound('us-east-1')).to be_nil
    end
  end
end
