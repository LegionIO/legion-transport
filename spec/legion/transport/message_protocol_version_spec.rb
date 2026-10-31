# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Protocol version header' do
  around do |example|
    original = Legion::Settings[:transport][:messages][:protocol_version]
    Legion::Settings[:transport][:messages][:protocol_version] = 'configured-protocol'
    example.run
  ensure
    Legion::Settings[:transport][:messages][:protocol_version] = original
  end

  let(:message_class) do
    Class.new(Legion::Transport::Message) do
      def exchange = nil

      def routing_key = 'test.key'

      def valid? = true
    end
  end

  it 'uses the configured protocol version in outgoing headers' do
    msg = message_class.new(function: 'test')
    expect(msg.headers).to include('legion_protocol_version' => 'configured-protocol')
  end

  it 'includes x-legion-version when Legion::VERSION is loaded' do
    stub_const('Legion::VERSION', '1.9.99')
    msg = message_class.new(function: 'test')
    expect(msg.headers).to include('x-legion-version' => '1.9.99')
  end

  it 'preserves existing headers alongside protocol version' do
    msg = message_class.new(function: 'test', task_id: 42)
    hdrs = msg.headers
    expect(hdrs['legion_protocol_version']).to eq('configured-protocol')
    expect(hdrs[:task_id]).to eq(42)
  end
end
