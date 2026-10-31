# frozen_string_literal: true

require 'spec_helper'
require 'legion/settings'
Legion::Settings.merge_settings('transport', Legion::Transport::Settings.default)
require 'legion/transport'
require 'legion/transport/connection'

RSpec.describe 'Channel leak prevention', :rabbitmq do
  before do
    Legion::Transport::Connection.setup
  end

  after do
    # Ensure @log_channel is always a real object (not a leaked double) for subsequent tests
    log_ch = Legion::Transport::Connection.instance_variable_get(:@log_channel)
    unless log_ch.is_a?(Bunny::Channel)
      Legion::Transport::Connection.instance_variable_set(:@log_channel, nil)
      Legion::Transport::Connection.setup
    end
  end

  describe 'Connection.setup' do
    it 'closes the QoS channel after applying basic_qos' do
      Legion::Transport::Connection.shutdown
      Legion::Transport::Connection.setup

      active_channels = Legion::Transport::Connection.session.instance_variable_get(:@channels).values.select(&:open?)
      expect(active_channels.size).to eq(1) # Only the log channel remains after initial QoS.
    end

    it 'closes old @log_channel before creating a new one' do
      old_log = Legion::Transport::Connection.instance_variable_get(:@log_channel)
      expect(old_log).to be_a(Bunny::Channel)
      expect(old_log).to be_open

      # Re-run setup — our fix should close old_log before replacing
      Legion::Transport::Connection.setup

      new_log = Legion::Transport::Connection.instance_variable_get(:@log_channel)
      expect(new_log).to be_a(Bunny::Channel)
      expect(new_log).to be_open
      # Old channel should now be closed
      expect(old_log).not_to be_open
    end
  end

  describe 'Connection.log_channel accessor' do
    it 'recovers when the log channel is closed' do
      old_log = Legion::Transport::Connection.instance_variable_get(:@log_channel)
      old_log.close

      result = Legion::Transport::Connection.log_channel
      expect(result).to be_a(Bunny::Channel)
      expect(result).to be_open
      expect(result).not_to eq(old_log)
    end

    it 'returns existing log_channel when still open' do
      existing = Legion::Transport::Connection.instance_variable_get(:@log_channel)
      expect(existing).to be_open

      result = Legion::Transport::Connection.log_channel
      expect(result).to eq(existing)
    end
  end

  describe 'Exchange#channel error recovery' do
    it 'closes the error channel before replacing on ChannelLevelException' do
      exchange = Legion::Transport::Exchange.new('test_channel_recovery_leak')
      old_channel = exchange.instance_variable_get(:@channel)
      expect(old_channel).to be_open

      # Clear @channel so the next call goes through the ||= assignment path
      exchange.instance_variable_set(:@channel, nil)

      # bad_channel simulates the broken channel referenced in the exception
      bad_channel = Legion::Transport::Connection.session.create_channel
      good_channel = Legion::Transport::Connection.session.create_channel

      call_count = 0
      allow(Legion::Transport::Connection).to receive(:channel) do
        call_count += 1
        # Raise with bad_channel as the exception's channel — production code
        # now uses e.channel to close it even when @channel is still nil
        raise Bunny::ChannelLevelException.new('test error', bad_channel, 406) if call_count == 1

        good_channel
      end

      # The rescue path should close bad_channel (via e.channel) and replace with good_channel
      begin
        exchange.channel
      rescue Bunny::ChannelLevelException
        nil
      end

      recovered_channel = exchange.instance_variable_get(:@channel)
      expect(recovered_channel).to eq(good_channel)
      expect(recovered_channel).to be_open
      # The channel from the exception must have been closed by the rescue
      expect(bad_channel).not_to be_open
    ensure
      old_channel&.close rescue nil # rubocop:disable Style/RescueModifier
      bad_channel&.close rescue nil # rubocop:disable Style/RescueModifier
      good_channel&.close rescue nil # rubocop:disable Style/RescueModifier
    end
  end
end
