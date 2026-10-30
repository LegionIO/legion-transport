# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'fileutils'
require 'timeout'
require 'tmpdir'
require 'legion/transport/spool/recovery_store'

RSpec.describe Legion::Transport::Spool::RecoveryStore do
  let(:spool_dir) { Dir.mktmpdir('legion-spool-recovery') }
  let(:recovery_dir) { File.join(spool_dir, 'recovery') }
  let(:store) { described_class.new(directory: spool_dir) }
  let(:record_id) { 'a' * 32 }
  let(:record) { { exchange: 'tasks', payload: { task_id: 42 }, tenant_id: 'tenant-a' } }
  let(:raw_line) { "  #{Legion::JSON.dump(record)}\r\n" }
  let(:error) { ArgumentError.new('saved routing key is missing') }

  after { FileUtils.remove_entry_secure(spool_dir) }

  def seed_entry(id: record_id, status: 'quarantined')
    store.store(id: id, record: record, raw_line: raw_line, error: error, status: status)
  end

  def temporary_files
    Dir.glob(File.join(recovery_dir, '*.json.*'))
  end

  describe '#store' do
    it 'preserves parsed metadata and the exact original bytes across a reopened store' do
      original_bytes = "\x00\xFF\xFE  invalid JSON\r\n".b
      store.store(id: record_id, record: nil, raw_line: original_bytes, error: error)
      recovered = described_class.new(directory: spool_dir).fetch(id: record_id)

      expect(recovered).to include(id: record_id, record: nil, status: 'quarantined',
                                   error_class: 'ArgumentError', error: error.message)
      expect(Base64.strict_decode64(recovered[:raw_line])).to eq(original_bytes)
      expect(Time.iso8601(recovered[:recorded_at])).to be <= Time.now

      parsed = seed_entry(id: 'b' * 32)
      expect(parsed[:record]).to eq(record)
      expect(Base64.strict_decode64(parsed[:raw_line])).to eq(raw_line)
    end

    it 'accepts serialized errors from journal recovery markers' do
      entry = store.store(id: record_id, record: record, raw_line: raw_line,
                          error: { error_class: 'LegacyRecordError', error: 'destination is missing' }, status: :waiting)

      expect(store.fetch(id: entry[:id])).to include(error_class: 'LegacyRecordError', error: 'destination is missing', status: 'waiting')
    end

    %w[ready delivered].each do |status|
      it "does not replace a #{status} entry with an old quarantine marker" do
        seed_entry
        repaired = store.update(id: record_id) do |entry|
          entry.merge(status: status, wire_record: { payload: 'repaired bytes' }, repaired_at: '2026-10-30T12:00:00Z')
        end
        duplicate = store.store(id: record_id, record: { payload: 'stale' }, raw_line: 'stale', error: error)

        expect(duplicate).to eq(repaired)
        expect(described_class.new(directory: spool_dir).fetch(id: record_id)).to eq(repaired)
        expect(store.count).to eq(1)
      end
    end

    it 'preserves the first quarantine evidence on a repeated store' do
      original = seed_entry
      duplicate = store.store(id: record_id, record: nil, raw_line: 'different', error: RuntimeError.new('different'))

      expect(duplicate).to eq(original)
    end
  end

  describe '#update' do
    it 'preserves unknown metadata when a callback returns only its changed fields' do
      original = seed_entry
      store.update(id: record_id) { { operator_metadata: { ticket: 'INC-42' }, wire_record: { payload: 'wire' } } }
      updated = store.update(id: record_id) { { status: :ready, repaired_at: '2026-10-30T12:00:00Z' } }

      expect(updated).to include(original.except(:status))
      expect(store.fetch(id: record_id)).to include(status: 'ready', operator_metadata: { ticket: 'INC-42' },
                                                    wire_record: { payload: 'wire' }, repaired_at: '2026-10-30T12:00:00Z')
    end

    it 'rejects changes to entry identity without changing the persisted record' do
      original = seed_entry

      expect { store.update(id: record_id) { { id: 'b' * 32 } } }.to raise_error(ArgumentError, /immutable/)
      expect { store.update(id: record_id) { { 'id' => 'b' * 32 } } }.to raise_error(ArgumentError)
      expect(store.fetch(id: record_id)).to eq(original)
      expect(store.count).to eq(1)
    end

    it 'rejects a non-Hash callback result without persisting its in-memory changes' do
      original = seed_entry

      expect do
        store.update(id: record_id) do |entry|
          entry[:status] = 'ready'
          false
        end
      end.to raise_error(ArgumentError)
      expect(store.fetch(id: record_id)).to eq(original)
    end

    it 'raises KeyError for missing entries rather than creating a replacement' do
      expect { store.fetch(id: record_id) }.to raise_error(KeyError)
      expect { store.update(id: record_id) { { status: 'ready' } } }.to raise_error(KeyError)
      expect(store.count).to eq(0)
    end
  end

  describe 'listing and capacity accounting' do
    it 'paginates deterministically, filters before pagination, and counts every persisted entry' do
      ids = 105.times.map { |index| format('%032x', index) }
      ids.reverse_each.with_index { |id, index| seed_entry(id: id, status: index.even? ? 'ready' : 'quarantined') }
      File.write(File.join(recovery_dir, 'incomplete.tmp'), 'uncommitted')
      File.write(File.join(recovery_dir, 'unrelated.json'), '{}')

      expect(store.entries.map { |entry| entry[:id] }).to eq(ids.first(100))
      expect(store.entries(limit: 10, offset: 100).map { |entry| entry[:id] }).to eq(ids.last(5))
      expect(store.entries(limit: 10, offset: 105)).to eq([])
      expect(store.entries(status: :ready, limit: 3, offset: 2).map { |entry| entry[:id] }).to eq(ids.values_at(4, 6, 8))
      expect(store.count).to eq(105)
      expect(store.count(status: 'ready')).to eq(53)
      expect(store.bytes).to eq(ids.sum { |id| File.size(File.join(recovery_dir, "#{id}.json")) })
    end

    it 'rejects invalid pagination instead of coercing or silently truncating it' do
      [0, -1, 1.5, '10', nil].each do |limit|
        expect { store.entries(limit: limit) }.to raise_error(ArgumentError)
      end
      [-1, 1.5, '0', nil].each do |offset|
        expect { store.entries(offset: offset) }.to raise_error(ArgumentError)
      end
    end

    it 'rejects traversal, uppercase, incorrectly sized and non-String IDs before using them as paths' do
      ['../outside', 'A' * 32, 'a' * 31, "#{record_id}\n", "#{record_id}/child", nil, 123].each do |id|
        expect { seed_entry(id: id) }.to raise_error(ArgumentError)
        expect { store.fetch(id: id) }.to raise_error(ArgumentError)
        expect { store.update(id: id) { { status: 'ready' } } }.to raise_error(ArgumentError)
      end
      expect(store.count).to eq(0)
    end
  end

  describe 'persistence failures' do
    %i[write flush fsync].each do |operation|
      it "retains old entries and cleans incomplete replacements when #{operation} fails" do
        original = seed_entry
        allow(File).to receive(:open).and_wrap_original do |open, path, *args, &block|
          file = open.call(path, *args, &block)
          allow(file).to receive(operation).and_raise(Errno::ENOSPC) if path.end_with?('.tmp')
          file
        end

        expect { store.update(id: record_id) { { status: 'ready' } } }.to raise_error(Errno::ENOSPC)
        expect { seed_entry(id: 'b' * 32) }.to raise_error(Errno::ENOSPC)
        expect(store.fetch(id: record_id)).to eq(original)
        expect(store.count).to eq(1)
        expect(temporary_files).to eq([])
      end
    end

    it 'rejects short writes and retains the complete prior entry' do
      original = seed_entry
      allow(File).to receive(:open).and_wrap_original do |open, path, *args, &block|
        file = open.call(path, *args, &block)
        allow(file).to(receive(:write).and_wrap_original { |write, serialized| write.call(serialized.byteslice(0, 3)) }) if path.end_with?('.tmp')
        file
      end

      expect { store.update(id: record_id) { { status: 'ready' } } }.to raise_error(IOError, /incomplete/)
      expect(store.fetch(id: record_id)).to eq(original)
      expect(temporary_files).to eq([])
    end

    it 'preserves a preexisting temporary file when exclusive creation fails' do
      store
      allow(SecureRandom).to receive(:hex).with(16).and_return('f' * 32)
      collision = File.join(recovery_dir, "#{record_id}.json.#{'f' * 32}.tmp")
      File.binwrite(collision, 'owned by another writer')

      expect { seed_entry }.to raise_error(Errno::EEXIST)
      expect(File.binread(collision)).to eq('owned by another writer')
      expect(store.count).to eq(0)
    end

    it 'retains the prior entry if atomic replacement fails' do
      original = seed_entry
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(anything, File.join(recovery_dir, "#{record_id}.json")).and_raise(Errno::EIO)

      expect { store.update(id: record_id) { { status: 'ready' } } }.to raise_error(Errno::EIO)
      expect(store.fetch(id: record_id)).to eq(original)
      expect(temporary_files).to eq([])
    end

    it 'restores the previous entry when directory fsync fails after replacement' do
      original = seed_entry
      fail_next_sync = true
      allow(File).to receive(:open).and_wrap_original do |open, path, *args, &block|
        if path == recovery_dir && fail_next_sync
          fail_next_sync = false
          open.call(path, *args) do |directory|
            allow(directory).to receive(:fsync).and_raise(Errno::EIO)
            block.call(directory)
          end
        else
          open.call(path, *args, &block)
        end
      end

      expect { store.update(id: record_id) { { status: 'ready' } } }.to raise_error(Errno::EIO)
      expect(store.fetch(id: record_id)).to eq(original)
      expect(temporary_files).to eq([])
      fail_next_sync = true
      expect { seed_entry(id: 'b' * 32) }.to raise_error(Errno::EIO)
      expect(store.count).to eq(1)
      expect(temporary_files).to eq([])
    end

    it 'logs persistence failure without logging the payload or exception message' do
      seed_entry
      logger = double('logger', error: nil)
      allow(store).to receive(:log).and_return(logger)
      allow(File).to receive(:rename).and_raise(IOError, 'secret payload contents')

      expect { store.update(id: record_id) { { status: 'ready' } } }.to raise_error(IOError, 'secret payload contents')
      expect(logger).to have_received(:error).with(a_string_including('IOError'))
      expect(logger).not_to have_received(:error).with(a_string_including('secret payload contents'))
    end

    it 'cleans an interrupted replacement, retains the previous state and releases its record lock' do
      original = seed_entry
      entered = Queue.new
      blocked = Queue.new
      allow(File).to receive(:open).and_wrap_original do |open, path, *args, &block|
        file = open.call(path, *args, &block)
        if path.end_with?('.tmp')
          allow(file).to receive(:write).and_wrap_original do |write, serialized|
            written = write.call(serialized)
            entered << true
            blocked.pop
            written
          end
        end
        file
      end
      writer = Thread.new { store.update(id: record_id) { { status: 'ready' } } }
      expect(entered.pop(timeout: 2)).to be true
      writer.kill
      expect(writer.join(2)).to eq(writer)
      allow(File).to receive(:open).and_call_original

      expect(store.fetch(id: record_id)).to eq(original)
      expect(temporary_files).to eq([])
      expect(store.update(id: record_id) { { status: 'ready' } }[:status]).to eq('ready')
    ensure
      writer&.kill&.join(1)
    end
  end

  describe 'record ownership' do
    it 'allows unrelated mutations and all read APIs while an update callback is blocked' do
      original = seed_entry
      entered = Queue.new
      release = Queue.new
      updater = Thread.new do
        store.update(id: record_id) do
          entered << true
          release.pop
          { status: 'ready' }
        end
      end
      expect(entered.pop(timeout: 2)).to be true
      independent = Thread.new do
        other = described_class.new(directory: spool_dir)
        seed_entry(id: 'b' * 32)
        other.update(id: 'b' * 32) { { status: 'delivered' } }
        [other.fetch(id: record_id), other.entries.length, other.count, other.bytes]
      end
      expect(independent.join(2)).to eq(independent)
      snapshot, entries, count, bytes = independent.value
      expect(snapshot).to eq(original)
      expect([entries, count]).to eq([2, 2])
      expect(bytes).to eq(Dir.glob(File.join(recovery_dir, '*.json')).sum { |path| File.size(path) })
      release << true
      expect(updater.join(2)).to eq(updater)
      expect(store.fetch(id: record_id)[:status]).to eq('ready')
    ensure
      release << true if release
      updater&.kill&.join(1)
      independent&.kill&.join(1)
    end

    it 'serializes same-ID read-modify-write callbacks across processes' do
      seed_entry
      children = []
      first_entered = IO.pipe
      first_release = IO.pipe
      second_started = IO.pipe
      second_finished = IO.pipe
      children << Process.fork do
        described_class.new(directory: spool_dir).update(id: record_id) do |entry|
          first_entered.last.write('1')
          first_release.first.read(1)
          { repairs: entry.fetch(:repairs, 0) + 1 }
        end
        Process.exit!(0)
      end
      expect(first_entered.first.wait_readable(3)).not_to be_nil
      expect(first_entered.first.read(1)).to eq('1')
      children << Process.fork do
        second_started.last.write('1')
        described_class.new(directory: spool_dir).update(id: record_id) do |entry|
          second_finished.last.write('1')
          { repairs: entry.fetch(:repairs, 0) + 1 }
        end
        Process.exit!(0)
      end
      expect(second_started.first.wait_readable(3)).not_to be_nil
      expect(second_started.first.read(1)).to eq('1')
      expect(second_finished.first.wait_readable(0.1)).to be_nil
      first_release.last.write('1')
      expect(second_finished.first.wait_readable(3)).not_to be_nil
      expect(second_finished.first.read(1)).to eq('1')
      until children.empty?
        status = Timeout.timeout(3) { Process.wait2(children.first).last }
        children.shift
        expect(status.success?).to be true
      end
      expect(store.fetch(id: record_id)[:repairs]).to eq(2)
    ensure
      children&.each do |pid|
        Process.kill('KILL', pid)
        Process.wait(pid)
      end
      [first_entered, first_release, second_started, second_finished].compact.flatten.each(&:close)
    end
  end
end
