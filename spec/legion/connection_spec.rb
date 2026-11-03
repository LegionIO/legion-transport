# frozen_string_literal: true

require 'spec_helper'
require 'legion/settings'
Legion::Settings.merge_settings('transport', Legion::Transport::Settings.default)
require 'legion/transport'
require 'legion/transport/connection'

RSpec.describe Legion::Transport::Connection, :rabbitmq do
  it '.connector' do
    expect(Legion::Transport::Connection.connector).to eq Bunny
  end

  it '.setup' do
    expect { Legion::Transport::Connection.setup }.not_to raise_error
    expect { Legion::Transport::Connection.setup }.not_to raise_exception
  end

  it 'can run setup multiple times' do
    expect do
      conn = Legion::Transport::Connection
      conn.setup
      conn.setup
      # conn.shutdown
    end.not_to raise_exception
  end

  before do
    @conn = Legion::Transport::Connection
    @conn.setup
  end

  it '.channel_thread' do
    expect(@conn.channel_thread).to be_a Bunny::Channel
  end

  it 'returns true with additional setup command' do
    expect(@conn.setup).to eq true
  end

  it '.channel' do
    expect(@conn.channel).not_to be_nil
    expect(@conn.channel).to be_a Bunny::Channel
    expect(@conn.channel).to eq(@conn.channel)
  end

  it '.session' do
    expect(@conn.session).not_to be_nil
    expect(@conn.session).to be_a Bunny::Session
  end

  it '.channel_open?' do
    expect(@conn.channel_open?).to eq true
  end

  it '.session_open?' do
    expect(@conn.session_open?).to eq true
  end

  it '.shutdown' do
    expect(@conn.session_open?).to eq true
    # expect { @conn.shutdown }.not_to raise_exception
    # expect(@conn.session_open?).to eq false
  end

  it 'can reconnect' do
    expect(@conn.session_open?).to eq true
    expect { @conn.setup }.not_to raise_exception
    expect { @conn.shutdown }.not_to raise_exception
    expect(@conn.session_open?).to eq false
    expect { @conn.setup }.not_to raise_exception
    expect(@conn.session_open?).to eq true
  end

  it 'includes resolved_hosts in settings' do
    conn_settings = Legion::Settings[:transport][:connection]
    expect(conn_settings[:resolved_hosts]).to be_a(Array)
    expect(conn_settings[:resolved_hosts]).not_to be_empty
  end

  describe '.log_channel' do
    it 'returns nil in lite mode' do
      allow(Legion::Transport::Connection).to receive(:lite_mode?).and_return(true)
      expect(Legion::Transport::Connection.log_channel).to be_nil
    end
  end

  describe '.build_session' do
    before { Legion::Transport::Connection.close_build_session }

    it 'open_build_session is a no-op in lite mode' do
      allow(Legion::Transport::Connection).to receive(:lite_mode?).and_return(true)
      Legion::Transport::Connection.open_build_session
      expect(Legion::Transport::Connection.build_session_open?).to be false
    end

    it 'close_build_session is safe when no build session exists' do
      expect { Legion::Transport::Connection.close_build_session }.not_to raise_error
    end

    it 'routes to build_channel when thread flag is set' do
      allow(Legion::Transport::Connection).to receive(:lite_mode?).and_return(true)
      # In lite mode, build session doesn't open, so channel falls through to normal path
      expect { Legion::Transport::Connection.channel }.not_to raise_error
    end
  end

  it 'can initialize a new duplicate object' do
    Legion::Transport::Connection.setup
    expect { @new_session = Legion::Transport::Connection.new }.not_to raise_exception
    expect { @new_session.reconnect }
    expect(@new_session).not_to eq Legion::Transport::Connection

    @session2 = Legion::Transport::Connection.new
    @session2.reconnect
    expect(@session2).not_to be Legion::Transport::Connection
    expect(@session2.session).not_to eq Legion::Transport::Connection.session
    expect(@session2.channel).not_to eq Legion::Transport::Connection.channel

    expect { @session2.shutdown }.not_to raise_exception
    expect(@session2.session_open?).to eq false
    expect(Legion::Transport::Connection.session_open?).to eq true
  end
end

RSpec.describe Legion::Transport::Connection, '.settings' do
  it 'reads replaced canonical channel settings without retaining an old settings snapshot' do
    original = Legion::Settings[:transport]
    initial = original.merge(channel: original.fetch(:channel).merge(default_worker_pool_size: 3))
    Legion::Settings.loader.settings[:transport] = initial
    expect(described_class.settings.dig(:channel, :default_worker_pool_size)).to eq(3)

    Legion::Settings.loader.settings[:transport] = initial.merge(
      channel: initial.fetch(:channel).merge(default_worker_pool_size: 7)
    )
    expect(described_class.settings.dig(:channel, :default_worker_pool_size)).to eq(7)
  ensure
    Legion::Settings.loader.settings[:transport] = original
  end
end
