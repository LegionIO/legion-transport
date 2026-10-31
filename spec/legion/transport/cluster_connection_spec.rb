# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Legion::Transport::Connection, 'cluster node rotation', :rabbitmq do
  before do
    described_class.instance_variable_set(:@session, nil)
    described_class.instance_variable_set(:@channel_thread, Concurrent::ThreadLocalVar.new(nil))
  end

  describe '#build_bunny_opts with cluster_nodes' do
    it 'merges cluster_nodes into resolved hosts' do
      Legion::Settings[:transport][:cluster_nodes] = ['rmq2:5672', 'rmq3:5672']
      opts = described_class.send(:build_bunny_opts, connection_name: 'test')
      expect(opts[:hosts]).to be_a(Array)
      hosts = opts[:hosts].map { |h| "#{h[:host]}:#{h[:port]}" }
      expect(hosts).to include('rmq2', 'rmq3').or include('rmq2:5672', 'rmq3:5672')
      Legion::Settings[:transport][:cluster_nodes] = []
    end

    it 'returns single-host path when cluster_nodes is empty' do
      Legion::Settings[:transport][:cluster_nodes] = []
      opts = described_class.send(:build_bunny_opts, connection_name: 'test')
      expect(opts[:host]).to eq('127.0.0.1')
      expect(opts[:hosts]).to be_nil
    end

    it 'deduplicates hosts from both sources' do
      Legion::Settings[:transport][:cluster_nodes] = Legion::Settings[:transport][:connection][:resolved_hosts].dup
      opts = described_class.send(:build_bunny_opts, connection_name: 'test')
      expect(opts[:host]).to eq('127.0.0.1')
      expect(opts[:hosts]).to be_nil
      Legion::Settings[:transport][:cluster_nodes] = []
    end

    it 'includes all unique hosts when cluster_nodes adds new entries' do
      Legion::Settings[:transport][:cluster_nodes] = ['rmq2:5672']
      opts = described_class.send(:build_bunny_opts, connection_name: 'test')
      hosts = opts[:hosts].map { |h| h[:host] }
      expect(hosts).to include('127.0.0.1')
      expect(hosts).to include('rmq2')
      Legion::Settings[:transport][:cluster_nodes] = []
    end
  end
end

RSpec.describe Legion::Transport::Connection, 'failover' do
  let(:connection) do
    described_class.clone.tap do |copy|
      copy.instance_variables.each { |name| copy.remove_instance_variable(name) }
    end
  end
  let(:hosts) { [{ host: 'unreachable', port: 5672 }, { host: 'available', port: 5673 }] }
  let(:failed) { instance_double(Bunny::Session, close: nil) }
  let(:available) { instance_double(Bunny::Session, start: nil) }

  before do
    stub_const('Legion::Transport::CONNECTOR', Bunny)
    allow(connection).to receive(:build_bunny_opts).and_return(hosts: hosts)
  end

  it 'starts the next host when the first session fails during its handshake' do
    socket = StringIO.new
    failed.instance_variable_set(:@transport, socket)
    allow(Bunny).to receive(:new).with(hosts.first).and_return(failed)
    allow(Bunny).to receive(:new).with(hosts.last).and_return(available)
    allow(failed).to receive(:start).and_raise(Bunny::TCPConnectionFailed, 'refused')
    allow(available).to receive(:start) { raise 'failed socket leaked' unless socket.closed? }

    expect(connection.send(:create_session_with_failover, connection_name: 'test')).to eq(available)
    expect(available).to have_received(:start)
    expect(socket).to be_closed
  end

  it 'advances after a constructor failure as well as a start failure' do
    allow(Bunny).to receive(:new).with(hosts.first).and_raise(Bunny::TCPConnectionFailed, 'refused')
    allow(Bunny).to receive(:new).with(hosts.last).and_return(available)

    expect(connection.send(:create_session_with_failover, connection_name: 'test')).to eq(available)
    expect(available).to have_received(:start)
  end

  it 'closes each failed session before reporting cluster exhaustion' do
    sessions = hosts.map { instance_double(Bunny::Session, close: nil) }
    sockets = sessions.map do |session|
      StringIO.new.tap { |socket| session.instance_variable_set(:@transport, socket) }
    end
    hosts.zip(sessions).each do |host, session|
      allow(Bunny).to receive(:new).with(host).and_return(session)
      allow(session).to receive(:start).and_raise(IOError, 'handshake failed')
    end

    expect do
      connection.send(:create_session_with_failover, connection_name: 'test')
    end.to raise_error(Legion::Transport::ClusterUnavailable)
    expect(sockets).to all(be_closed)
  end

  it 'cleans up an interrupted handshake without treating pool expiry as host failure' do
    socket = StringIO.new
    failed.instance_variable_set(:@transport, socket)
    allow(Bunny).to receive(:new).with(hosts.first).and_return(failed)
    allow(failed).to receive(:start).and_raise(Legion::Transport::PoolTimeout, 'checkout expired')
    expect(Bunny).not_to receive(:new).with(hosts.last)

    expect do
      connection.send(:create_session_with_failover, connection_name: 'test')
    end.to raise_error(Legion::Transport::PoolTimeout)
    expect(socket).to be_closed
  end
end
