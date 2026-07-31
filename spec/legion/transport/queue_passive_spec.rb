# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Queue passive declares (credential scoping)' do
  let(:instance) { Legion::Transport::Queue.allocate }

  def stub_settings(enabled)
    allow(Legion::Settings).to receive(:dig).with(:crypt, :vault, :dynamic_rmq_creds).and_return(enabled ? true : false)
  end

  def stub_mode(infra: false, agent: false, worker: false)
    mode = Module.new
    mode.define_singleton_method(:infra?) { infra }
    mode.define_singleton_method(:agent?) { agent }
    mode.define_singleton_method(:worker?) { worker }
    stub_const('Legion::Mode', mode)
  end

  def stub_identity(resolved:, queue_prefix: nil)
    prefix = queue_prefix
    process = Module.new
    process.define_singleton_method(:resolved?) { resolved }
    process.define_singleton_method(:queue_prefix) { prefix }
    stub_const('Legion::Identity', Module.new)
    stub_const('Legion::Identity::Process', process)
  end

  describe '#credential_scoping_enabled?' do
    it 'returns false when Legion::Settings is not defined' do
      hide_const('Legion::Settings')
      expect(instance.send(:credential_scoping_enabled?)).to be false
    end

    it 'returns false when dynamic_rmq_creds is false' do
      stub_settings(false)
      expect(instance.send(:credential_scoping_enabled?)).to be false
    end

    it 'returns true when dynamic_rmq_creds is true' do
      stub_settings(true)
      expect(instance.send(:credential_scoping_enabled?)).to be true
    end
  end

  describe '#bootstrap_phase?' do
    it 'returns false when credential scoping is disabled' do
      stub_settings(false)
      stub_identity(resolved: false)
      expect(instance.send(:bootstrap_phase?)).to be false
    end

    it 'returns true when scoping enabled and identity not resolved' do
      stub_settings(true)
      stub_identity(resolved: false)
      expect(instance.send(:bootstrap_phase?)).to be true
    end

    it 'returns false when scoping enabled and identity is resolved' do
      stub_settings(true)
      stub_identity(resolved: true)
      expect(instance.send(:bootstrap_phase?)).to be false
    end
  end

  describe '#topology_mode?' do
    it 'returns true when Legion::Mode is not defined' do
      hide_const('Legion::Mode') if defined?(Legion::Mode)
      expect(instance.send(:topology_mode?)).to be true
    end

    it 'returns true for infra mode' do
      stub_mode(infra: true, agent: false)
      expect(instance.send(:topology_mode?)).to be true
    end

    it 'returns false for agent mode' do
      stub_mode(infra: false, agent: true, worker: false)
      expect(instance.send(:topology_mode?)).to be false
    end

    it 'returns true for worker mode' do
      stub_mode(infra: false, agent: false, worker: true)
      expect(instance.send(:topology_mode?)).to be true
    end

    it 'returns false when neither infra nor worker' do
      stub_mode(infra: false, agent: false, worker: false)
      expect(instance.send(:topology_mode?)).to be false
    end
  end

  describe '#own_queue?' do
    before { instance.instance_variable_set(:@queue_name_arg, 'worker.myapp.queue1') }

    it 'returns false when Legion::Identity::Process is not defined' do
      hide_const('Legion::Identity::Process') if defined?(Legion::Identity::Process)
      hide_const('Legion::Identity') if defined?(Legion::Identity)
      expect(instance.own_queue?).to be false
    end

    it 'returns false when identity is not resolved' do
      stub_identity(resolved: false, queue_prefix: 'worker.myapp')
      expect(instance.own_queue?).to be false
    end

    it 'returns false when prefix is nil' do
      stub_identity(resolved: true, queue_prefix: nil)
      expect(instance.own_queue?).to be false
    end

    it 'returns false when prefix is empty' do
      stub_identity(resolved: true, queue_prefix: '')
      expect(instance.own_queue?).to be false
    end

    it 'returns true when queue name starts with own prefix' do
      stub_identity(resolved: true, queue_prefix: 'worker.myapp')
      expect(instance.own_queue?).to be true
    end

    it 'returns false when queue name does not start with own prefix' do
      stub_identity(resolved: true, queue_prefix: 'worker.other')
      expect(instance.own_queue?).to be false
    end

    it 'returns false for shared extension queue (e.g. github.repos)' do
      instance.instance_variable_set(:@queue_name_arg, 'github.repos')
      stub_identity(resolved: true, queue_prefix: 'worker.myapp')
      expect(instance.own_queue?).to be false
    end
  end

  describe '#passive?' do
    context 'when credential scoping is disabled (default)' do
      before { stub_settings(false) }

      it 'returns false regardless of mode' do
        stub_mode(infra: false, agent: false)
        expect(instance.passive?).to be false
      end
    end

    context 'when credential scoping is enabled' do
      before { stub_settings(true) }

      it 'returns true during bootstrap phase' do
        stub_identity(resolved: false)
        stub_mode(infra: true, agent: false)
        expect(instance.passive?).to be true
      end

      it 'returns false for infra mode after identity resolves' do
        stub_identity(resolved: true)
        stub_mode(infra: true, agent: false)
        expect(instance.passive?).to be false
      end

      it 'returns true for agent mode after identity resolves (agent is passive)' do
        stub_identity(resolved: true)
        stub_mode(infra: false, agent: true)
        expect(instance.passive?).to be true
      end

      it 'returns true for worker mode on shared queue' do
        instance.instance_variable_set(:@queue_name_arg, 'github.repos')
        stub_identity(resolved: true, queue_prefix: 'worker.myapp')
        stub_mode(infra: false, agent: false)
        expect(instance.passive?).to be true
      end

      it 'returns false for worker mode on its own queue' do
        instance.instance_variable_set(:@queue_name_arg, 'worker.myapp.queue1')
        stub_identity(resolved: true, queue_prefix: 'worker.myapp')
        stub_mode(infra: false, agent: false)
        expect(instance.passive?).to be false
      end

      it 'returns true during bootstrap even for infra mode' do
        stub_identity(resolved: false)
        stub_mode(infra: true, agent: false)
        expect(instance.passive?).to be true
      end
    end
  end

  describe '#default_options' do
    context 'when credential scoping is disabled' do
      before { stub_settings(false) }

      it 'includes x-queue-type and x-dead-letter-exchange arguments' do
        opts = instance.default_options
        expect(opts[:arguments]).to have_key(:'x-queue-type')
        expect(opts[:arguments]).to have_key(:'x-dead-letter-exchange')
        expect(opts[:passive]).to be false
      end
    end

    context 'when passive (worker with scoping enabled)' do
      before do
        stub_settings(true)
        stub_identity(resolved: true, queue_prefix: 'worker.myapp')
        stub_mode(infra: false, agent: false)
        instance.instance_variable_set(:@queue_name_arg, 'github.repos')
      end

      it 'sets passive: true' do
        expect(instance.default_options[:passive]).to be true
      end

      it 'strips x-dead-letter-exchange argument' do
        opts = instance.default_options
        expect(opts[:arguments]).not_to have_key(:'x-dead-letter-exchange')
      end

      it 'strips x-queue-type argument' do
        opts = instance.default_options
        expect(opts[:arguments]).not_to have_key(:'x-queue-type')
      end

      it 'returns empty arguments hash' do
        opts = instance.default_options
        expect(opts[:arguments]).to eq({})
      end
    end

    context 'when active (infra mode with scoping enabled)' do
      before do
        stub_settings(true)
        stub_identity(resolved: true)
        stub_mode(infra: true, agent: false)
      end

      it 'sets passive: false' do
        expect(instance.default_options[:passive]).to be false
      end

      it 'includes x-queue-type argument' do
        opts = instance.default_options
        expect(opts[:arguments]).to have_key(:'x-queue-type')
      end
    end
  end

  describe '#ensure_dlx' do
    let(:channel_double) do
      dbl = instance_double('Bunny::Channel')
      allow(dbl).to receive(:exchange_declare_without_recording_topology)
      allow(dbl).to receive(:queue_declare_without_recording_topology)
      allow(dbl).to receive(:queue_bind)
      allow(dbl).to receive(:open?).and_return(false)
      dbl
    end

    before do
      session_double = instance_double('Bunny::Session')
      allow(session_double).to receive(:create_channel).and_return(channel_double)
      allow(session_double).to receive(:open?).and_return(true)
      allow(Legion::Transport::Connection).to receive(:session).and_return(session_double)
      allow(instance).to receive(:safely_close_channel)
    end

    context 'when credential scoping is disabled' do
      before { stub_settings(false) }

      it 'creates the DLX exchange and queue' do
        merged_options = { arguments: { 'x-dead-letter-exchange': 'github.dlx' } }
        instance.ensure_dlx(merged_options)
        expect(channel_double).to have_received(:exchange_declare_without_recording_topology).with('github.dlx', 'fanout', anything)
      end
    end

    context 'when credential scoping is enabled' do
      before { stub_settings(true) }

      it 'skips DLX creation during bootstrap phase' do
        stub_identity(resolved: false)
        stub_mode(infra: true, agent: false)
        merged_options = { arguments: { 'x-dead-letter-exchange': 'github.dlx' } }
        instance.ensure_dlx(merged_options)
        expect(channel_double).not_to have_received(:exchange_declare_without_recording_topology)
      end

      it 'skips DLX creation for worker mode' do
        stub_identity(resolved: true)
        stub_mode(infra: false, agent: false)
        merged_options = { arguments: { 'x-dead-letter-exchange': 'github.dlx' } }
        instance.ensure_dlx(merged_options)
        expect(channel_double).not_to have_received(:exchange_declare_without_recording_topology)
      end

      it 'creates DLX for infra mode after identity resolves' do
        stub_identity(resolved: true)
        stub_mode(infra: true, agent: false)
        merged_options = { arguments: { 'x-dead-letter-exchange': 'github.dlx' } }
        instance.ensure_dlx(merged_options)
        expect(channel_double).to have_received(:exchange_declare_without_recording_topology).with('github.dlx', 'fanout', anything)
      end

      it 'skips DLX creation for agent mode (agent is not topology owner)' do
        stub_identity(resolved: true)
        stub_mode(infra: false, agent: true)
        merged_options = { arguments: { 'x-dead-letter-exchange': 'github.dlx' } }
        instance.ensure_dlx(merged_options)
        expect(channel_double).not_to have_received(:exchange_declare_without_recording_topology)
      end
    end
  end
end
