# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Transport::Settings do
  describe '.connection' do
    subject(:connection) { described_class.connection }

    it 'returns port as an integer' do
      expect(connection[:port]).to be_a(Integer)
      expect(connection[:port]).to eq(5672)
    end

    it 'resolves host to a string' do
      expect(connection[:host]).to be_a(String)
      expect(connection[:host]).to eq('127.0.0.1')
    end

    it 'includes resolved_hosts array' do
      expect(connection[:resolved_hosts]).to be_a(Array)
      expect(connection[:resolved_hosts]).to eq(['127.0.0.1:5672'])
    end
  end

  describe '.default' do
    subject(:defaults) { described_class.default }

    it 'includes connection settings' do
      expect(defaults[:connection]).to be_a(Hash)
      expect(defaults[:connection][:port]).to be_a(Integer)
    end
  end
end

RSpec.describe Legion::Transport::Settings, '.resolve_hosts' do
  it 'returns default localhost with AMQP port when no args given' do
    result = described_class.resolve_hosts
    expect(result).to eq(['127.0.0.1:5672'])
  end

  it 'accepts singular host string' do
    result = described_class.resolve_hosts(host: '10.0.0.5')
    expect(result).to eq(['10.0.0.5:5672'])
  end

  it 'accepts hosts array' do
    result = described_class.resolve_hosts(hosts: ['10.0.0.5', '10.0.0.6'])
    expect(result).to eq(['10.0.0.5:5672', '10.0.0.6:5672'])
  end

  it 'accepts singular server string' do
    result = described_class.resolve_hosts(server: '10.0.0.5')
    expect(result).to eq(['10.0.0.5:5672'])
  end

  it 'accepts servers array' do
    result = described_class.resolve_hosts(servers: ['10.0.0.5', '10.0.0.6'])
    expect(result).to eq(['10.0.0.5:5672', '10.0.0.6:5672'])
  end

  it 'merges all input sources together' do
    result = described_class.resolve_hosts(
      host: '10.0.0.1', hosts: ['10.0.0.2'], server: '10.0.0.3', servers: ['10.0.0.4']
    )
    expect(result).to contain_exactly(
      '10.0.0.1:5672', '10.0.0.2:5672', '10.0.0.3:5672', '10.0.0.4:5672'
    )
  end

  it 'preserves explicit ports' do
    result = described_class.resolve_hosts(host: '10.0.0.5:5671')
    expect(result).to eq(['10.0.0.5:5671'])
  end

  it 'injects default port only where missing' do
    result = described_class.resolve_hosts(hosts: ['10.0.0.5:5671', '10.0.0.6'])
    expect(result).to eq(['10.0.0.5:5671', '10.0.0.6:5672'])
  end

  it 'deduplicates entries' do
    result = described_class.resolve_hosts(host: '10.0.0.5', server: '10.0.0.5')
    expect(result).to eq(['10.0.0.5:5672'])
  end

  it 'allows port override' do
    result = described_class.resolve_hosts(host: '10.0.0.5', port: 5671)
    expect(result).to eq(['10.0.0.5:5671'])
  end
end

RSpec.describe Legion::Transport::Settings, '.connection with server overrides' do
  it 'resolves server from settings when present' do
    Legion::Settings[:transport][:connection][:server] = '10.0.0.5'
    conn = described_class.connection
    expect(conn[:resolved_hosts]).to include('10.0.0.5:5672')
    Legion::Settings[:transport][:connection].delete(:server)
  end

  it 'resolves servers array from settings when present' do
    Legion::Settings[:transport][:connection][:servers] = ['10.0.0.5', '10.0.0.6']
    conn = described_class.connection
    expect(conn[:resolved_hosts]).to include('10.0.0.5:5672', '10.0.0.6:5672')
    Legion::Settings[:transport][:connection].delete(:servers)
  end
end
