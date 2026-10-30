# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'legion/logging/helper'
require 'securerandom'
require 'time'
require_relative 'spool/legacy'

module Legion
  module Transport
    module Spool
      class CapacityExceededError < StandardError; end
      class LegacyRecordError < StandardError; end
      class LegacyDependencyNotReady < LegacyRecordError; end

      @mutex = Mutex.new
      @replay_mutex = Mutex.new

      class << self
        include Legion::Logging::Helper

        def setup(directory: nil, max_file_bytes: 10_485_760, max_total_bytes: 524_288_000,
                  max_files: 100, max_age_seconds: 259_200)
          @mutex.synchronize do
            @directory = directory || Legion::Settings[:transport].dig(:spool, :directory) || File.expand_path('~/.legionio/spool')
            @max_file_bytes = max_file_bytes
            @max_total_bytes = max_total_bytes
            @max_files = max_files
            @max_age_seconds = max_age_seconds
            @current_file = nil
            FileUtils.mkdir_p(@directory)
          end
          true
        end

        def write(exchange:, routing_key:, payload:, **envelope)
          raise ArgumentError, 'spool payload must be an already encoded String' unless payload.is_a?(String)

          setup unless @directory
          record = {
            spool_version:    2,
            exchange:         exchange,
            exchange_type:    envelope.delete(:exchange_type) || 'topic',
            tenant_id:        envelope.delete(:tenant_id) || 'default',
            payload:          Base64.strict_encode64(payload),
            payload_encoding: payload.encoding.name,
            envelope:         envelope.merge(routing_key: routing_key),
            spooled_at:       Time.now.iso8601
          }
          line = "#{Legion::JSON.dump(record)}\n"
          with_directory_lock do
            file = append_path(bytes: line.bytesize)
            persist_line(file: file, line: line)
            @current_file = file
          end
          true
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: 'transport.spool.write',
                           directory: @directory, exchange: exchange, routing_key: routing_key)
          raise
        end

        # A callback acknowledges a record only by returning literal true. Confirmed prefixes
        # are compacted atomically; a crash before compaction can redeliver them (at least once).
        def drain(&)
          setup unless @directory
          files = with_directory_lock { sorted_files }
          files.each do |file|
            claim = claim_file(file: file)
            return false unless claim

            return false unless drain_claim(claim: claim, &)
          end
          true
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.drain')
          false
        end

        # Recovery callbacks only schedule work; disk and broker operations run on this worker.
        def replay_async
          @replay_mutex.synchronize do
            @replay_requested = true
            return false if @replay_thread&.alive?

            @replay_stopping = false
            @replay_thread = Thread.new { replay_pending }
          end
          true
        end

        # deadline is an absolute Process::CLOCK_MONOTONIC time, shared with shutdown.
        def stop_replay(deadline:)
          worker = @replay_mutex.synchronize do
            @replay_stopping = true
            @replay_requested = false
            @replay_thread
          end
          return true unless worker&.alive?
          return false if worker == Thread.current

          remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          worker.join([remaining / 2, 0.05].min) if remaining.positive?
          worker.kill if worker.alive?
          remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          worker.join(remaining) if remaining.positive?
          !worker.alive?
        end

        def count
          setup unless @directory
          with_directory_lock do
            sorted_files.sum { |file| File.foreach(file).count { |line| !line.strip.empty? } }
          end
        end

        def evict_stale
          setup unless @directory
          with_directory_lock do
            cutoff = Time.now - @max_age_seconds
            sorted_files.each do |file|
              next if file.end_with?('.active.jsonl') || file.include?('.claim-') || File.mtime(file) >= cutoff

              File.delete(file)
              log.info "Evicted stale spool file=#{file}"
            end
            sync_directory
          end
        end

        def reset!
          stop_replay(deadline: ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 1)
          raise IOError, 'spool replay is still stopping' if @replay_thread&.alive?

          @mutex.synchronize do
            @directory = nil
            @current_file = nil
            @max_file_bytes = nil
            @max_total_bytes = nil
            @max_files = nil
            @max_age_seconds = nil
          end
        end

        attr_reader :max_file_bytes

        private

        def with_directory_lock
          @mutex.synchronize do
            File.open(File.join(@directory, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
              lock.flock(File::LOCK_EX)
              yield
            end
          end
        end

        def sorted_files
          Dir.glob(File.join(@directory, '*.jsonl'))
        end

        def sync_directory
          File.open(@directory, 'r', &:fsync)
        end

        def append_path(bytes:)
          current_size = @current_file && File.exist?(@current_file) ? File.size(@current_file) : 0
          reuse = current_size.positive? && current_size + bytes <= max_file_bytes
          unless reuse
            File.rename(@current_file, @current_file.sub(/\.active\.jsonl\z/, '.jsonl')) if current_size.positive?
            @current_file = nil
          end
          files = sorted_files
          if files.sum { |file| File.size(file) } + bytes > @max_total_bytes || (!reuse && files.size >= @max_files)
            raise CapacityExceededError, 'spool capacity exhausted; pending records were retained'
          end

          return @current_file if reuse

          File.join(@directory, "spool-#{Time.now.strftime('%Y%m%d%H%M%S%N')}-#{SecureRandom.hex(4)}.active.jsonl")
        end

        def persist_line(file:, line:)
          File.open(file, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |io|
            io.sync = true
            original_size = io.size
            begin
              raise IOError, 'incomplete spool append' unless io.write(line) == line.bytesize

              io.flush
              io.fsync
              sync_directory
            rescue StandardError
              rollback_append(io: io, size: original_size)
              raise
            end
          end
        end

        def rollback_append(io:, size:)
          io.truncate(size)
          io.flush
          File.delete(io.path) if size.zero?
          io.fsync
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.rollback_append')
        end

        def claim_file(file:)
          with_directory_lock do
            return unless File.exist?(file)

            # Ownership transfers to drain_claim, which closes the handle in ensure.
            io = File.open(file, 'rb') # rubocop:disable Style/FileOpen
            unless io.flock(File::LOCK_EX | File::LOCK_NB)
              io.close
              return
            end
            claimed = file.include?('.claim-') ? file : file.sub(/\.jsonl\z/, ".claim-#{SecureRandom.hex(8)}.jsonl")
            File.rename(file, claimed) unless claimed == file
            @current_file = nil if @current_file == file
            sync_directory
            [claimed, io]
          rescue StandardError
            io&.close
            raise
          end
        end

        def drain_claim(claim:)
          file, io = claim
          confirmed_offset = 0
          while (line = io.gets)
            next if line.strip.empty?

            record = Legion::JSON.load(line)
            unless record.key?(:spool_version)
              upgrade_claim(claim: claim, offset: confirmed_offset)
              confirmed_offset = 0
              io = claim.last
              next
            end
            raise LegacyRecordError, "unsupported spool version: #{record[:spool_version].inspect}" unless record[:spool_version] == 2

            record[:payload] = Base64.strict_decode64(record.fetch(:payload)).force_encoding(record.fetch(:payload_encoding))
            return false unless yield(record) == true

            confirmed_offset = io.pos
          end
          true
        ensure
          begin
            compact_claim(file: file, io: io, offset: confirmed_offset) if confirmed_offset.positive? && io.equal?(claim.last)
          ensure
            claim.last.close
          end
        end

        # The replacement stays locked after rename, until this drainer releases its claim.
        # Nothing is published until the complete upgraded tail and directory entry are durable.
        def upgrade_claim(claim:, offset:)
          file, original = claim
          temporary = "#{file}.#{SecureRandom.hex(4)}.tmp"
          # Ownership transfers to drain_claim on rename; this method closes failed replacements.
          replacement = File.open(temporary, File::RDWR | File::CREAT | File::EXCL, 0o600) # rubocop:disable Style/FileOpen
          replacement.flock(File::LOCK_EX)
          original.seek(offset)
          original.each_line do |line|
            next if line.strip.empty?

            record = Legion::JSON.load(line)
            unless record.key?(:spool_version)
              record = Legion::Transport::Spool::Legacy.convert(record: record)
              line = "#{Legion::JSON.dump(record)}\n"
            end
            raise IOError, 'incomplete spool upgrade write' unless replacement.write(line) == line.bytesize
          end
          replacement.flush
          replacement.fsync
          replacement.rewind
          with_directory_lock do
            Thread.handle_interrupt(Object => :never) do
              File.rename(temporary, file)
              claim[1] = replacement
            end
            sync_directory
          end
        rescue Legion::Transport::EncryptionNotReady, LegacyDependencyNotReady
          @upgrade_waiting_for_dependency = true
          raise
        ensure
          original.close unless original.equal?(claim.last)
          replacement&.close unless replacement.equal?(claim.last)
          File.delete(temporary) if temporary && File.exist?(temporary)
        end

        def compact_claim(file:, io:, offset:)
          if offset == io.size
            with_directory_lock do
              File.delete(file)
              sync_directory
            end
            return
          end

          temporary = "#{file}.#{SecureRandom.hex(4)}.tmp"
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |remaining|
            io.seek(offset)
            IO.copy_stream(io, remaining)
            remaining.flush
            remaining.fsync
            with_directory_lock do
              File.rename(temporary, file)
              sync_directory
            end
          end
        ensure
          File.delete(temporary) if temporary && File.exist?(temporary)
        end

        def replay_pending
          loop do
            ready = @replay_mutex.synchronize do
              next false if @replay_stopping

              @replay_requested = false
              true
            end
            break unless ready

            @upgrade_waiting_for_dependency = false
            completed = drain { |record| !@replay_stopping && replay_record(record: record) }
            pending = completed && !@replay_stopping && count.positive?
            again = @replay_mutex.synchronize do
              !@replay_stopping && (pending || @replay_requested || @upgrade_waiting_for_dependency)
            end
            break unless again

            sleep 1 if @upgrade_waiting_for_dependency
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.replay')
        ensure
          @replay_mutex.synchronize do
            if @replay_thread == Thread.current
              @replay_thread = nil
              if @replay_requested
                @replay_stopping = false
                @replay_thread = Thread.new { replay_pending }
              end
            end
          end
        end

        def replay_record(record:)
          envelope = record.fetch(:envelope)
          payload = record.fetch(:payload)
          channel = Legion::Transport::Connection.channel
          exchange_name = record.fetch(:exchange)
          exchange = if exchange_name.empty?
                       channel.default_exchange
                     else
                       channel.exchange(exchange_name, type: record.fetch(:exchange_type).to_sym, passive: true)
                     end
          return false if @replay_stopping

          Legion::Transport::TenantQuota.check_publish(record.fetch(:tenant_id), message_size: payload.bytesize)
          result = Legion::Transport::Publisher.publish(exchange: exchange, payload: payload, envelope: envelope,
                                                        publisher_confirm: true, mandatory: true)
          result[:accepted] == true && result[:status] == :accepted
        end
      end
    end
  end
end
