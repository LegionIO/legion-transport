# frozen_string_literal: true

require 'spec_helper'
require 'openssl'
require 'base64'
require 'tmpdir'

RSpec.describe Legion::Transport::Message, 'encryption policy' do
  let(:ready) { false }
  let(:configured_encrypt) { true }
  let(:crypt) { Module.new }
  let(:key) { 'k' * 32 }
  let(:channel) { instance_double(Bunny::Channel, using_publisher_confirmations?: false) }
  let(:exchange) { instance_double(Bunny::Exchange, name: 'task', type: :topic, channel: channel) }
  let(:sent) { [] }
  let(:message) { described_class.new(function: 'secret') }

  before do
    settings = Legion::Settings[:transport]
    allow(Legion::Settings).to receive(:[]).and_call_original
    allow(Legion::Settings).to receive(:[]).with(:transport).and_return(settings.merge(messages: settings[:messages].merge(encrypt: configured_encrypt)))
    allow(Legion::Settings).to receive(:dig).and_call_original
    allow(Legion::Settings).to receive(:dig).with(:crypt, :cs_encrypt_ready).and_return(ready)
    stub_const('Legion::Crypt', crypt)
    allow(crypt).to receive(:encrypt) do |plaintext|
      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.encrypt
      cipher.key = key
      iv = cipher.random_iv
      ciphertext = cipher.update(plaintext) + cipher.final
      { enciphered_message: "gcm:#{Base64.strict_encode64(ciphertext)}:#{Base64.strict_encode64(cipher.auth_tag)}",
        iv:                 Base64.strict_encode64(iv) }
    end
    allow(message).to receive(:exchange).and_return(exchange)
    allow(exchange).to receive(:publish) do |payload, **envelope|
      sent << { payload: payload, envelope: envelope }
      exchange
    end
  end

  it 'keeps configured encryption mandatory while the cluster secret is not ready' do
    expect(message.encrypt?).to be true
    expect(Legion::Transport::Spool).not_to receive(:write)
    expect(Legion::Transport::Connection).not_to receive(:channel)

    expect { message.publish }.to raise_error(Legion::Transport::EncryptionNotReady)
    expect(sent).to eq([])
  end

  context 'when the configured default is plaintext' do
    let(:configured_encrypt) { false }

    it 'still fails closed for a per-publish encryption requirement' do
      expect(Legion::Transport::Spool).not_to receive(:write)

      expect { message.publish(encrypt: true) }.to raise_error(Legion::Transport::EncryptionNotReady)
      expect(sent).to eq([])
    end
  end

  it 'preserves a deliberate plaintext override even before readiness' do
    expect(message.publish(encrypt: false, return_result: true)).to include(status: :accepted)
    expect(sent.fetch(0)).to include(payload: '{"function":"secret"}')
    expect(sent.fetch(0)[:envelope][:content_encoding]).to eq('identity')
  end

  it 'allows the cluster-secret bootstrap message despite a configured encryption requirement' do
    allow(crypt).to receive(:public_key).and_return('public-key')
    bootstrap = Legion::Transport::Messages::RequestClusterSecret.new(encrypt: true)
    allow(bootstrap).to receive(:exchange).and_return(exchange)

    expect(bootstrap.publish(return_result: true)).to include(status: :accepted)
    expect(Legion::JSON.load(sent.fetch(0)[:payload])).to include(function: 'push_cluster_secret', public_key: 'public-key')
    expect(sent.fetch(0)[:envelope][:content_encoding]).to eq('identity')
  end

  context 'when the cluster secret is ready' do
    let(:ready) { true }

    it 'publishes ciphertext with the IV and encoding needed for authenticated round-trip decryption' do
      expect(message.publish(return_result: true)).to include(status: :accepted)
      wire = sent.fetch(0)
      prefix, ciphertext, tag = wire[:payload].split(':', 3)
      decipher = OpenSSL::Cipher.new('aes-256-gcm')
      decipher.decrypt
      decipher.key = key
      decipher.iv = Base64.strict_decode64(wire[:envelope][:headers][:iv])
      decipher.auth_tag = Base64.strict_decode64(tag)

      expect(prefix).to eq('gcm')
      expect(wire[:envelope][:content_encoding]).to eq('encrypted/cs')
      expect(decipher.update(Base64.strict_decode64(ciphertext)) + decipher.final).to eq('{"function":"secret"}')
    end

    it 'never spools plaintext if encryption itself fails' do
      allow(crypt).to receive(:encrypt).and_raise(IOError, 'key unavailable')
      expect(Legion::Transport::Spool).not_to receive(:write)

      expect(message.publish).to include(status: :failed, accepted: false)
      expect(sent).to eq([])
    end

    it 'bounds encryption even when a stale ready flag hides a blocked key initializer' do
      allow(Legion::Settings).to receive(:dig).with(:crypt, :cluster_secret_timeout).and_return(0.01)
      allow(crypt).to receive(:encrypt) { sleep 10 }
      expect(Legion::Transport::Spool).not_to receive(:write)

      Timeout.timeout(1) do
        expect { message.publish }.to raise_error(Legion::Transport::EncryptionNotReady)
      end
      expect(sent).to eq([])
    end

    it 'persists the exact encrypted wire payload and IV without encoding again' do
      directory = Dir.mktmpdir('encrypted-spool')
      Legion::Transport::Spool.reset!
      Legion::Transport::Spool.setup(directory: directory)
      allow(exchange).to receive(:publish) do |payload, **envelope|
        sent << { payload: payload, envelope: envelope }
        raise IOError, 'offline'
      end

      expect(message.publish).to include(status: :spooled)
      records = []
      Legion::Transport::Spool.drain do |record|
        records << record
        true
      end
      wire = sent.fetch(0)
      expect(records.fetch(0)[:payload]).to eq(wire[:payload])
      expect(records.fetch(0)[:envelope]).to include(content_encoding: 'encrypted/cs')
      expect(records.fetch(0)[:envelope][:headers][:iv]).to eq(wire[:envelope][:headers][:iv])
    ensure
      Legion::Transport::Spool.reset!
      FileUtils.rm_rf(directory) if directory
    end
  end
end
