# frozen_string_literal: true

RSpec.describe Legion::Transport::Helper do
  let(:test_class) do
    Class.new do
      include Legion::Transport::Helper

      def full_path
        '/opt/legion/extensions/lex-test'
      end
    end
  end

  let(:custom_ttl_class) do
    Class.new do
      include Legion::Transport::Helper

      def transport_default_ttl
        300_000
      end
    end
  end

  subject { test_class.new }

  describe '#transport_default_ttl' do
    it 'returns nil by default (no expiration)' do
      allow(Legion::Settings).to receive(:dig).with(:transport, :messages, :ttl).and_return(nil)
      expect(subject.transport_default_ttl).to be_nil
    end

    it 'returns the settings value when configured' do
      allow(Legion::Settings).to receive(:dig).with(:transport, :messages, :ttl).and_return(60_000)
      expect(subject.transport_default_ttl).to eq(60_000)
    end

    it 'can be overridden by a LEX' do
      obj = custom_ttl_class.new
      expect(obj.transport_default_ttl).to eq(300_000)
    end
  end

  describe '#transport_connected?' do
    it 'returns true when transport is connected' do
      allow(Legion::Settings).to receive(:dig).with(:transport, :connected).and_return(true)
      expect(subject.transport_connected?).to be true
    end

    it 'returns false when transport is not connected' do
      allow(Legion::Settings).to receive(:dig).with(:transport, :connected).and_return(false)
      expect(subject.transport_connected?).to be false
    end

    it 'returns false when settings raises' do
      allow(Legion::Settings).to receive(:dig).and_raise(StandardError)
      expect(subject.transport_connected?).to be false
    end
  end

  describe '#transport_session_open?' do
    it 'delegates to Connection.session_open?' do
      allow(Legion::Transport::Connection).to receive(:session_open?).and_return(true)
      expect(subject.transport_session_open?).to be true
    end

    it 'returns false on error' do
      allow(Legion::Transport::Connection).to receive(:session_open?).and_raise(StandardError)
      expect(subject.transport_session_open?).to be false
    end
  end

  describe '#transport_channel_open?' do
    it 'delegates to Connection.channel_open?' do
      allow(Legion::Transport::Connection).to receive(:channel_open?).and_return(true)
      expect(subject.transport_channel_open?).to be true
    end

    it 'returns false on error' do
      allow(Legion::Transport::Connection).to receive(:channel_open?).and_raise(StandardError)
      expect(subject.transport_channel_open?).to be false
    end
  end

  describe '#transport_lite_mode?' do
    it 'delegates to Connection.lite_mode?' do
      allow(Legion::Transport::Connection).to receive(:lite_mode?).and_return(false)
      expect(subject.transport_lite_mode?).to be false
    end
  end

  describe '#transport_channel' do
    it 'delegates to Connection.channel' do
      channel = double('channel')
      allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
      expect(subject.transport_channel).to eq(channel)
    end
  end

  describe '#transport_spool_count' do
    it 'delegates to Spool.count' do
      allow(Legion::Transport::Spool).to receive(:count).and_return(42)
      expect(subject.transport_spool_count).to eq(42)
    end

    it 'returns 0 on error' do
      allow(Legion::Transport::Spool).to receive(:count).and_raise(StandardError)
      expect(subject.transport_spool_count).to eq(0)
    end
  end

  describe '#transport_publish' do
    let(:channel) do
      instance_double(Bunny::Channel, register_exchange: nil, record_exchange: nil,
                                      using_publisher_confirmations?: false, confirm_select: true, wait_for_confirms: true)
    end
    let(:exchange_instance) { Bunny::Exchange.new(channel, :topic, 'events', no_declare: true) }
    let(:exchange_class) do
      class_double(Legion::Transport::Exchange, new: exchange_instance, cached_instance: exchange_instance,
                                               declaration: { name: 'events', type: 'topic' })
    end
    let(:published) { [] }

    before do
      allow(subject).to receive(:transport_connected?).and_return(true)
      allow(subject).to receive(:default_exchange).and_return(exchange_class)
      allow(Legion::Settings).to receive(:dig).and_call_original
      allow(Legion::Settings).to receive(:dig).with(:transport, :messages, :persistent).and_return(true)
      allow(channel).to receive(:basic_publish) do |payload, exchange, routing_key, envelope|
        published << { payload: payload, exchange: exchange, routing_key: routing_key, envelope: envelope }
      end
    end

    it 'publishes JSON objects and leaves already encoded strings unchanged' do
      expect(subject.transport_publish(routing_key: 'test.run', payload: { foo: 'bar' })).to be true
      expect(subject.transport_publish(routing_key: 'test.run', payload: 'raw-string')).to be true

      expect(published.map { |entry| entry[:payload] }).to eq(['{"foo":"bar"}', 'raw-string'])
      expect(published.map { |entry| entry[:exchange] }).to eq(%w[events events])
    end

    it 'uses configured persistence while preserving an explicit false override' do
      subject.transport_publish(routing_key: 'test.run')
      subject.transport_publish(routing_key: 'test.run', persistent: false)
      allow(Legion::Settings).to receive(:dig).with(:transport, :messages, :persistent).and_return(false)
      subject.transport_publish(routing_key: 'test.run')

      expect(published.map { |entry| entry[:envelope][:persistent] }).to eq([true, false, false])
    end

    it 'applies explicit TTL ahead of the helper default' do
      allow(subject).to receive(:transport_default_ttl).and_return(30_000)
      subject.transport_publish(routing_key: 'test.run', ttl: 60_000)

      expect(published.fetch(0)[:envelope][:expiration]).to eq('60000')
    end

    it 'applies the helper default only when expiration and TTL were omitted' do
      allow(subject).to receive(:transport_default_ttl).and_return(30_000)
      subject.transport_publish(routing_key: 'test.run')
      subject.transport_publish(routing_key: 'test.run', ttl: nil)
      subject.transport_publish(routing_key: 'test.run', expiration: '99999')

      expect(published.map { |entry| entry[:envelope][:expiration] }).to eq(['30000', nil, '99999'])
    end

    it 'returns false when transport is disconnected without sending anything' do
      allow(subject).to receive(:transport_connected?).and_return(false)

      expect(subject.transport_publish(routing_key: 'test.run')).to be false
      expect(published).to eq([])
    end

    it 'returns false when publication fails' do
      allow(channel).to receive(:basic_publish).and_raise(IOError, 'connection closed')

      expect(subject.transport_publish(routing_key: 'test.run')).to be false
    end

    it 'returns the reliable broker result instead of unconditionally returning true' do
      allow(channel).to receive(:wait_for_confirms).and_return(false)

      expect(subject.transport_publish(routing_key: 'test.run', publisher_confirm: true)).to include(status: :nacked, accepted: false)
    end

    it 'returns structured failures when a reliable publish is requested while disconnected' do
      allow(subject).to receive(:transport_connected?).and_return(false)

      expect(subject.transport_publish(routing_key: 'test.run', return_result: true)).to include(status: :failed, accepted: false)
    end

    it 'fails closed when encryption was explicitly requested before readiness' do
      stub_const('Legion::Crypt', Module.new)
      allow(Legion::Crypt).to receive(:encrypt)
      allow(Legion::Settings).to receive(:dig).with(:crypt, :cs_encrypt_ready).and_return(false)

      result = subject.transport_publish(routing_key: 'test.run', encrypt: true, return_result: true)

      expect(result).to include(status: :failed, accepted: false, error_class: 'Legion::Transport::EncryptionNotReady')
      expect(published).to eq([])
    end
  end

  describe '#transport_path' do
    it 'returns the transport subdirectory path' do
      expect(subject.transport_path).to eq('/opt/legion/extensions/lex-test/transport')
    end

    it 'memoizes the result' do
      first = subject.transport_path
      expect(subject.transport_path).to equal(first)
    end
  end

  describe '#transport_class' do
    let(:lex_transport) { Module.new }
    let(:lex_class) do
      mod = Module.new
      mod.const_set(:Transport, lex_transport)
      mod
    end
    let(:wired_class) do
      lc = lex_class
      Class.new do
        include Legion::Transport::Helper

        define_method(:lex_class) { lc }
      end
    end

    it 'returns the transport module for the lex class' do
      expect(wired_class.new.transport_class).to eq(lex_transport)
    end
  end
end
