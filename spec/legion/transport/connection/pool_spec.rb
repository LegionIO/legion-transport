# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/helpers/pool'

RSpec.describe Legion::Transport::Connection, 'pooled channels' do
  let(:connection) do
    described_class.clone.tap do |copy|
      copy.instance_variables.each { |name| copy.remove_instance_variable(name) }
    end
  end
  let(:channels) { {} }
  let(:fake_session) do
    instance_double(Bunny::Session, open?: true, close: nil).tap do |session|
      session.instance_variable_set(:@channels, channels)
      allow(session).to receive(:create_channel) do |*|
        channel = instance_double(Bunny::Channel, basic_qos: nil, prefetch: nil, connection: session)
        channel.instance_variable_set(:@status, :open)
        allow(channel).to receive(:open?) { channel.instance_variable_get(:@status) == :open }
        allow(channel).to receive(:close) { channel.instance_variable_set(:@status, :closed) }
        channels[channels.size + 1] = channel
        channel
      end
    end
  end

  before do
    @connected = Legion::Settings[:transport][:connected]
    @pool_size = Legion::Settings[:transport][:connection_pool_size]
    Legion::Settings[:transport][:connection_pool_size] = 3
    allow(connection).to receive(:lite_mode?).and_return(false)
    allow(connection).to receive(:create_session_with_failover).and_return(fake_session)
    allow(connection).to receive(:apply_quorum_policy_if_enabled)
    allow(connection).to receive(:handle_exception)
  end

  after do
    connection.shutdown
    Legion::Settings[:transport][:connected] = @connected
    Legion::Settings[:transport][:connection_pool_size] = @pool_size
  end

  it 'reuses an open channel for repeated publishing on one thread' do
    connection.setup
    publisher = connection.channel

    100.times { expect(connection.channel).to equal(publisher) }

    expect(connection.channel_registry_size).to eq(1)
    expect(channels.values.count(&:open?)).to eq(2) # Publisher and log channel.
  end

  it 'keeps channels separate across threads and closes both during shutdown' do
    connection.setup
    publisher = connection.channel
    other = Thread.new { connection.channel }.value

    expect(other).not_to equal(publisher)
    expect(connection.channel_registry_size).to eq(2)
    connection.shutdown
    expect(publisher).not_to be_open
    expect(other).not_to be_open
  end

  it 'replaces a closed channel without abandoning another live channel' do
    connection.setup
    publisher = connection.channel
    publisher.close

    expect(connection.channel_open?).to be false
    replacement = connection.channel
    expect(replacement).not_to equal(publisher)
    expect(replacement).to be_open
    expect(connection.channel_registry_size).to eq(1)
  end

  it 'reclaims a departed publisher thread before allocating its replacement' do
    connection.setup
    departed = Thread.new { connection.channel }.value

    replacement = connection.channel

    expect(departed).not_to be_open
    expect(replacement).to be_open
    expect(connection.channel_registry_size).to eq(1)
  end

  it 'returns a session to the pool when channel creation fails' do
    pool = Legion::Transport::Helpers::Pool.new(size: 1, timeout: 0.1) { fake_session }
    connection.instance_variable_set(:@pool, pool)
    publisher = instance_double(Bunny::Channel, prefetch: nil, open?: true, close: nil)
    attempts = 0
    allow(fake_session).to receive(:create_channel) do |*|
      attempts += 1
      raise IOError, 'channel handshake failed' if attempts == 1

      publisher
    end

    expect { connection.channel }.to raise_error(IOError, 'channel handshake failed')
    expect(connection.channel).to equal(publisher)
  end
end
