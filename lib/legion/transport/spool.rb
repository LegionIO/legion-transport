# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'legion/logging/helper'
require 'securerandom'
require 'time'
require_relative 'spool/legacy'
require_relative 'spool/recovery_store'

module Legion
  module Transport
    module Spool
      class CapacityExceededError < StandardError; end
      class LegacyRecordError < StandardError; end
      class LegacyDependencyNotReady < LegacyRecordError; end
      class UnroutableRecordError < StandardError; end

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
            @recovery_store = Legion::Transport::Spool::RecoveryStore.new(directory: @directory)
          end
          true
        end

        def write(exchange:, routing_key:, payload:, **envelope)
          raise ArgumentError, 'spool payload must be an already encoded String' unless payload.is_a?(String)

          setup unless @directory
          record = {
            spool_version:    2,
            record_id:        SecureRandom.hex(16),
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
          drain_recovery(&)
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
            sorted_files.sum { |file| File.foreach(file).count { |line| !line.strip.empty? } } +
              @recovery_store.count(status: 'ready') + @recovery_store.count(status: 'waiting')
          end
        end

        def status
          setup unless @directory
          { pending: count, quarantined: @recovery_store.count(status: 'quarantined'),
            waiting: @recovery_store.count(status: 'waiting'), delivered_recoveries: @recovery_store.count(status: 'delivered') }
        end

        def recovery_entries(status: nil, limit: 100, offset: 0)
          setup unless @directory
          @recovery_store.entries(status: status, limit: limit, offset: offset).map { |entry| recovery_summary(entry: entry) }
        end

        def recovery_record(id:)
          setup unless @directory
          @recovery_store.fetch(id: id)
        end

        def repair_record(id:, changes:)
          setup unless @directory
          validate_repair_changes(changes: changes)

          updated = @recovery_store.update(id: id) do |entry|
            raise ArgumentError, 'a delivered recovery record cannot be republished by repair' if entry[:status] == 'delivered'

            source = (entry[:wire_record] || entry[:record] || {}).dup
            if source[:spool_version] == 2 && !source[:recovery]
              source = repair_wire_record(record: source, changes: changes)
            else
              source = source.merge(changes)
              if changes[:encrypt] == false
                source[:content_encoding] = 'identity'
                source[:headers] = (source[:headers] || {}).except(:iv, 'iv')
              end
              source[:spooled_at] ||= entry[:recorded_at]
              source = Legion::Transport::Spool::Legacy.convert(record: source)
            end
            source[:record_id] = id
            entry.merge(status: 'ready', wire_record: source, repaired_at: Time.now.iso8601, error: nil, error_class: nil)
          end
          replay_async
          recovery_summary(entry: updated)
        end

        def retry_recovery(id:)
          setup unless @directory
          updated = prepare_recovery(id: id)
          replay_async if %w[ready waiting].include?(updated[:status])
          recovery_summary(entry: updated)
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
            @recovery_store = nil
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
          if files.sum { |file| File.size(file) } + @recovery_store.bytes + bytes > @max_total_bytes || (!reuse && files.size >= @max_files)
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

            record = parse_spool_record(line: line)
            if record.nil? || record[:spool_version] != 2 || !valid_record_id?(record: record)
              upgrade_claim(claim: claim, offset: confirmed_offset)
              confirmed_offset = 0
              io = claim.last
              next
            end
            if record[:recovery]
              retain_recovery(marker: record, line: line)
            else
              begin
                decoded = decoded_wire_record(record: record)
              rescue ArgumentError, KeyError, TypeError, LegacyRecordError => e
                retain_recovery(marker: recovery_marker(record: record, line: line, error: e), line: line)
                confirmed_offset = io.pos
                next
              end
              begin
                return false unless yield(decoded) == true
              rescue UnroutableRecordError => e
                retain_recovery(marker: recovery_marker(record: record, line: line, error: e), line: line)
              end
            end

            confirmed_offset = io.pos
          end
          true
        ensure
          begin
            compact_claim(file: file, io: io, offset: confirmed_offset) if confirmed_offset&.positive? && io.equal?(claim.last)
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

            line = "#{Legion::JSON.dump(upgraded_record(line: line))}\n"
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
        ensure
          original&.close unless original.equal?(claim.last)
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

        def parse_spool_record(line:)
          record = Legion::JSON.load(line)
          record if record.is_a?(Hash)
        rescue StandardError => e
          log.warn "Spool record could not be parsed (#{e.class})"
          nil
        end

        def valid_record_id?(record:)
          record[:record_id].is_a?(String) && record[:record_id].match?(/\A[0-9a-f]{32}\z/)
        end

        def upgraded_record(line:)
          record = parse_spool_record(line: line)
          original = record
          raise LegacyRecordError, 'spool record is not a valid JSON object' unless record
          return record if record[:recovery] && valid_record_id?(record: record)

          if record.key?(:spool_version)
            raise LegacyRecordError, "unsupported spool version: #{record[:spool_version].inspect}" unless record[:spool_version] == 2

            decoded_wire_record(record: record)
          else
            record = Legion::Transport::Spool::Legacy.convert(record: record)
          end
          record.merge(record_id: valid_record_id?(record: record) ? record[:record_id] : SecureRandom.hex(16))
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.upgrade_record')
          recovery_marker(record: original, line: line, error: e)
        end

        def recovery_marker(record:, line:, error:)
          waiting = error.is_a?(Legion::Transport::EncryptionNotReady) || error.is_a?(LegacyDependencyNotReady) ||
                    error.is_a?(IOError) || error.class.name.start_with?('OpenSSL::')
          id = record && valid_record_id?(record: record) ? record[:record_id] : SecureRandom.hex(16)
          { spool_version: 2, record_id: id,
            recovery: { status: waiting ? 'waiting' : 'quarantined', record: record,
                        raw_line: Base64.strict_encode64(line), error_class: error.class.name, error: error.message } }
        end

        def retain_recovery(marker:, line:)
          begin
            detail = marker.fetch(:recovery)
            unless detail.is_a?(Hash) && %w[waiting quarantined].include?(detail[:status]) &&
                   (detail[:record].nil? || detail[:record].is_a?(Hash)) &&
                   detail[:error_class].is_a?(String) && detail[:error].is_a?(String)
              raise LegacyRecordError, 'invalid spool recovery marker'
            end

            raw = Base64.strict_decode64(detail.fetch(:raw_line))
          rescue ArgumentError, KeyError, TypeError, LegacyRecordError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.recovery_marker')
            detail = recovery_marker(record: marker, line: line, error: e).fetch(:recovery)
            raw = line
          end
          @recovery_store.store(id: marker.fetch(:record_id), record: detail[:record], raw_line: raw,
                                error: detail.slice(:error_class, :error), status: detail.fetch(:status))
        end

        def recovery_summary(entry:)
          record = entry[:wire_record] || entry[:record] || {}
          envelope = record[:envelope].is_a?(Hash) ? record[:envelope] : {}
          entry.slice(:id, :status, :error_class, :error, :recorded_at, :repaired_at, :delivered_at).merge(
            exchange:    record[:exchange] || entry[:exchange],
            routing_key: envelope[:routing_key] || record[:routing_key] || entry[:routing_key],
            tenant_id:   record[:tenant_id] || entry[:tenant_id]
          )
        end

        def validate_repair_changes(changes:)
          allowed = %i[exchange routing_key tenant_id exchange_type payload headers encrypt]
          raise ArgumentError, 'repair changes must be a Hash of supported delivery fields' unless changes.is_a?(Hash) && (changes.keys - allowed).empty?
          raise ArgumentError, 'repair changes cannot be empty' if changes.empty?
          raise ArgumentError, 'encrypt must be true or false' if changes.key?(:encrypt) && ![true, false].include?(changes[:encrypt])
          raise ArgumentError, 'headers must be a Hash' if changes.key?(:headers) && !changes[:headers].is_a?(Hash)

          %i[exchange routing_key exchange_type].each do |key|
            raise ArgumentError, "#{key} must be a String" unless changes.fetch(key, '').is_a?(String)
          end
        end

        def repair_wire_record(record:, changes:)
          raise ArgumentError, 'changing tenant identity requires an explicit exchange' if changes.key?(:tenant_id) && !changes.key?(:exchange)

          record = record.merge(changes.slice(:exchange, :exchange_type, :tenant_id))
          record[:exchange] = Legion::Transport::TenantTopology.exchange_name(record[:exchange], tenant_id: record[:tenant_id] || 'default')
          envelope = record[:envelope].is_a?(Hash) ? record[:envelope].dup : {}
          envelope.merge!(changes.slice(:routing_key))
          envelope[:headers] = (envelope[:headers] || {}).merge(changes[:headers].transform_keys(&:to_sym)) if changes.key?(:headers)
          if envelope[:content_encoding] == 'encrypted/cs' && !changes.key?(:payload)
            original_iv = record.dig(:envelope, :headers, :iv)
            raise ArgumentError, 'the IV cannot change without replacing its encrypted payload' unless envelope.dig(:headers, :iv) == original_iv
          end
          if changes.key?(:payload) || changes.key?(:encrypt)
            raise ArgumentError, 'changing wire encryption requires an explicit raw payload' unless changes.key?(:payload)

            return encode_repaired_payload(record: record, envelope: envelope, changes: changes)
          end

          record = record.merge(envelope: envelope)
          decoded_wire_record(record: record)
          record
        end

        def encode_repaired_payload(record:, envelope:, changes:)
          legacy = envelope.merge(exchange: record[:exchange], exchange_type: record.fetch(:exchange_type, 'topic'),
                                  tenant_id: record.fetch(:tenant_id, 'default'), payload: changes.fetch(:payload),
                                  spooled_at: record.fetch(:spooled_at, Time.now.iso8601))
          legacy[:encrypt] = changes[:encrypt] if changes.key?(:encrypt)
          if changes[:encrypt] == false
            legacy[:content_encoding] = 'identity'
            legacy[:headers] = (legacy[:headers] || {}).except(:iv, 'iv')
          end
          Legion::Transport::Spool::Legacy.convert(record: legacy)
        end

        def prepare_recovery(id:)
          @recovery_store.update(id: id) do |entry|
            next entry if %w[ready delivered].include?(entry[:status])

            raw = if entry[:wire_record]
                    Legion::JSON.dump(entry[:wire_record])
                  else
                    Base64.strict_decode64(entry.fetch(:raw_line))
                  end
            record = upgraded_record(line: raw)
            if record[:recovery]
              detail = record[:recovery]
              entry.merge(detail.slice(:status, :error_class, :error))
            else
              entry.merge(status: 'ready', wire_record: record.merge(record_id: id), error: nil, error_class: nil)
            end
          end
        end

        def decoded_wire_record(record:)
          unless record[:exchange].is_a?(String) && record[:exchange_type].is_a?(String) &&
                 record[:tenant_id].is_a?(String) && record[:envelope].is_a?(Hash) &&
                 record[:envelope][:routing_key].is_a?(String)
            raise LegacyRecordError, 'wire record requires exchange, exchange_type, tenant_id and an envelope routing_key'
          end

          payload = Base64.strict_decode64(record.fetch(:payload)).force_encoding(record.fetch(:payload_encoding))
          record.merge(payload: payload)
        end

        def drain_recovery(&)
          offset = 0
          loop do
            entries = @recovery_store.entries(limit: 1000, offset: offset)
            entries.each do |entry|
              entry = prepare_recovery(id: entry[:id]) if entry[:status] == 'waiting'
              next unless entry[:status] == 'ready'
              return false unless deliver_recovery(id: entry[:id], &)
            end
            break if entries.size < 1000

            offset += entries.size
          end
          true
        end

        def deliver_recovery(id:)
          updated = @recovery_store.update(id: id) do |current|
            next current unless current[:status] == 'ready'

            record = current.fetch(:wire_record)
            begin
              decoded = decoded_wire_record(record: record)
            rescue ArgumentError, KeyError, TypeError, LegacyRecordError => e
              handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.recovery_decode')
              next current.merge(status: 'quarantined', error_class: e.class.name, error: e.message)
            end
            if yield(decoded) == true
              current.merge(status: 'delivered', delivered_at: Time.now.iso8601,
                            exchange: record[:exchange], routing_key: record.dig(:envelope, :routing_key), tenant_id: record[:tenant_id],
                            record: nil, raw_line: nil, wire_record: nil)
            else
              current
            end
          rescue UnroutableRecordError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.spool.recovery_publish')
            current.merge(status: 'quarantined', error_class: e.class.name, error: e.message)
          end
          updated[:status] != 'ready'
        end

        def replay_pending
          loop do
            ready = @replay_mutex.synchronize do
              next false if @replay_stopping

              @replay_requested = false
              true
            end
            break unless ready

            completed = drain { |record| !@replay_stopping && replay_record(record: record) }
            waiting = @recovery_store.count(status: 'waiting').positive?
            pending = completed && !@replay_stopping && count.positive?
            again = @replay_mutex.synchronize do
              !@replay_stopping && (pending || @replay_requested || waiting)
            end
            break unless again

            sleep 1 if waiting
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
          if result[:status] == :unroutable || %w[Bunny::NotFound Bunny::PreconditionFailed].include?(result[:error_class])
            raise UnroutableRecordError, "broker rejected destination: #{result[:error] || result[:return_reply_text] || result[:status]}"
          end

          result[:accepted] == true && result[:status] == :accepted
        rescue StandardError => e
          raise unless defined?(::Bunny::NotFound) && (e.is_a?(::Bunny::NotFound) || e.is_a?(::Bunny::PreconditionFailed))

          raise UnroutableRecordError, "Exchange #{record[:exchange]} is unavailable or incompatible (#{e.class})"
        end
      end
    end
  end
end
