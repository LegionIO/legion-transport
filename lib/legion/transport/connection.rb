# frozen_string_literal: true

require 'concurrent-ruby'
require 'legion/logging/helper'
require 'timeout'
require_relative 'connection/ssl'
require_relative 'connection/vault'
require_relative 'connection/recovery'

module Legion
  module Transport
    module Connection
      RECOVERY_WINDOW = 60
      MAX_RECOVERIES_PER_WINDOW = 5
      MAX_PUBLISHER_CHANNELS = 128
      SHUTDOWN_TIMEOUT = 5

      class << self
        include Legion::Logging::Helper
        include Legion::Transport::Connection::SSL
        include Legion::Transport::Connection::Vault

        def lite_mode?
          Legion::Transport::TYPE == 'local'
        end

        def settings
          Legion::Settings[:transport]
        end

        def new
          clone
        end

        def connector
          Legion::Transport::CONNECTOR
        end

        def reconnect(connection_name: 'Legion', **)
          @session = nil
          @channel_thread = Concurrent::ThreadLocalVar.new(nil)
          @channel_registry = Concurrent::Hash.new
          setup(connection_name: connection_name)
        end

        def setup(connection_name: 'Legion', generation: nil, **)
          generation = reconnect_mutex.synchronize do
            raise IOError, 'transport is shutting down' if @shutting_down

            generation ||= @generation ||= 0
            check_generation!(generation: generation)
            generation
          end
          log.info("Using transport connector: #{Legion::Transport::CONNECTOR}")
          return setup_lite(generation: generation) if lite_mode?

          pool_size = settings[:connection_pool_size].to_i
          if pool_size > 1
            setup_pool(pool_size: pool_size, connection_name: connection_name, generation: generation)
          elsif session.respond_to?(:open?) && session.open?
            @channel_thread ||= Concurrent::ThreadLocalVar.new(nil)
          else
            rebuild_single_session(connection_name: connection_name, generation: generation)
          end

          register_session_callbacks
          reset_log_channel
          apply_quorum_policy_if_enabled
          true
        end

        def channel
          generation, channel_thread, pool, current_session = publisher_channel_context
          return build_channel if Thread.current[:legion_build_session] && @build_session
          return channel_thread.value if channel_thread.value&.open?

          sweep_dead_thread_channels
          if pool
            current_session = pool.checkout
            checked_out = true
          end
          raise IOError, 'transport session unavailable (recovery in progress)' unless current_session&.open?

          ch = current_session.create_channel(nil, settings[:channel][:default_worker_pool_size], false, 10)
          ch.prefetch(settings[:prefetch])
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            channel_thread.value = ch
            track_channel(Thread.current, ch)
          end
          if channel_registry_size >= MAX_PUBLISHER_CHANNELS
            log.warn "Channel registry at capacity (size=#{channel_registry_size}, max=#{MAX_PUBLISHER_CHANNELS})"
          end
          ch
        rescue StandardError
          safe_close_channel(ch)
          raise
        ensure
          pool.checkin(current_session) if checked_out
        end

        def session
          return nil if @session.nil?

          @session.value
        end

        def channel_thread
          channel
        end

        def channel_open?
          current_channel = @channel_thread&.value
          return false unless current_channel

          current_channel.open?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.channel_open?')
          false
        end

        def session_open?
          current_session = session
          return false unless current_session

          current_session.open?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.session_open?')
          false
        end

        def shutdown
          acquired = reconnect_mutex.synchronize do
            next false if @shutting_down

            @shutting_down = true
          end
          return unless acquired

          log.info 'Transport connection shutting down'
          disconnect_sessions(deadline: monotonic_now + SHUTDOWN_TIMEOUT)
          @pending_recovery = @pending_publishers = nil
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.shutdown')
        ensure
          reconnect_mutex.synchronize { @shutting_down = false } if acquired
        end

        def force_reconnect(connection_name: 'Legion')
          acquired = begin_reconnect
          return unless acquired

          log.warn('Force reconnecting: pathological recovery loop detected')
          @pending_recovery ||= Legion::Transport::Connection::Recovery.capture(sessions: owned_sessions, excluded_channels: [@log_channel])
          @pending_publishers ||= { cache:    @channel_thread || Concurrent::ThreadLocalVar.new(nil),
                                    registry: @channel_registry || Concurrent::Hash.new }
          generation = disconnect_sessions(deadline: monotonic_now + SHUTDOWN_TIMEOUT)
          @recovery_timestamps = []
          setup(connection_name: connection_name, generation: generation)
          @pending_recovery.restore(session: session)
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            @channel_thread = @pending_publishers.fetch(:cache)
            @channel_registry = @pending_publishers.fetch(:registry)
            @channel_registry.delete_if { |_thread, ch| !ch.open? }
            @pending_recovery = @pending_publishers = nil
          end

          Array(@reconnect_callbacks).each do |cb|
            cb.call
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.reconnect_callback')
          end
          true
        rescue StandardError => e
          disconnect_sessions(deadline: monotonic_now + SHUTDOWN_TIMEOUT) if acquired
          handle_exception(e, level: :error, handled: true, operation: 'transport.connection.force_reconnect')
          false
        ensure
          clear_reconnect_state if acquired
        end

        def on_force_reconnect(&block)
          @reconnect_callbacks ||= []
          @reconnect_callbacks << block
        end

        def open_build_session(connection_name: 'Legion::Build')
          return if lite_mode? || @build_session

          generation = @generation ||= 0
          build_session = create_session_with_failover(connection_name: connection_name)
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            raise IOError, 'build session already opened' if @build_session

            @build_session = Concurrent::AtomicReference.new(build_session)
            @build_channel_thread = Concurrent::ThreadLocalVar.new(nil)
          end
          log.info 'Build session opened'
        rescue StandardError
          tear_down_session(build_session) if build_session
          raise
        end

        def build_channel
          build_session = @build_session&.value
          return channel unless build_session

          generation = @generation ||= 0
          channel_thread = @build_channel_thread
          return channel_thread.value if channel_thread.value&.open?

          ch = build_session.create_channel(nil, settings[:channel][:default_worker_pool_size], false, 10)
          ch.prefetch(settings[:prefetch])
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            raise IOError, 'build session closed during channel creation' unless @build_session&.value.equal?(build_session)

            channel_thread.value = ch
          end
          ch
        rescue StandardError
          safe_close_channel(ch) if ch
          raise
        end

        def close_build_session
          build_session = reconnect_mutex.synchronize do
            current = @build_session&.value
            @build_session = nil
            @build_channel_thread = nil
            current
          end
          tear_down_session(build_session) if build_session
        end

        def build_session_open?
          @build_session&.value&.open? == true
        end

        def log_channel
          return nil if lite_mode?
          return @log_channel if @log_channel&.open?

          reset_log_channel if session&.open?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.log_channel')
          nil
        end

        def create_dedicated_session(name: 'legion-dedicated')
          if lite_mode?
            # In-process transport is process-global; return the shared session so
            # that callers do not inadvertently reset all queues via Session#close.
            # Use an AtomicReference + compare_and_set so concurrent callers cannot
            # each create a separate InProcess::Session (whose #close calls Local.reset!).
            ref = (@session ||= Concurrent::AtomicReference.new(nil))

            loop do
              shared = ref.value
              return shared if shared&.open?

              s = Legion::Transport::InProcess::Session.new
              s.start
              # Install this session only if no other thread has won the race.
              return s if ref.compare_and_set(shared, s)
              # Another thread installed a session first; discard this one and retry.
            end
          end

          create_session_with_failover(connection_name: name)
        end

        def channel_registry_size
          (@channel_registry ||= Concurrent::Hash.new).size
        end

        private

        def publisher_channel_context
          reconnect_mutex.synchronize do
            raise IOError, 'transport session unavailable (recovery in progress)' if @shutting_down ||
                                                                                     (@reconnecting && @reconnect_thread != Thread.current)

            @channel_thread ||= Concurrent::ThreadLocalVar.new(nil)
            [@generation ||= 0, @channel_thread, @pool, session]
          end
        end

        def track_channel(thread, channel)
          @channel_registry ||= Concurrent::Hash.new
          @channel_registry[thread] = channel
        end

        def sweep_dead_thread_channels
          @channel_registry ||= Concurrent::Hash.new
          return if @channel_registry.empty?

          swept = 0
          deadline = monotonic_now + SHUTDOWN_TIMEOUT
          @channel_registry.keys.each do |thread| # rubocop:disable Style/HashEachMethods
            next if thread&.alive?

            channel = @channel_registry.delete(thread)
            next unless channel
            next unless channel.open?
            next if channel_has_consumers?(channel)

            safe_close_channel(channel, deadline: deadline)
            swept += 1
          rescue StandardError => e
            @channel_registry.delete(thread)
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.sweep_channel')
          end

          log.info "Swept #{swept} orphaned channel(s) from dead threads (remaining=#{@channel_registry.size})" if swept.positive?
        end

        def channel_has_consumers?(channel)
          return false unless channel.respond_to?(:consumers)

          !channel.consumers.empty?
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'transport.connection.channel_has_consumers?')
          false
        end

        def owned_sessions
          pool_sessions = @pool ? @pool.sessions : []
          channel_sessions = (@channel_registry || {}).values.filter_map do |ch|
            ch.connection if ch.respond_to?(:connection)
          end
          log_session = @log_channel.connection if @log_channel.respond_to?(:connection)
          [session, @build_session&.value, log_session, *pool_sessions, *channel_sessions].compact.uniq
        end

        def disconnect_sessions(deadline:)
          pool, sessions, generation = reconnect_mutex.synchronize do
            current_pool = @pool
            pooled_sessions = current_pool ? current_pool.sessions : []
            remaining_sessions = owned_sessions - pooled_sessions
            @generation = (@generation || 0) + 1
            @pool = @session = @build_session = @log_channel = nil
            @configured_pool_size = @build_channel_thread = nil
            @channel_thread = Concurrent::ThreadLocalVar.new(nil)
            @channel_registry = Concurrent::Hash.new
            Legion::Settings[:transport][:connected] = false
            [current_pool, remaining_sessions, @generation]
          end
          pool&.shutdown { |sess| tear_down_session(sess, deadline: deadline) }
          sessions.each { |sess| tear_down_session(sess, deadline: deadline) }
          generation
        end

        def apply_qos_and_close(qos_channel)
          qos_channel.basic_qos(settings[:prefetch], true)
        ensure
          safe_close_channel(qos_channel)
        end

        def safe_close_channel(chan, deadline: monotonic_now + SHUTDOWN_TIMEOUT)
          return unless chan&.open?

          with_shutdown_deadline(deadline: deadline) { chan.close }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.safe_close_channel')
        end

        def reset_log_channel
          current_session = session
          raise IOError, 'transport session unavailable' unless current_session

          safe_close_channel(@log_channel)
          ch = current_session.create_channel
          ch.prefetch(1)
          reconnect_mutex.synchronize do
            raise IOError, 'transport session changed during log channel creation' if @shutting_down || !session.equal?(current_session)

            @log_channel = ch
          end
        rescue StandardError
          safe_close_channel(ch) if ch
          raise
        end

        def setup_pool(pool_size:, connection_name:, generation:)
          return true if reusable_pool?(pool_size)

          tear_down_session(session) if session && @pool.nil?
          reset_pool
          pool = Legion::Transport::Helpers::Pool.new(size: pool_size) do
            create_session_with_failover(connection_name: connection_name)
          end
          primary = pool.checkout
          qos_channel = primary.create_channel(nil, settings[:channel][:session_worker_pool_size])
          apply_qos_and_close(qos_channel)
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            @pool = pool
            @session = Concurrent::AtomicReference.new(primary)
            @channel_thread = Concurrent::ThreadLocalVar.new(nil)
            @configured_pool_size = pool_size
            Legion::Settings[:transport][:connected] = true
          end
          installed = true
          log.info "Connected via pool (size=#{pool_size})"
        ensure
          pool&.checkin(primary) if primary
          unless installed
            deadline = monotonic_now + SHUTDOWN_TIMEOUT
            pool&.shutdown { |sess| tear_down_session(sess, deadline: deadline) }
          end
        end

        def setup_lite(generation:)
          require_relative 'local'
          Legion::Transport::Local.setup
          current_session = session || Legion::Transport::InProcess::Session.new
          current_session.start unless current_session.open?
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            @session = Concurrent::AtomicReference.new(current_session)
            @channel_thread = Concurrent::ThreadLocalVar.new(nil)
            Legion::Settings[:transport][:connected] = true
          end
          log.info 'Connected via in-process transport (lite mode)'
          true
        end

        def create_session_with_failover(connection_name:)
          opts = build_bunny_opts(connection_name: connection_name)
          hosts = opts[:hosts] || [{ host: opts[:host] || '127.0.0.1', port: opts[:port] || 5672 }]
          last_error = nil

          hosts.each do |host_entry|
            host = host_entry.is_a?(Hash) ? host_entry : parse_host_entry(host_entry, default_port: opts[:port] || 5672)
            attempt_opts = opts.except(:hosts).merge(host)
            candidate = nil
            started = false
            begin
              candidate = connector.new(attempt_opts)
              candidate.start
              started = true
              return candidate
            rescue Bunny::TCPConnectionFailed, Bunny::PossibleAuthenticationFailureError,
                   Bunny::NetworkFailure, Bunny::ConnectionLevelException, SystemCallError, IOError, Timeout::Error => e
              last_error = e
              handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.create_session',
                               host: "#{host[:host]}:#{host[:port]}")
            ensure
              tear_down_session(candidate) if candidate && !started
            end
          end

          raise Legion::Transport::ClusterUnavailable, "All cluster nodes exhausted: #{last_error&.message}"
        end

        def register_session_callbacks
          @recovery_timestamps ||= []

          session.on_blocked { log.warn('Legion::Transport is being blocked by RabbitMQ!') } if session.respond_to?(:on_blocked)

          if session.respond_to?(:on_unblocked)
            session.on_unblocked do
              log.info('Legion::Transport is no longer being blocked by RabbitMQ')
            end
          end

          if session.respond_to?(:after_recovery_attempts_exhausted)
            session.after_recovery_attempts_exhausted do
              log.error('Recovery attempts exhausted, forcing full reconnect')
              Thread.new { force_reconnect }
            end
          end

          return unless session.respond_to?(:after_recovery_completed)

          session.after_recovery_completed do
            log.info('Legion::Transport has completed recovery')

            @recovery_timestamps << Time.now
            @recovery_timestamps.reject! { |t| t < Time.now - RECOVERY_WINDOW }

            if @recovery_timestamps.size >= MAX_RECOVERIES_PER_WINDOW
              log.warn(
                "#{@recovery_timestamps.size} recoveries in #{RECOVERY_WINDOW}s, forcing full reconnect"
              )
              Thread.new { force_reconnect }
            end
          end
        end

        def tear_down_session(sess, deadline: monotonic_now + SHUTDOWN_TIMEOUT)
          channels = (sess.instance_variable_get(:@channels) || {}).values
          threads = channels.flat_map { |ch| ch.respond_to?(:work_pool) ? Array(ch.work_pool&.threads) : [] }
          threads << sess.instance_variable_get(:@reader_loop)&.instance_variable_get(:@thread)
          threads << sess.instance_variable_get(:@heartbeat_sender)&.instance_variable_get(:@thread)
          mark_session_closing(sess)
          with_shutdown_deadline(deadline: deadline) do
            close_session_transport(sess)
            stop_session_threads(threads: threads, deadline: deadline)
            sess.close
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.tear_down_session')
        ensure
          close_session_transport(sess)
          Array(channels).each { |ch| ch.instance_variable_set(:@status, :closed) }
          stop_session_threads(threads: threads, deadline: deadline)
        end

        def stop_session_threads(threads:, deadline:)
          Array(threads).compact.uniq.each do |thread|
            next if thread == Thread.current

            thread.kill
            thread.join([deadline - monotonic_now, 0].max)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.stop_session_thread')
          end
        end

        def with_shutdown_deadline(deadline:, &)
          remaining = deadline - monotonic_now
          raise Timeout::Error, 'transport shutdown deadline exceeded' unless remaining.positive?

          Timeout.timeout(remaining, &)
        end

        def monotonic_now
          ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end

        def check_generation!(generation:)
          return if !@shutting_down && (@generation || 0) == generation

          raise IOError, 'transport lifecycle changed during connection creation'
        end

        def apply_quorum_policy_if_enabled
          return unless defined?(Legion::Transport::Helpers::Policy)

          Legion::Transport::Helpers::Policy.apply_quorum_policy!
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.apply_quorum_policy')
          nil
        end

        def build_bunny_opts(connection_name:)
          conn_settings = Legion::Settings[:transport][:connection].dup
          resolved = conn_settings.delete(:resolved_hosts) || []
          default_port = conn_settings[:port] || 5672

          cluster_nodes = Array(Legion::Settings[:transport][:cluster_nodes])
          all_hosts = (resolved + cluster_nodes).uniq
          all_hosts.shuffle! if all_hosts.length > 1

          opts = conn_settings.merge(
            connection_name: connection_name,
            logger:          Legion::Transport.logger,
            log_level:       Legion::Transport.send(:bunny_log_level_value)
          )

          if all_hosts.length > 1
            opts[:hosts] = all_hosts.map { |h| parse_host_entry(h, default_port: default_port) }
            opts.delete(:host)
            opts.delete(:port)
          end

          opts.merge!(tls_options)
          vault_opts = vault_pki_tls_options
          opts.merge!(vault_opts) unless vault_opts.empty?
          opts
        end

        def mark_session_closing(sess)
          # Teardown must not wait for a status mutex held by a stalled recovery.
          sess.instance_variable_set(:@automatically_recover, false)
          sess.instance_variable_set(:@status, :closing)
          sess.instance_variable_set(:@manually_closed, true)
          sess.instance_variable_set(:@recovering_from_network_failure, false)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.mark_session_closing')
        end

        def close_session_transport(sess)
          sess.instance_variable_get(:@transport)&.close
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.close_transport')
        end

        def safely_close_log_channel
          safe_close_channel(@log_channel)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.close_log_channel')
        end

        def rebuild_single_session(connection_name:, generation:)
          reset_pool if @pool
          safely_close_log_channel
          @log_channel = nil
          tear_down_session(session) if session
          current_session = create_session_with_failover(connection_name: connection_name)
          qos_channel = current_session.create_channel(nil, settings[:channel][:session_worker_pool_size])
          apply_qos_and_close(qos_channel)
          reconnect_mutex.synchronize do
            check_generation!(generation: generation)
            @session = Concurrent::AtomicReference.new(current_session)
            @channel_thread = Concurrent::ThreadLocalVar.new(nil)
            @channel_registry = Concurrent::Hash.new
            Legion::Settings[:transport][:connected] = true
          end
          installed = true
          log.info "Connected to RabbitMQ (connection=#{connection_name})"
        ensure
          tear_down_session(current_session) if current_session && !installed
        end

        def reusable_pool?(pool_size)
          @pool && @configured_pool_size == pool_size && @pool.connected? && session_open?
        end

        def reset_pool
          deadline = monotonic_now + SHUTDOWN_TIMEOUT
          @pool&.shutdown { |sess| tear_down_session(sess, deadline: deadline) }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.reset_pool')
        ensure
          @pool = nil
          @configured_pool_size = nil
        end

        def parse_host_entry(host_entry, default_port:)
          entry = host_entry.to_s
          match = entry.match(/\A(?<host>[^:]+):(?<port>\d+)\z/)
          return { host: match[:host], port: match[:port].to_i } if match

          { host: entry, port: default_port }
        end

        def reconnect_mutex
          @reconnect_mutex ||= Mutex.new
        end

        def begin_reconnect
          reconnect_mutex.synchronize do
            return false if @reconnecting || @shutting_down

            @reconnecting = true
            @reconnect_thread = Thread.current
            true
          end
        end

        def clear_reconnect_state
          reconnect_mutex.synchronize do
            @reconnecting = false
            @reconnect_thread = nil
          end
        end
      end
    end
  end
end
