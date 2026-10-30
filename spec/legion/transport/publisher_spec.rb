# frozen_string_literal: true

require 'spec_helper'
require 'bunny'
require 'bunny/concurrent/continuation_queue'

RSpec.describe Legion::Transport::Publisher do
  let(:channel) do
    instance_double(Bunny::Channel, register_exchange: nil, record_exchange: nil,
                                    using_publisher_confirmations?: false, confirm_select: true,
                                    wait_for_confirms: true, open?: true, close: true)
  end
  let(:exchange) { Bunny::Exchange.new(channel, :topic, 'task', no_declare: true) }
  let(:envelope) { { routing_key: 'task.run', message_id: 'same-message', correlation_id: 'same-correlation' } }
  let(:sent) { [] }
  let(:return_info) { instance_double(Bunny::ReturnInfo, reply_code: 312, reply_text: 'NO_ROUTE') }

  before do
    allow(channel).to receive(:basic_publish) do |payload, _name, _key, properties|
      sent << { payload: payload, properties: properties }
    end
  end

  def return_send(exchange:, send:)
    exchange.handle_return(return_info, Bunny::MessageProperties.new(send[:properties]), send[:payload])
  end

  it 'uses the real zero-argument Bunny confirmation contract' do
    expect(channel).to receive(:wait_for_confirms).with(no_args).and_return(true)

    result = described_class.publish(exchange: exchange, payload: '{}', envelope: envelope, publisher_confirm: true)

    expect(result).to include(status: :accepted, accepted: true)
    expect(sent.map { |entry| entry[:payload] }).to eq(['{}'])
  end

  it 'waits for an exchange return even when mandatory is requested without publisher_confirm' do
    allow(channel).to receive(:wait_for_confirms) do
      return_send(exchange: exchange, send: sent.last)
      true
    end

    result = described_class.publish(exchange: exchange, payload: '{}', envelope: envelope, mandatory: true)

    expect(result).to include(status: :unroutable, accepted: false, return_reply_code: 312, return_reply_text: 'NO_ROUTE')
  end

  it 'ignores a late return from a previous send with the same application identifiers' do
    first = described_class.publish(exchange: exchange, payload: 'first', envelope: envelope, mandatory: true)
    old_send = sent.last
    allow(channel).to receive(:wait_for_confirms) do
      return_send(exchange: exchange, send: old_send)
      true
    end

    second = described_class.publish(exchange: exchange, payload: 'second', envelope: envelope, mandatory: true)

    expect(first).to include(status: :accepted, accepted: true)
    expect(second).to include(status: :accepted, accepted: true)
    expect(second).not_to have_key(:return_reply_code)
  end

  it 'does not carry an unroutable result into the next successful send' do
    allow(channel).to receive(:wait_for_confirms) do
      return_send(exchange: exchange, send: sent.last) if sent.length == 1
      true
    end

    first = described_class.publish(exchange: exchange, payload: 'first', envelope: envelope, mandatory: true)
    second = described_class.publish(exchange: exchange, payload: 'second', envelope: envelope, mandatory: true)

    expect(first[:status]).to eq(:unroutable)
    expect(second[:status]).to eq(:accepted)
  end

  it 'settles ordinary sends on an already confirmed channel before another reliable send' do
    allow(channel).to receive(:using_publisher_confirmations?).and_return(true)
    allow(channel).to receive(:wait_for_confirms).and_return(false, true)

    ordinary = described_class.publish(exchange: exchange, payload: 'ordinary', envelope: envelope)
    reliable = described_class.publish(exchange: exchange, payload: 'reliable', envelope: envelope, publisher_confirm: true)

    expect(ordinary).to include(status: :nacked, accepted: false)
    expect(reliable).to include(status: :accepted, accepted: true)
  end

  it 'reports a broker nack rather than acceptance' do
    allow(channel).to receive(:wait_for_confirms).and_return(false)

    result = described_class.publish(exchange: exchange, payload: '{}', envelope: envelope, publisher_confirm: true)

    expect(result).to include(status: :nacked, accepted: false)
  end

  it 'reports Bunny continuation expiry during the wait as a confirm timeout' do
    allow(channel).to receive(:wait_for_confirms).and_raise(Timeout::Error)

    result = described_class.publish(exchange: exchange, payload: '{}', envelope: envelope, publisher_confirm: true)

    expect(result).to include(status: :confirm_timeout, accepted: false)
    expect(described_class.channel_usable?(channel: channel)).to be false
  end

  it 'does not label a publish exception as a confirm timeout' do
    allow(channel).to receive(:basic_publish).and_raise(Timeout::Error, 'socket timeout')

    result = described_class.publish(exchange: exchange, payload: '{}', envelope: envelope, publisher_confirm: true)

    expect(result).to include(status: :failed, accepted: false, error_class: 'Timeout::Error')
  end

  it 'bounds the actual Bunny confirm wait, retires that channel, and permits a replacement channel' do
    waiting_channel = Bunny::Channel.allocate
    waiting_channel.instance_variable_set(:@connection, double('session', threaded: true, continuation_timeout: 60_000))
    waiting_channel.instance_variable_set(:@unconfirmed_set_mutex, Mutex.new)
    waiting_channel.instance_variable_set(:@unconfirmed_set, Set.new([1]))
    waiting_channel.instance_variable_set(:@confirms_continuations, Bunny::Concurrent::ContinuationQueue.new)
    waiting_channel.instance_variable_set(:@threads_waiting_on_confirms_continuations, [])
    allow(waiting_channel).to receive(:raise_if_no_longer_open!)
    allow(waiting_channel).to receive(:using_publisher_confirmations?).and_return(true)
    allow(waiting_channel).to receive(:register_exchange)
    allow(waiting_channel).to receive(:record_exchange)
    allow(waiting_channel).to receive(:basic_publish)
    allow(waiting_channel).to receive(:open?).and_return(true)
    expect(waiting_channel).to receive(:close).and_raise(IOError, 'close failed')
    waiting_exchange = Bunny::Exchange.new(waiting_channel, :topic, 'task', no_declare: true)

    result = Timeout.timeout(1) do
      described_class.publish(exchange: waiting_exchange, payload: '{}', envelope: envelope,
                              publisher_confirm: true, confirm_timeout_ms: 20)
    end
    retired = described_class.publish(exchange: waiting_exchange, payload: '{}', envelope: envelope, publisher_confirm: true)
    recovered = described_class.publish(exchange: exchange, payload: '{}', envelope: envelope, publisher_confirm: true)

    expect(result).to include(status: :confirm_timeout, accepted: false)
    expect(retired).to include(status: :failed, accepted: false)
    expect(described_class.channel_usable?(channel: waiting_channel)).to be false
    expect(recovered).to include(status: :accepted, accepted: true)
  end

  it 'uses actual local routing results without requiring AMQP confirm methods' do
    require 'legion/transport/in_process'
    session = Legion::Transport::InProcess::Session.new.start
    local_channel = session.create_channel
    local_exchange = Legion::Transport::InProcess::Exchange.new(local_channel, :topic, 'local.events')
    queue = Legion::Transport::InProcess::Queue.new(local_channel, 'local.queue')
    queue.bind(local_exchange, routing_key: 'events.run')
    delivered = []
    queue.subscribe { |_delivery, _properties, payload| delivered << payload }

    missing = described_class.publish(exchange: local_exchange, payload: 'missing', envelope: { routing_key: 'absent' },
                                      publisher_confirm: true, mandatory: true)
    routed = described_class.publish(exchange: local_exchange, payload: 'delivered', envelope: { routing_key: 'events.run' },
                                     publisher_confirm: true, mandatory: true)

    expect(missing).to include(status: :unroutable, accepted: false)
    expect(routed).to include(status: :accepted, accepted: true)
    expect(delivered).to eq(['delivered'])
  ensure
    session&.close
  end
end
