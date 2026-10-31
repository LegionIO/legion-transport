# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Transport::Message, 'payload size enforcement' do
  around do |example|
    original = Legion::Settings[:transport][:max_payload_bytes]
    example.run
  ensure
    Legion::Settings[:transport][:max_payload_bytes] = original
  end

  context 'when the payload exceeds the limit' do
    it 'raises PayloadTooLarge before any AMQP interaction' do
      msg = described_class.new(data: 'x' * 2_000_000)
      Legion::Settings[:transport][:max_payload_bytes] = 100

      expect { msg.publish }.to raise_error(
        Legion::Transport::PayloadTooLarge,
        /exceeds limit of 100 bytes/
      )
    end

    it 'includes actual size in the error message' do
      msg = described_class.new(data: 'x' * 200)
      Legion::Settings[:transport][:max_payload_bytes] = 50

      expect { msg.publish }.to raise_error(Legion::Transport::PayloadTooLarge, /bytes/)
    end
  end

  it 'fails clearly if the configured safety limit is missing instead of silently allowing a larger payload' do
    Legion::Settings[:transport].delete(:max_payload_bytes)
    message = described_class.new(data: 'payload', encrypt: false)
    expect { message.publish! }.to raise_error(KeyError)
  end

  context 'when the payload is within the limit' do
    it 'publishes the encoded message within the limit' do
      msg = described_class.new(function: 'test', encrypt: false)
      channel = instance_double(Bunny::Channel, using_publisher_confirmations?: false)
      exchange_mock = instance_double(Bunny::Exchange, name: 'task', type: :topic, channel: channel)
      allow(msg).to receive(:exchange).and_return(exchange_mock)
      expect(exchange_mock).to receive(:publish).with('{"function":"test"}', anything).and_return(exchange_mock)

      expect(msg.publish(return_result: true)).to include(status: :accepted, accepted: true)
    end
  end
end
