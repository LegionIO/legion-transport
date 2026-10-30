# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'legion/transport/connection/vault'

RSpec.describe Legion::Transport::Connection::Vault do
  let(:test_obj) { Object.new.extend(described_class) }

  let(:cert_data) do
    {
      cert:     "-----BEGIN CERTIFICATE-----\nMIIB...\n-----END CERTIFICATE-----",
      key:      "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----",
      ca_chain: ["-----BEGIN CERTIFICATE-----\nCACA...\n-----END CERTIFICATE-----"],
      serial:   '01:02',
      expiry:   Time.now + 86_400
    }
  end

  after { test_obj.send(:cleanup_pki_tempfiles) }

  describe '#vault_pki_tls_options' do
    context 'when vault_pki is disabled in settings' do
      before { Legion::Settings[:transport][:tls] = { vault_pki: false } }
      after  { Legion::Settings[:transport].delete(:tls) }

      it 'returns empty hash' do
        expect(test_obj.vault_pki_tls_options).to eq({})
      end
    end

    context 'when vault_pki is enabled but Crypt::Mtls is not defined' do
      before do
        Legion::Settings[:transport][:tls] = { vault_pki: true }
        hide_const('Legion::Crypt::Mtls') if defined?(Legion::Crypt::Mtls)
      end
      after { Legion::Settings[:transport].delete(:tls) }

      it 'returns empty hash' do
        expect(test_obj.vault_pki_tls_options).to eq({})
      end
    end

    context 'when vault_pki is enabled but Mtls.enabled? is false' do
      before do
        Legion::Settings[:transport][:tls] = { vault_pki: true }
        mtls = Module.new
        stub_const('Legion::Crypt::Mtls', mtls)
        allow(Legion::Crypt::Mtls).to receive(:enabled?).and_return(false)
      end
      after { Legion::Settings[:transport].delete(:tls) }

      it 'returns empty hash' do
        expect(test_obj.vault_pki_tls_options).to eq({})
      end
    end

    context 'when vault_pki and Mtls.enabled? are both true' do
      before do
        Legion::Settings[:transport][:tls] = { vault_pki: true }
        mtls = Module.new
        stub_const('Legion::Crypt::Mtls', mtls)
        allow(Legion::Crypt::Mtls).to receive(:enabled?).and_return(true)
        allow(Legion::Crypt::Mtls).to receive(:issue_cert).and_return(cert_data)
      end
      after { Legion::Settings[:transport].delete(:tls) }

      it 'calls Mtls.issue_cert with the node name' do
        expect(Legion::Crypt::Mtls).to receive(:issue_cert).with(
          common_name: Legion::Settings[:client][:name]
        ).and_return(cert_data)
        test_obj.vault_pki_tls_options
      end

      it 'returns a hash with tls: true' do
        opts = test_obj.vault_pki_tls_options
        expect(opts[:tls]).to be true
      end

      it 'returns verify_peer: true' do
        opts = test_obj.vault_pki_tls_options
        expect(opts[:verify_peer]).to be true
      end

      it 'returns tempfile paths for tls_cert and tls_key' do
        opts = test_obj.vault_pki_tls_options
        expect(opts[:tls_cert]).to be_a(String)
        expect(File.exist?(opts[:tls_cert])).to be true
        expect(opts[:tls_key]).to be_a(String)
        expect(File.exist?(opts[:tls_key])).to be true
      end

      it 'writes cert PEM content to the tempfile' do
        opts = test_obj.vault_pki_tls_options
        content = File.read(opts[:tls_cert])
        expect(content).to include('BEGIN CERTIFICATE')
      end

      it 'writes key PEM content to the tempfile' do
        opts = test_obj.vault_pki_tls_options
        content = File.read(opts[:tls_key])
        expect(content).to include('BEGIN RSA PRIVATE KEY')
      end

      it 'returns tls_ca_certificates as an array of tempfile paths' do
        opts = test_obj.vault_pki_tls_options
        expect(opts[:tls_ca_certificates]).to be_an(Array)
        expect(opts[:tls_ca_certificates]).not_to be_empty
      end

      it 'keeps PEM files readable through GC until their owner is retired' do
        opts = test_obj.vault_pki_tls_options
        paths = [opts[:tls_cert], opts[:tls_key], *opts[:tls_ca_certificates]]
        GC.start(full_mark: true, immediate_sweep: true)
        expect(paths.map { |path| File.read(path) }).to eq([cert_data[:cert], cert_data[:key], *cert_data[:ca_chain]])

        test_obj.send(:cleanup_pki_tempfiles)
        expect(paths.none? { |path| File.exist?(path) }).to be(true)
      end

      it 'retains session PEM owners across native restart and cleans up at retirement', :rabbitmq do
        connection = Legion::Transport::Connection.clone
        connection.instance_variables.each { |name| connection.remove_instance_variable(name) }
        candidate = instance_double(Bunny::Session, close: nil)
        paths = nil
        allow(Bunny).to receive(:new) do |options|
          paths = [options[:tls_cert], options[:tls_key], *options[:tls_ca_certificates]]
          candidate
        end
        reads = []
        allow(candidate).to receive(:start) do
          GC.start(full_mark: true, immediate_sweep: true)
          reads << paths.map { |path| File.read(path) }
        end

        session = connection.create_dedicated_session(name: 'pki-lifetime')
        GC.start(full_mark: true, immediate_sweep: true)
        session.start
        expect(reads).to eq(Array.new(2) { [cert_data[:cert], cert_data[:key], *cert_data[:ca_chain]] })
        connection.send(:tear_down_session, sess: session)
        expect(paths.none? { |path| File.exist?(path) }).to be(true)
      ensure
        connection&.send(:tear_down_session, sess: candidate) if candidate
      end

      it 'removes all PEM material after a failed session handshake', :rabbitmq do
        connection = Legion::Transport::Connection.clone
        connection.instance_variables.each { |name| connection.remove_instance_variable(name) }
        allow(connection).to receive(:handle_exception)
        candidate = instance_double(Bunny::Session, close: nil)
        paths = nil
        allow(Bunny).to receive(:new) do |options|
          paths = [options[:tls_cert], options[:tls_key], *options[:tls_ca_certificates]]
          candidate
        end
        allow(candidate).to receive(:start).and_raise(IOError, 'TLS handshake failed')

        expect { connection.create_dedicated_session(name: 'pki-failure') }
          .to raise_error(Legion::Transport::ClusterUnavailable)
        expect(paths.none? { |path| File.exist?(path) }).to be(true)
      end
    end

    context 'when Mtls.issue_cert raises' do
      before do
        Legion::Settings[:transport][:tls] = { vault_pki: true }
        mtls = Module.new
        stub_const('Legion::Crypt::Mtls', mtls)
        allow(Legion::Crypt::Mtls).to receive(:enabled?).and_return(true)
        allow(Legion::Crypt::Mtls).to receive(:issue_cert).and_raise(RuntimeError, 'Vault unreachable')
      end
      after { Legion::Settings[:transport].delete(:tls) }

      it 'returns empty hash and does not raise' do
        expect { test_obj.vault_pki_tls_options }.not_to raise_error
        expect(test_obj.vault_pki_tls_options).to eq({})
      end
    end
  end

  describe '#vault_pki_enabled?' do
    after { Legion::Settings[:transport].delete(:tls) }

    it 'returns false when transport.tls.vault_pki is false' do
      Legion::Settings[:transport][:tls] = { vault_pki: false }
      expect(test_obj.vault_pki_enabled?).to be false
    end

    it 'returns false when tls key is missing' do
      Legion::Settings[:transport].delete(:tls)
      expect(test_obj.vault_pki_enabled?).to be false
    end

    it 'returns true when vault_pki is true' do
      Legion::Settings[:transport][:tls] = { vault_pki: true }
      expect(test_obj.vault_pki_enabled?).to be true
    end
  end
end
