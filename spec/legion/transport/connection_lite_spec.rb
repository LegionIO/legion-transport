# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/in_process'

RSpec.describe Legion::Transport::Connection do
  describe '.lite_mode?' do
    it 'returns true when TYPE is local' do
      stub_const('Legion::Transport::TYPE', 'local')
      expect(described_class.lite_mode?).to be true
    end

    it 'returns false when TYPE is bunny' do
      stub_const('Legion::Transport::TYPE', 'bunny')
      expect(described_class.lite_mode?).to be false
    end
  end

  describe '.create_dedicated_session' do
    after do
      described_class.instance_variable_set(:@session, nil)
      described_class.instance_variable_set(:@channel_thread, nil)
    end

    it 'returns an InProcess::Session in lite mode' do
      stub_const('Legion::Transport::TYPE', 'local')
      session = described_class.create_dedicated_session(name: 'test')
      expect(session).to be_a(Legion::Transport::InProcess::Session)
    end

    it 'responds to create_channel in lite mode' do
      stub_const('Legion::Transport::TYPE', 'local')
      session = described_class.create_dedicated_session(name: 'test')
      expect(session).to respond_to(:create_channel)
    end

    it 'reuses the shared in-process session when already started in lite mode' do
      stub_const('Legion::Transport::TYPE', 'local')

      shared_session = described_class.session
      if shared_session.nil? || shared_session.closed?
        shared_session = Legion::Transport::InProcess::Session.new
        shared_session.start
        described_class.instance_variable_set(:@session, Concurrent::AtomicReference.new(shared_session))
      end

      dedicated = described_class.create_dedicated_session(name: 'test')
      expect(dedicated).to be(shared_session)
    end
  end
end
