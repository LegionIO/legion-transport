# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Connection dead-thread channel sweep' do
  let(:connection) { Legion::Transport::Connection }

  before do
    connection.instance_variable_set(:@channel_registry, Concurrent::Hash.new)
  end

  after do
    connection.instance_variable_set(:@channel_registry, Concurrent::Hash.new)
  end

  describe '#sweep_dead_thread_channels' do
    it 'closes channels from dead threads with no consumers' do
      channel = instance_double('Bunny::Channel', open?: true, consumers: {})
      dead_thread = instance_double('Thread', alive?: false)

      registry = connection.instance_variable_get(:@channel_registry)
      registry[dead_thread] = channel

      expect(channel).to receive(:close)
      connection.send(:sweep_dead_thread_channels)
      expect(registry).to be_empty
    end

    it 'does not close channels from live threads' do
      channel = instance_double('Bunny::Channel', open?: true)
      live_thread = instance_double('Thread', alive?: true)

      registry = connection.instance_variable_get(:@channel_registry)
      registry[live_thread] = channel

      expect(channel).not_to receive(:close)
      connection.send(:sweep_dead_thread_channels)
      expect(registry.size).to eq(1)
    end

    it 'does not close channels with active consumers even if thread is dead' do
      consumer = instance_double('Bunny::Consumer')
      channel = instance_double('Bunny::Channel', open?: true, consumers: { 'tag' => consumer })
      dead_thread = instance_double('Thread', alive?: false)

      registry = connection.instance_variable_get(:@channel_registry)
      registry[dead_thread] = channel

      expect(channel).not_to receive(:close)
      connection.send(:sweep_dead_thread_channels)
      expect(registry).to be_empty
    end

    it 'removes dead-thread entries even when channel is already closed' do
      channel = instance_double('Bunny::Channel', open?: false)
      dead_thread = instance_double('Thread', alive?: false)

      registry = connection.instance_variable_get(:@channel_registry)
      registry[dead_thread] = channel

      connection.send(:sweep_dead_thread_channels)
      expect(registry).to be_empty
    end

    it 'handles channel.close raising an exception' do
      channel = instance_double('Bunny::Channel', open?: true, consumers: {})
      dead_thread = instance_double('Thread', alive?: false)
      allow(channel).to receive(:close).and_raise(RuntimeError, 'already closed')

      registry = connection.instance_variable_get(:@channel_registry)
      registry[dead_thread] = channel

      expect { connection.send(:sweep_dead_thread_channels) }.not_to raise_error
      expect(registry).to be_empty
    end
  end

  describe '#track_channel' do
    it 'registers the thread and channel' do
      channel = instance_double('Bunny::Channel')
      thread = Thread.current

      connection.send(:track_channel, thread, channel)
      registry = connection.instance_variable_get(:@channel_registry)
      expect(registry[thread]).to eq(channel)
    end
  end

  describe '#channel_registry_size' do
    it 'returns the number of tracked channels' do
      registry = connection.instance_variable_get(:@channel_registry)
      registry[Thread.current] = nil
      registry[instance_double('Thread')] = nil

      expect(connection.channel_registry_size).to eq(2)
    end
  end

  describe 'integration: threads that die release channels' do
    it 'sweeps channels from threads that have terminated' do
      channel = instance_double('Bunny::Channel', open?: true, consumers: {})
      dead_thread = Thread.new { nil }
      dead_thread.join

      registry = connection.instance_variable_get(:@channel_registry)
      registry[dead_thread] = channel

      expect(channel).to receive(:close)
      connection.send(:sweep_dead_thread_channels)
      expect(registry).to be_empty
    end
  end
end
