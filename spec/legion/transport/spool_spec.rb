# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Legion::Transport::Spool do
  let(:spool_dir) { Dir.mktmpdir('legion-spool') }

  before do
    described_class.reset!
    described_class.setup(directory: spool_dir)
  end

  after do
    described_class.reset!
    FileUtils.rm_rf(spool_dir)
  end

  def pending_payloads
    payloads = []
    described_class.drain do |record|
      payloads << record[:payload]
      true
    end
    payloads
  end

  describe '.write' do
    it 'persists binary wire bytes and returns success only after the append' do
      payload = "\x00\xFF\x80ciphertext".b
      expect(described_class.write(exchange: 'task', routing_key: 'run', payload: payload)).to be true
      expect(pending_payloads).to eq([payload])
    end

    it 'rejects unencoded messages rather than marking a Hash as encrypted wire data' do
      expect do
        described_class.write(exchange: 'task', routing_key: 'run', payload: { secret: true },
                              content_encoding: 'encrypted/cs')
      end.to raise_error(ArgumentError)
      expect(described_class.count).to eq(0)
    end

    %i[write fsync].each do |operation|
      it "raises on #{operation} failure without corrupting previously persisted records" do
        described_class.write(exchange: 'task', routing_key: 'run', payload: 'before')
        allow(File).to receive(:open).and_wrap_original do |original, path, *args, &block|
          if path.end_with?('.jsonl') && args.first.is_a?(Integer)
            original.call(path, *args) do |file|
              allow(file).to receive(operation).and_raise(Errno::ENOSPC)
              block.call(file)
            end
          else
            original.call(path, *args, &block)
          end
        end

        expect do
          described_class.write(exchange: 'task', routing_key: 'run', payload: 'failed')
        end.to raise_error(Errno::ENOSPC)
        expect(pending_payloads).to eq(['before'])
      end
    end
  end

  describe '.drain' do
    it 'retains writes made inside a callback for the next drain' do
      described_class.write(exchange: 'task', routing_key: 'run', payload: 'first')
      delivered = []
      described_class.drain do |record|
        delivered << record[:payload]
        described_class.write(exchange: 'task', routing_key: 'run', payload: 'during replay')
        true
      end

      expect(delivered).to eq(['first'])
      expect(pending_payloads).to eq(['during replay'])
    end

    it 'never gives two concurrent drainers the same claimed file' do
      described_class.write(exchange: 'task', routing_key: 'run', payload: 'once')
      entered = Queue.new
      release = Queue.new
      delivered = Queue.new
      first = Thread.new do
        described_class.drain do |record|
          delivered << record[:payload]
          entered << true
          release.pop
          true
        end
      end
      expect(entered.pop(timeout: 2)).to be true
      second = Thread.new do
        described_class.drain do |record|
          delivered << record[:payload]
          true
        end
      end
      expect(second.join(2)).to eq(second)
      expect(delivered.size).to eq(1)
      release << true
      expect(first.join(2)).to eq(first)
      expect(described_class.count).to eq(0)
    ensure
      release << true if release
      first&.kill&.join(1)
      second&.kill&.join(1)
    end

    it 'allows writers on another thread while a replay callback is waiting' do
      described_class.write(exchange: 'task', routing_key: 'run', payload: 'first')
      entered = Queue.new
      release = Queue.new
      drainer = Thread.new do
        described_class.drain do |_record|
          entered << true
          release.pop
          true
        end
      end
      expect(entered.pop(timeout: 2)).to be true
      writer = Thread.new { described_class.write(exchange: 'task', routing_key: 'run', payload: 'second') }
      expect(writer.join(2)).to eq(writer)
      release << true
      expect(drainer.join(2)).to eq(drainer)
      expect(pending_payloads).to eq(['second'])
    ensure
      release << true if release
      writer&.kill&.join(1)
      drainer&.kill&.join(1)
    end

    it 'removes only a confirmed prefix and retries the unconfirmed record before the remainder' do
      %w[confirmed unconfirmed unprocessed].each do |payload|
        described_class.write(exchange: 'task', routing_key: 'run', payload: payload)
      end
      expect(described_class.drain { |record| record[:payload] == 'confirmed' }).to be false
      expect(pending_payloads).to eq(%w[unconfirmed unprocessed])
    end

    it 'does not treat a truthy publication result as a confirmation' do
      described_class.write(exchange: 'task', routing_key: 'run', payload: 'pending')
      expect(described_class.drain { { accepted: false } }).to be false
      expect(pending_payloads).to eq(['pending'])
    end

    it 'retains the failing record when the callback raises' do
      %w[confirmed failed].each do |payload|
        described_class.write(exchange: 'task', routing_key: 'run', payload: payload)
      end
      described_class.drain do |record|
        raise IOError, 'connection lost' if record[:payload] == 'failed'

        true
      end
      expect(pending_payloads).to eq(['failed'])
    end

    it 'releases an interrupted claim without discarding unconfirmed or unprocessed records' do
      %w[confirmed interrupted unprocessed].each do |payload|
        described_class.write(exchange: 'task', routing_key: 'run', payload: payload)
      end
      entered = Queue.new
      blocked = Queue.new
      drainer = Thread.new do
        described_class.drain do |record|
          if record[:payload] == 'interrupted'
            entered << true
            blocked.pop
          end
          true
        end
      end
      expect(entered.pop(timeout: 2)).to be true
      drainer.kill
      expect(drainer.join(2)).to eq(drainer)
      expect(pending_payloads).to eq(%w[interrupted unprocessed])
    ensure
      drainer&.kill&.join(1)
    end
  end
end
