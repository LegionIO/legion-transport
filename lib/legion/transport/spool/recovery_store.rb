# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'legion/json'
require 'legion/logging/helper'
require 'securerandom'
require 'time'

module Legion
  module Transport
    module Spool
      class RecoveryStore
        include Legion::Logging::Helper

        ID_PATTERN = /\A[0-9a-f]{32}\z/

        def initialize(directory:, **)
          @directory = File.join(File.expand_path(directory), 'recovery')
          FileUtils.mkdir_p(@directory, mode: 0o700)
          File.open(File.dirname(@directory), File::RDONLY, &:fsync)
        rescue StandardError, Interrupt => e
          log.error("Transport recovery initialization failed (#{e.class})")
          raise
        end

        def store(id:, record:, raw_line:, error:, status: 'quarantined', **)
          with_record_lock(id: id) do |path|
            # An old journal marker must never resurrect a repaired or delivered entry.
            next read_entry(id: id) if File.exist?(path)

            error_info = if error.is_a?(::Exception)
                           { error_class: error.class.name, error: error.message }
                         else
                           { error_class: error.fetch(:error_class), error: error.fetch(:error) }
                         end
            entry = error_info.merge(id: id, status: normalize_status(status: status), record: record,
                                     # raw_line is always strict Base64, including in fetch/entries results.
                                     raw_line: Base64.strict_encode64(raw_line), recorded_at: Time.now.utc.iso8601(6))
            persist_entry(path: path, entry: entry)
          end
        end

        def fetch(id:, **)
          validate_id(id: id)
          read_entry(id: id)
        end

        def entries(status: nil, limit: 100, offset: 0, **)
          raise ArgumentError, 'limit must be a positive Integer' unless limit.is_a?(Integer) && limit.positive?
          raise ArgumentError, 'offset must be a nonnegative Integer' unless offset.is_a?(Integer) && offset >= 0

          selected_status = normalize_status(status: status) unless status.nil?
          records = entry_paths.lazy.map { |path| read_entry(id: File.basename(path, '.json')) }
          records = records.select { |entry| entry[:status] == selected_status } if selected_status
          records.drop(offset).take(limit).to_a
        end

        def count(status: nil, **)
          paths = entry_paths
          return paths.length if status.nil?

          selected_status = normalize_status(status: status)
          paths.count { |path| read_entry(id: File.basename(path, '.json'))[:status] == selected_status }
        end

        # Only complete entry files contribute; stable locks and in-flight replacements do not.
        def bytes
          entry_paths.sum { |path| File.size(path) }
        rescue StandardError, Interrupt => e
          log.error("Transport recovery size lookup failed (#{e.class})")
          raise
        end

        def update(id:, **)
          with_record_lock(id: id) do |path|
            entry = read_entry(id: id)
            updated = yield(entry.dup)
            raise ArgumentError, 'recovery update must return a Hash with Symbol keys' unless updated.is_a?(Hash) && updated.keys.all?(Symbol)
            raise ArgumentError, 'recovery entry id is immutable' if updated.key?(:id) && updated[:id] != id

            updated = entry.merge(updated)
            updated[:status] = normalize_status(status: updated[:status])
            persist_entry(path: path, entry: updated)
          end
        end

        private

        def validate_id(id:, **)
          raise ArgumentError, 'recovery id must be 32 lowercase hexadecimal characters' unless id.is_a?(String) && ID_PATTERN.match?(id)
        end

        def normalize_status(status:, **)
          unless (status.is_a?(String) || status.is_a?(Symbol)) && !status.to_s.empty?
            raise ArgumentError, 'recovery status must be a nonempty String or Symbol'
          end

          status.to_s
        end

        def entry_paths
          Dir.glob(File.join(@directory, '*.json')).select { |path| ID_PATTERN.match?(File.basename(path, '.json')) }
        rescue StandardError, Interrupt => e
          log.error("Transport recovery listing failed (#{e.class})")
          raise
        end

        def read_entry(id:, **)
          entry = Legion::JSON.load(File.binread(File.join(@directory, "#{id}.json")))
          raise IOError, 'invalid persisted recovery entry' unless entry.is_a?(Hash) && entry[:id] == id

          entry
        rescue Errno::ENOENT
          raise KeyError, "Recovery entry #{id} does not exist"
        rescue StandardError, Interrupt => e
          # Parser errors can contain the original payload; never log exception messages here.
          log.error("Transport recovery read failed (#{e.class})")
          raise
        end

        def with_record_lock(id:, **)
          validate_id(id: id)
          # This inode is never renamed or removed: all processes retain the same ownership boundary.
          File.open(File.join(@directory, "#{id}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
            raise IOError, 'could not lock recovery entry' unless lock.flock(File::LOCK_EX)

            yield File.join(@directory, "#{id}.json")
          end
        rescue StandardError, Interrupt => e
          log.error("Transport recovery mutation failed (#{e.class})")
          raise
        end

        def persist_entry(path:, entry:, **)
          temporary = "#{path}.#{SecureRandom.hex(16)}.tmp"
          previous = "#{temporary}.previous"
          backed_up = installed = committed = false
          serialized = Legion::JSON.dump(entry)
          replacement = nil
          Thread.handle_interrupt(Object => :never) do
            replacement = File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) # rubocop:disable Style/FileOpen
          end
          raise IOError, 'incomplete recovery entry write' unless replacement.write(serialized) == serialized.bytesize

          replacement.flush
          replacement.fsync
          replacement.close
          Thread.handle_interrupt(Object => :never) do
            if File.exist?(path)
              File.link(path, previous)
              backed_up = true
            end
            File.rename(temporary, path)
            installed = true
            File.open(@directory, File::RDONLY, &:fsync)
            committed = true
          end
          entry
        ensure
          Thread.handle_interrupt(Object => :never) do
            if installed && !committed
              # Keep the old inode available until the replacement's directory entry is durable.
              backed_up ? File.rename(previous, path) : File.delete(path)
              installed = false
              File.open(@directory, File::RDONLY, &:fsync)
            end
          ensure
            begin
              replacement&.close unless replacement&.closed?
            ensure
              File.delete(temporary) if replacement && File.exist?(temporary)
              File.delete(previous) if backed_up && (!installed || committed) && File.exist?(previous)
            end
          end
        end
      end
    end
  end
end
