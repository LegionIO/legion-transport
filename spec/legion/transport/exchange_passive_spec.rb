# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Exchange passive declares (credential scoping)' do
  # Use allocate to bypass AMQP initialization
  let(:instance) { Legion::Transport::Exchange.allocate }

  # Helper to configure Legion::Settings stub for dynamic_rmq_creds
  def stub_settings(enabled)
    allow(Legion::Settings).to receive(:dig).with(:crypt, :vault, :dynamic_rmq_creds).and_return(enabled ? true : false)
  end

  # Helper to stub Legion::Mode
  def stub_mode(infra: false, agent: false, worker: false)
    mode = Module.new
    mode.define_singleton_method(:infra?) { infra }
    mode.define_singleton_method(:agent?) { agent }
    mode.define_singleton_method(:worker?) { worker }
    stub_const('Legion::Mode', mode)
  end

  # Helper to stub Legion::Identity::Process
  def stub_identity(resolved:)
    process = Module.new
    process.define_singleton_method(:resolved?) { resolved }
    stub_const('Legion::Identity', Module.new)
    stub_const('Legion::Identity::Process', process)
  end

  describe '#credential_scoping_enabled?' do
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
    it 'returns false when Legion::Identity::Process is not defined' do
      stub_settings(true)
      hide_const('Legion::Identity::Process') if defined?(Legion::Identity::Process)
      expect(instance.send(:bootstrap_phase?)).to be false
    end

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
    it 'returns true when Legion::Mode is not defined (default safe)' do
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

    it 'returns false for neither infra nor worker' do
      stub_mode(infra: false, agent: false, worker: false)
      expect(instance.send(:topology_mode?)).to be false
    end
  end

  describe '#passive?' do
    context 'when credential scoping is disabled (default)' do
      before { stub_settings(false) }

      it 'returns false regardless of mode' do
        stub_mode(infra: false, agent: false)
        expect(instance.passive?).to be false
      end

      it 'returns false even without Legion::Mode defined' do
        hide_const('Legion::Mode') if defined?(Legion::Mode)
        expect(instance.passive?).to be false
      end
    end

    context 'when credential scoping is enabled' do
      before { stub_settings(true) }

      it 'returns true during bootstrap phase (identity not resolved)' do
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

      it 'returns true for worker mode after identity resolves' do
        stub_identity(resolved: true)
        stub_mode(infra: false, agent: false)
        expect(instance.passive?).to be true
      end

      it 'returns true during bootstrap even for infra mode (bootstrap creds have configure: "")' do
        stub_identity(resolved: false)
        stub_mode(infra: true, agent: false)
        expect(instance.passive?).to be true
      end
    end
  end

  describe '#default_options' do
    it 'sets passive: false when scoping disabled' do
      stub_settings(false)
      opts = instance.default_options
      expect(opts[:passive]).to be false
    end

    it 'sets passive: true for worker mode with scoping enabled' do
      stub_settings(true)
      stub_identity(resolved: true)
      stub_mode(infra: false, agent: false)
      opts = instance.default_options
      expect(opts[:passive]).to be true
    end

    it 'sets passive: false for infra mode post-identity with scoping enabled' do
      stub_settings(true)
      stub_identity(resolved: true)
      stub_mode(infra: true, agent: false)
      opts = instance.default_options
      expect(opts[:passive]).to be false
    end

    it 'always includes durable and auto_delete keys' do
      stub_settings(false)
      opts = instance.default_options
      expect(opts).to have_key(:durable)
      expect(opts).to have_key(:auto_delete)
    end
  end
end
