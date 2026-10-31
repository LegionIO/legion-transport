# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/in_process'

RSpec.describe 'Strict task publication' do
  let(:session) { Legion::Transport::InProcess::Session.new.start }
  let(:channel) { session.create_channel }
  let(:exchange) { channel.exchange('task.boundaries', type: :topic) }
  let(:queue) { Legion::Transport::InProcess::Queue.new(channel, 'task.boundaries.queue') }
  let(:message) { Legion::Transport::Messages::Task.new(function: 'execute', routing_key: 'jobs.execute', encrypt: false) }

  around do |example|
    original_loader = Legion::Settings.loader
    original = original_loader.settings[:task_execution]
    original_transport = Legion::Settings[:transport]
    begin
      original_loader.settings[:transport] = original_transport.merge(task_publication: original_transport.fetch(:task_publication).dup)
      original_loader.settings[:task_execution] = {
        routes: { check_subtask: 'custom.continuation', transform: 'custom.transform', conditioner: 'custom.conditioner', task_update: 'custom.update' },
        statuses: { completed: 'custom.completed' }, terminal_statuses: [], legacy_terminal_statuses: [],
        message_types: { task: 'custom.task' }, protocol: { version: 99, metadata_fields: [] },
        publication: { mandatory: false, publisher_confirm: false, spool: true }
      }
      example.run
    ensure
      Legion::Settings.loader = original_loader
      original_loader.settings[:task_execution] = original
      original_loader.settings.delete(:task_execution) if original.nil?
      original_loader.settings[:transport] = original_transport
    end
  end

  before do
    Legion::Transport::Local.reset!
    allow(message).to receive(:exchange).and_return(exchange)
  end

  after do
    session.close
    Legion::Transport::Local.reset!
  end

  it 'returns an explicit acceptance for a routed pending message without implying execution' do
    queue.bind(exchange, routing_key: 'jobs.execute')

    expect(message.publish!).to include(accepted: true, status: :accepted, routing_key: 'jobs.execute')
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(1)
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << Legion::JSON.load(payload) }
    expect(received).to eq([{ function: 'execute' }])
  end

  it 'rejects an unroutable publication without buffering an imaginary destination' do
    expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected) { |error|
      expect(error.result).to include(accepted: false, status: :unroutable)
    }
    queue.bind(exchange, routing_key: 'jobs.execute')
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(0)
  end

  it 'does not report callback failure as delivery and retains the message for replacement' do
    queue.bind(exchange, routing_key: 'jobs.execute')
    consumer = queue.subscribe { |_info, _properties, _payload| raise IOError, 'worker unavailable' }
    expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected) { |error|
      expect(error.result).to include(accepted: false, status: :failed, error_class: 'IOError')
    }
    consumer.cancel
    received = []
    queue.subscribe(manual_ack: false) { |info, _properties, payload| received << [info.redelivered, Legion::JSON.load(payload)] }
    expect(received).to eq([[true, { function: 'execute' }]])
  end

  it 'retains a pending delivery when its first subscriber fails' do
    queue.bind(exchange, routing_key: 'jobs.execute')
    message.publish!
    expect { queue.subscribe { |_info, _properties, _payload| raise IOError, 'failed backlog' } }.to raise_error(IOError, 'failed backlog')
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(1)
    received = []
    queue.subscribe(manual_ack: false) { |info, _properties, payload| received << [info.redelivered, Legion::JSON.load(payload)] }
    expect(received).to eq([[true, { function: 'execute' }]])
  end

  it 'preserves encrypted retry bytes, identity and retry headers through strict raw publishing' do
    queue.bind(exchange, routing_key: 'jobs.execute')
    received = []
    queue.subscribe(manual_ack: false) { |info, properties, payload| received << [info, properties, payload] }
    bytes = "\x00\xFFencrypted".b
    envelope = {
      routing_key: 'jobs.execute', message_id: 'logical-task', correlation_id: 'chain', content_type: 'application/json',
      content_encoding: 'encrypted/cs', headers: { iv: 'unchanged-iv', retry_count: 2, principal_id: 'caller', execution_token: 'claim' }
    }

    result = Legion::Transport::Publisher.publish!(exchange: exchange, payload: bytes, envelope: envelope)
    expect(result).to include(accepted: true, message_id: 'logical-task', correlation_id: 'chain')
    expect(received.first[1]).to include(envelope.except(:routing_key))
    expect(received.first[2]).to eq(bytes)
    expect(envelope).not_to have_key(:mandatory)
  end

  it 'uses the canonical continuation route despite obsolete settings and an explicit stale route' do
    queue.bind(exchange, routing_key: 'task.subtask.check')
    continuation = Legion::Transport::Messages::CheckSubtask.new(task_id: 9, routing_key: 'obsolete.route', encrypt: false)
    allow(continuation).to receive(:exchange).and_return(exchange)

    expect(continuation.publish!).to include(accepted: true, routing_key: 'task.subtask.check')
  end

  it 'preserves typed lineage, policy, transform context and business args across a subtask handoff' do
    queue.bind(exchange, routing_key: 'task.subtask.transform')
    received = []
    queue.subscribe(manual_ack: false) { |_info, properties, payload| received << [properties, Legion::JSON.load(payload)] }
    metadata = {
      task_id: 9, parent_id: 8, master_id: 1, chain_id: 'chain', function: 'execute', function_id: 7, relationship_id: 3,
      runner_class: 'Worker', runner_routing_key: 'worker', trigger_runner_id: 2, trigger_function_id: 4, debug: false,
      engine: 'json', schema: { type: 'object', required: ['order_id'] }, engine_options: { strict: true },
      principal_id: 'principal', principal_type: 'service', tenant_id: 'tenant', worker_id: 'worker-id', source: 'scheduler',
      message_id: 'message', correlation_id: 'correlation', attempt_id: 12, execution_token: 'token', depth: 0,
      deadline_at: '2026-11-01T00:00:00Z', schedule_id: 5, occurrence_id: 'occurrence', definition_version: 2
    }
    subtask = Legion::Transport::Messages::SubTask.new(**metadata, transformation: '{}', args: { order_id: 42 }, results: { total: 7 }, encrypt: false)
    allow(subtask).to receive(:exchange).and_return(exchange)

    expect(subtask.publish!).to include(accepted: true, routing_key: 'task.subtask.transform')
    properties, body = received.fetch(0)
    expect(body).to include(metadata.merge(args: { order_id: 42 }, results: { total: 7 }, transformation: '{}'))
    expect(properties.headers).to include(metadata.merge(task_protocol_version: 1))
    expect(properties.type).to eq('task')
    expect(body.fetch(:args)).not_to have_key(:principal_id)
    expect(body).not_to have_key(:encrypt)
  end

  it 'does not discard dynamic task identity or insert policy fields into business args' do
    queue.bind(exchange, routing_key: 'orders.worker.execute')
    received = []
    queue.subscribe(manual_ack: false) { |_info, properties, payload| received << [properties, Legion::JSON.load(payload)] }
    extension = double('extension', values: { name: 'orders' })
    runner = double('runner', extension: extension, values: { name: 'worker' })
    function = double('function', runner: runner, values: { name: 'execute' })
    dynamic = Legion::Transport::Messages::Dynamic.new(function_id: 7, task_id: 9, parent_id: 4, principal_id: 'caller',
                                                       schema: { type: 'object' }, args: { order_id: 42 }, encrypt: false)
    allow(dynamic).to receive(:function).and_return(function)
    allow(dynamic).to receive(:exchange).and_return(exchange)

    expect(dynamic.publish!).to include(accepted: true)
    properties, body = received.fetch(0)
    expect(body).to include(task_id: 9, parent_id: 4, function_id: 7, function: 'execute', principal_id: 'caller',
                            schema: { type: 'object' }, args: { order_id: 42 })
    expect(properties.headers).to include(task_id: 9, parent_id: 4, principal_id: 'caller')
  end

  it 'does not bypass a short condition object in favor of a later transformation' do
    queue.bind(exchange, routing_key: 'task.subtask.conditioner')
    stage = Legion::Transport::Messages::Task.new(function: 'execute', conditions: '{}', transformation: '{}', encrypt: false)
    allow(stage).to receive(:exchange).and_return(exchange)

    expect(stage.publish!).to include(accepted: true, routing_key: 'task.subtask.conditioner')
  end

  it 'publishes and recognizes canonical completion despite obsolete status and terminal overrides' do
    queue.bind(exchange, routing_key: 'task.update')
    received = []
    queue.subscribe(manual_ack: false) { |_info, _properties, payload| received << Legion::JSON.load(payload) }
    update = Legion::Transport::Messages::TaskUpdate.new(task_id: 9, status: 'task.completed', encrypt: false)
    allow(update).to receive(:exchange).and_return(exchange)

    expect(update.publish!).to include(accepted: true, routing_key: 'task.update')
    expect(update.task_terminal_status?(status: received.fetch(0).fetch(:status))).to be(true)
    expect(update.task_terminal_status?(status: 'complete')).to be(true)
    expect(update.task_terminal_status?(status: 'task.running')).to be(false)
    expect { Legion::Transport::Messages::TaskUpdate.new(task_id: 9, status: 'custom.completed') }.to raise_error(Legion::Exception::InvalidTaskStatus)
  end

  it 'applies live local mandatory policy to message and raw publishing without resetting it' do
    Legion::Settings[:transport][:task_publication][:mandatory] = false
    expect(message.publish!).to include(accepted: true)
    expect(Legion::Transport::Publisher.publish!(exchange: exchange, payload: 'raw', envelope: { routing_key: 'missing' })).to include(accepted: true)

    Legion::Settings[:transport][:task_publication][:mandatory] = true
    expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected)
    expect do
      Legion::Transport::Publisher.publish!(exchange: exchange, payload: 'raw', envelope: { routing_key: 'missing' })
    end.to raise_error(Legion::Transport::PublishRejected)
  end

  it 'recovers owned defaults after loader replacement while preserving local policy and live connection state' do
    replacement = Legion::Settings::Loader.new
    replacement.settings[:transport] = { task_publication: { mandatory: false }, connected: true }
    Legion::Settings.loader = replacement

    expect(message.publish!).to include(accepted: true)
    expect(Legion::Settings[:transport][:connected]).to be(true)
    Legion::Settings[:transport][:task_publication][:mandatory] = true
    expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected)
    expect(Legion::Settings[:transport][:connected]).to be(true)
  end

  it 'rejects malformed local publication policy before queuing work' do
    queue.bind(exchange, routing_key: 'jobs.execute')
    Legion::Settings[:transport][:task_publication][:mandatory] = 'false'

    expect { message.publish! }.to raise_error(Legion::Transport::Settings::ConfigurationError)
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(0)
  end

  it 'rejects a nonpositive confirmation timeout before queuing work' do
    queue.bind(exchange, routing_key: 'jobs.execute')
    Legion::Settings[:transport][:task_publication][:publish_confirm_timeout_ms] = 0

    expect { message.publish! }.to raise_error(Legion::Transport::Settings::ConfigurationError)
    expect(Legion::Transport::Local.queue_depth(queue.name)).to eq(0)
  end

  it 'keeps legacy non-task publication return behavior unchanged' do
    queue.bind(exchange, routing_key: 'events.created')
    legacy = Legion::Transport::Message.new(routing_key: 'events.created', encrypt: false, event: 'created')
    allow(legacy).to receive(:exchange).and_return(exchange)

    expect(legacy.publish).to be_nil
    expect(legacy.publish!).to include(accepted: true, status: :accepted)
  end
end

RSpec.describe Legion::Transport::Message, '#publish! broker boundaries' do
  let(:channel) do
    instance_double(Bunny::Channel, register_exchange: nil, record_exchange: nil, using_publisher_confirmations?: false,
                                    confirm_select: true, wait_for_confirms: true, open?: true, close: true)
  end
  let(:exchange) { Bunny::Exchange.new(channel, :topic, 'strict.tasks', no_declare: true) }
  let(:message) { described_class.new(routing_key: 'work', encrypt: false, task_id: 4) }

  before do
    allow(message).to receive(:exchange).and_return(exchange)
    allow(channel).to receive(:basic_publish)
  end

  it 'raises with the broker nack rather than returning a truthy failure hash' do
    allow(channel).to receive(:wait_for_confirms).and_return(false)
    expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected) { |error|
      expect(error.result).to include(accepted: false, status: :nacked)
    }
  end

  it 'raises an ambiguous timeout result and retires the channel' do
    allow(channel).to receive(:wait_for_confirms).and_raise(Timeout::Error)
    expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected) { |error|
      expect(error.result).to include(accepted: false, status: :confirm_timeout)
    }
    expect(Legion::Transport::Publisher.channel_usable?(channel: channel)).to be false
  end

  it 'never acknowledges a spool write as publication acceptance and disables the second spool by default' do
    Dir.mktmpdir('strict-task-spool') do |directory|
      Legion::Transport::Spool.reset!
      Legion::Transport::Spool.setup(directory: directory)
      allow(channel).to receive(:basic_publish).and_raise(IOError, 'broker unavailable')

      expect { message.publish! }.to raise_error(Legion::Transport::PublishRejected) { |error|
        expect(error.result).to include(accepted: false, status: :failed)
      }
      expect(Legion::Transport::Spool.count).to eq(0)
      expect { message.publish!(spool: true) }.to raise_error(Legion::Transport::PublishRejected) { |error|
        expect(error.result).to include(accepted: false, status: :spooled)
      }
      expect(Legion::Transport::Spool.count).to eq(1)
    ensure
      Legion::Transport::Spool.reset!
    end
  end
end
