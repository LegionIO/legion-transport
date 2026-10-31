# frozen_string_literal: true

require 'spec_helper'
require 'legion/json'
require 'open3'
require 'rbconfig'

RSpec.describe 'Lite transport wrapper integration' do
  it 'initializes real wrappers, delivers ordered encrypted envelopes, and retires consumers on shutdown' do
    script = <<~RUBY
      require 'legion/json'
      require 'legion/settings'
      Legion::Settings.load
      require 'legion/transport'

      connection = Legion::Transport::Connection
      connection.setup
      channel = connection.channel
      exchange = Legion::Transport::Exchange.new('integration.events')
      queue = Legion::Transport::Queue.new('integration.work')
      queue.bind(exchange, routing_key: 'work.#')
      envelope = { content_encoding: 'aes-256-gcm', headers: { 'iv' => 'encrypted-iv' }, message_id: 'wire-message' }
      exchange.publish('backlog', routing_key: 'work.first', **envelope)
      deliveries = []
      consumer = queue.subscribe do |info, properties, payload|
        deliveries << [info.exchange, info.routing_key, properties.content_encoding, properties.headers['iv'], payload]
        queue.acknowledge(info.delivery_tag)
        exchange.publish('nested', routing_key: 'work.next', **envelope) if payload == 'backlog'
      end
      consumer.cancel
      exchange.publish('pending', routing_key: 'work.later', **envelope)
      pending = Legion::Transport::Local.queue_depth(queue.name)
      active_queue = Legion::Transport::Queue.new('integration.active')
      active_consumer = active_queue.subscribe { |_info, _properties, _payload| raise 'unexpected active delivery' }
      connection.shutdown
      puts Legion::JSON.dump({ deliveries: deliveries, pending_before_shutdown: pending,
                               pending_after_shutdown: Legion::Transport::Local.queue_depth(queue.name),
                               cancelled: consumer.cancelled? && active_consumer.cancelled?, channel_closed: !channel.open? })
    RUBY
    root = File.expand_path('../../..', __dir__)
    stdout, stderr, status = Open3.capture3(
      { 'LEGION_MODE' => 'lite', 'LEGION_DNS_BOOTSTRAP' => 'false' },
      RbConfig.ruby, '-Ilib', '-e', script, chdir: root
    )

    expect(status.success?).to be(true), stderr
    result = Legion::JSON.load(stdout.lines.last)
    expect(result).to eq(
      deliveries:              [
        ['integration.events', 'work.first', 'aes-256-gcm', 'encrypted-iv', 'backlog'],
        ['integration.events', 'work.next', 'aes-256-gcm', 'encrypted-iv', 'nested']
      ],
      pending_before_shutdown: 1,
      pending_after_shutdown:  0,
      cancelled:               true,
      channel_closed:          true
    )
  end
end
