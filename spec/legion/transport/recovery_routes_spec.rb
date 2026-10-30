# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'
require 'rack/mock'
require 'tmpdir'
require 'legion/transport/in_process'

RSpec.describe Legion::Transport::Routes, 'spool recovery API' do
  let(:directory) { Dir.mktmpdir('legion-recovery-api') }
  let(:channel) { Legion::Transport::InProcess::Channel.new }
  let(:deliveries) { Queue.new }
  let(:app) do
    Class.new(Sinatra::Base) do
      set :environment, :test
      set :host_authorization, permitted: :any
      register Legion::Transport::Routes
    end
  end
  let(:request) { Rack::MockRequest.new(app) }

  before do
    Legion::Transport::Spool.reset!
    Legion::Transport::Spool.setup(directory: directory)
    @messages = Legion::Settings[:transport][:messages]
    @topology = Legion::Settings[:transport][:tenant_topology]
    Legion::Settings[:transport][:messages] = @messages.merge(encrypt: false)
    Legion::Settings[:transport][:tenant_topology] = { enabled: false }
    Legion::Transport::Local.reset!
    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
    destination = channel.exchange('api.repaired', type: :topic)
    queue = Legion::Transport::InProcess::Queue.new(channel, 'api.recovery.received')
    queue.bind(destination, routing_key: 'run')
    queue.subscribe { |_delivery, _properties, payload| deliveries << payload }
    original = { exchange: 'Legion::Transport::Messages::Direct', routing_key: 'run',
                 payload: { secret: 'inspect only by id', encrypt: false }, spooled_at: Time.now.iso8601 }
    File.write(File.join(directory, 'legacy.jsonl'), "#{Legion::JSON.dump(original)}\n")
    Legion::Transport::Spool.replay_async
    await_recovery_worker
  end

  after do
    Legion::Transport::Spool.reset!
    Legion::Transport::Local.reset!
    Legion::Settings[:transport][:messages] = @messages
    Legion::Settings[:transport][:tenant_topology] = @topology
    FileUtils.rm_rf(directory)
  end

  def await_recovery_worker
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while (worker = Legion::Transport::Spool.instance_variable_get(:@replay_thread))
      expect(worker.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)).to eq(worker)
    end
  end

  it 'supports inspection, repair, confirmed delivery and idempotent retry without editing spool files' do
    response = request.get('/api/transport/spool')
    expect(response.status).to eq(200)
    expect(Legion::JSON.load(response.body)[:data]).to include(quarantined: 1, pending: 0)
    response = request.get('/api/transport/spool/recovery?status=quarantined&limit=1')
    expect(response.status).to eq(200)
    expect(response.body).not_to include('inspect only by id')
    id = Legion::JSON.load(response.body)[:data].fetch(0).fetch(:id)
    response = request.get("/api/transport/spool/recovery/#{id}")
    expect(Legion::JSON.load(response.body)[:data][:record][:payload][:secret]).to eq('inspect only by id')

    response = request.post("/api/transport/spool/recovery/#{id}/repair",
                            'CONTENT_TYPE' => 'application/json', input: Legion::JSON.dump({ exchange: 'api.repaired' }))
    expect(response.status).to eq(202)
    expect(Legion::JSON.load(response.body)[:data]).to include(status: 'ready')
    await_recovery_worker
    expect(Legion::JSON.load(deliveries.pop(timeout: 2))).to include(secret: 'inspect only by id')
    response = request.get("/api/transport/spool/recovery/#{id}")
    expect(Legion::JSON.load(response.body)[:data]).to include(status: 'delivered', raw_line: nil, record: nil)
    response = request.post("/api/transport/spool/recovery/#{id}/retry")
    expect(response.status).to eq(200)
    expect(deliveries).to be_empty
    response = request.post("/api/transport/spool/recovery/#{id}/repair",
                            'CONTENT_TYPE' => 'application/json', input: Legion::JSON.dump({ exchange: 'another' }))
    expect(response.status).to eq(422)
    expect(Legion::Transport::Spool.recovery_record(id: id)[:status]).to eq('delivered')
  end

  it 'rejects invalid changes and unknown ids without mutating the recovery entry' do
    entry = Legion::Transport::Spool.recovery_entries.fetch(0)
    original = Legion::Transport::Spool.recovery_record(id: entry[:id])
    response = request.post("/api/transport/spool/recovery/#{entry[:id]}/repair",
                            'CONTENT_TYPE' => 'application/json', input: Legion::JSON.dump({ encrypt: 'false' }))
    expect(response.status).to eq(422)
    expect(Legion::Transport::Spool.recovery_record(id: entry[:id])).to eq(original)
    expect(request.get("/api/transport/spool/recovery/#{'0' * 32}").status).to eq(404)
    expect(request.get('/api/transport/spool/recovery/not-an-id').status).to eq(422)
    expect(request.get('/api/transport/spool/recovery?limit=0').status).to eq(422)
    expect(deliveries).to be_empty
  end
end
