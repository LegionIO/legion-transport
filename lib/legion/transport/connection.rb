# frozen_string_literal: true

require 'concurrent-ruby'
require 'legion/logging/helper'
require 'timeout'
require_relative 'connection/ssl'
require_relative 'connection/vault'

module Legion
  module Transport
    module Connection
      RECOVERY_WINDOW = 60
      MAX_RECOVERIES_PER_WINDOW = 5
      MAX_PUBLISHER_CHANNELS = 128

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

        def setup(connection_name: 'Legion', **)
          log.info("Using transport connector: #{Legion::Transport::CONNECTOR}")
          return setup_lite if lite_mode?

          pool_size = settings[:connection_pool_size].to_i
          if pool_size > 1
            setup_pool(pool_size: pool_size, connection_name: connection_name)
          elsif session.respond_to?(:open?) && session.open?
            @channel_thread ||= Concurrent::ThreadLocalVar.new(nil)
          else
            rebuild_single_session(connection_name: connection_name)
          end

          register_session_callbacks
          reset_log_channel
          apply_quorum_policy_if_enabled
          true
        end

        def channel
          # Build threads route to build session
          return build_channel if Thread.current[:legion_build_session] && @build_session

          if @pool
            sess = @pool.checkout
            begin
              start_session(sess)
              ch = sess.create_channel(nil, settings[:channel][:default_worker_pool_size], false, 10)
              ch.prefetch(settings[:prefetch])
              return ch
            rescue StandardError => e
              safe_close_channel(ch)
              handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.channel', pooled: true)
              raise
            ensure
              @pool.checkin(sess) if sess
            end
          end

          return @channel_thread.value if !@channel_thread.value.nil? && @channel_thread.value.open?

          s = session
          raise IOError, 'transport session unavailable (recovery in progress)' unless s&.open?

          sweep_dead_thread_channels

          current_size = channel_registry_size
          if current_size >= MAX_PUBLISHER_CHANNELS
            log.warn "Channel registry at capacity (size=#{current_size}, max=#{MAX_PUBLISHER_CHANNELS}); " \
                     'RabbitMQ channel_max exhaustion risk — investigate thread lifecycle'
          end

          @channel_thread.value = s.create_channel(nil, settings[:channel][:default_worker_pool_size], false, 10)
          @channel_thread.value.prefetch(settings[:prefetch])
          track_channel(Thread.current, @channel_thread.value)
          log.debug "Channel created for thread #{Thread.current.object_id} (tracked=#{channel_registry_size})"
          @channel_thread.value
        end

        def session
          return nil if @session.nil?

          @session.value
        end

        def channel_thread
          channel
        end

        def channel_open?
          # In pool mode, channels are not cached in @channel_thread; check the primary session instead.
          return session_open? if @pool

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
          log.info 'Transport connection shutting down'
          @shutting_down = true
          pre_mark_sessions_closing
          close_build_session
          close_all_tracked_channels

          if @pool
            @pool.shutdown
            @pool = nil
          end

          return unless @session

          if lite_mode?
            session&.close
            @session = nil
            return
          end

          s = session
          return unless s

          tear_down_session(s)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.shutdown')
        ensure
          @log_channel = nil
          @session = nil
          @channel_registry = Concurrent::Hash.new
          @shutting_down = false
        end

        def force_reconnect(connection_name: 'Legion')
          return if @shutting_down
          return unless begin_reconnect

          log.warn('Force reconnecting: pathological recovery loop detected')
          old = session
          pool_mode = !@pool.nil?
          reset_pool if pool_mode
          @session = nil
          @channel_thread = Concurrent::ThreadLocalVar.new(nil)
          @channel_registry = Concurrent::Hash.new
          @recovery_timestamps = []

          tear_down_session(old) if old && !pool_mode
          setup(connection_name: connection_name)

          Array(@reconnect_callbacks).each do |cb|
            cb.call
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.reconnect_callback')
          end
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: 'transport.connection.force_reconnect')
        ensure
          clear_reconnect_state
        end

        def on_force_reconnect(&block)
          @reconnect_callbacks ||= []
          @reconnect_callbacks << block
        end

        def open_build_session(connection_name: 'Legion::Build')
          return if lite_mode?
          return if @build_session

          @build_session = Concurrent::AtomicReference.new(
            create_session_with_failover(connection_name: connection_name)
          )
          @build_session.value.start
          @build_channel_thread = Concurrent::ThreadLocalVar.new(nil)
          log.info 'Build session opened'
        end

        def build_channel
          return channel unless @build_session
          return @build_channel_thread.value if @build_channel_thread.value&.open?

          @build_channel_thread.value = @build_session.value.create_channel(
            nil, settings[:channel][:default_worker_pool_size], false, 10
          )
          @build_channel_thread.value.prefetch(settings[:prefetch])
          @build_channel_thread.value
        end

        def close_build_session
          return unless @build_session

          s = @build_session.value
          Timeout.timeout(10) { s.close } if s&.open?
          @build_session = nil
          @build_channel_thread = nil
          log.info 'Build session closed (all build channels released)'
        rescue Timeout::Error => e
          handle_exception(e, level: :warn, handled: true,
                           operation: 'transport.connection.close_build_session')
          bs = @build_session&.value
          safely_close_build_transport(bs)
          @build_session = nil
          @build_channel_thread = nil
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.close_build_session')
          @build_session = nil
          @build_channel_thread = nil
        end

        def build_session_open?
          @build_session&.value&.open? == true
        end

        def log_channel
          return nil if lite_mode?
          return @log_channel if @log_channel&.open?

          if session&.open?
            safely_close_log_channel
            @log_channel = session.create_channel
            @log_channel.prefetch(1)
            @log_channel
          end
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

          sess = create_session_with_failover(connection_name: name)
          sess.start
          sess
        end

        def channel_registry_size
          (@channel_registry ||= Concurrent::Hash.new).size
        end

        private

        def track_channel(thread, channel)
          @channel_registry ||= Concurrent::Hash.new
          @channel_registry[thread] = channel
        end

        def close_all_tracked_channels
          @channel_registry ||= Concurrent::Hash.new
          return if @channel_registry.empty?

          @channel_registry.keys.each do |thread| # rubocop:disable Style/HashEachMethods
            channel = @channel_registry.delete(thread)
            channel&.close if channel&.open?
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.close_tracked_channel')
          end
        end

        def sweep_dead_thread_channels
          @channel_registry ||= Concurrent::Hash.new
          return if @channel_registry.empty?

          swept = 0
          @channel_registry.keys.each do |thread| # rubocop:disable Style/HashEachMethods
            next if thread&.alive?

            channel = @channel_registry.delete(thread)
            next unless channel

            if channel.open?
              channel.close
              swept += 1
            end
          rescue StandardError => e
            @channel_registry.delete(thread)
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.sweep_channel')
          end

          log.info "Swept #{swept} orphaned channel(s) from dead threads (remaining=#{@channel_registry.size})" if swept.positive?
        end

        def pre_mark_sessions_closing
          candidates = [
            session,
            @log_channel.respond_to?(:connection) ? @log_channel.connection : nil,
            @build_session&.value
          ].compact.uniq

          candidates.each do |sess|
            mark_session_closing(sess) if sess.respond_to?(:instance_variable_set)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.pre_mark_sessions_closing')
          end
        end

        def apply_qos_and_close(qos_channel)
          qos_channel.basic_qos(settings[:prefetch], true)
        ensure
          safe_close_channel(qos_channel)
        end

        def safe_close_channel(chan)
          chan&.close if chan&.open?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.safe_close_channel')
        end

        def reset_log_channel
          @log_channel&.close if @log_channel&.open?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.reset_log_channel')
        ensure
          @log_channel = session.create_channel
          @log_channel.prefetch(1)
        end

        def setup_pool(pool_size:, connection_name:)
          return true if reusable_pool?(pool_size)

          tear_down_session(session) if session.respond_to?(:open?) && session.open? && @pool.nil?
          reset_pool
          require 'legion/transport/helpers/pool'
          @pool = Legion::Transport::Helpers::Pool.new(size: pool_size) do
            build_started_session(connection_name: connection_name)
          end
          primary = @pool.checkout
          start_session(primary)
          qos_channel = primary.create_channel(nil, settings[:channel][:session_worker_pool_size])
          apply_qos_and_close(qos_channel)
          @session = Concurrent::AtomicReference.new(primary)
          @channel_thread = Concurrent::ThreadLocalVar.new(nil)
          @configured_pool_size = pool_size
          Legion::Settings[:transport][:connected] = true
          log.info "Connected via pool (size=#{pool_size})"
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: 'transport.connection.setup_pool', pool_size: pool_size)
          @pool = nil
          raise e
        ensure
          @pool.checkin(primary) if defined?(primary) && primary && @pool
        end

        def setup_lite
          require_relative 'local'
          Legion::Transport::Local.setup
          @session ||= Concurrent::AtomicReference.new(Legion::Transport::InProcess::Session.new)
          session.start unless session.open?
          @channel_thread = Concurrent::ThreadLocalVar.new(nil)
          Legion::Settings[:transport][:connected] = true
          log.info 'Connected via in-process transport (lite mode)'
          true
        end

        def create_session_with_failover(connection_name:)
          opts = build_bunny_opts(connection_name: connection_name)
          hosts = opts[:hosts] || [{ host: opts[:host] || '127.0.0.1', port: opts[:port] || 5672 }]
          last_error = nil

          hosts.each do |host_entry|
            attempt_opts = opts.dup
            if host_entry.is_a?(Hash)
              attempt_opts[:host] = host_entry[:host]
              attempt_opts[:port] = host_entry[:port]
            end
            attempt_opts.delete(:hosts)

            return connector.new(attempt_opts)
          rescue Bunny::TCPConnectionFailed, Bunny::PossibleAuthenticationFailureError, Errno::ECONNREFUSED => e
            last_error = e
            host_desc = host_entry.is_a?(Hash) ? "#{host_entry[:host]}:#{host_entry[:port]}" : host_entry
            handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.create_session',
                             host: host_desc)
          end

          raise Legion::Transport::ClusterUnavailable, "All cluster nodes exhausted: #{last_error&.message}" if defined?(Legion::Transport::ClusterUnavailable)

          raise last_error || StandardError.new('No cluster nodes available')
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

        def tear_down_session(sess)
          mark_session_closing(sess)
          Timeout.timeout(3) { sess.close }
        rescue Timeout::Error => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.tear_down_session')
          kill_reader_threads(sess)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.tear_down_session')
        end

        def kill_reader_threads(sess)
          reader_loop = sess.instance_variable_get(:@reader_loop)
          thread = reader_loop&.instance_variable_get(:@thread)
          thread&.kill
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.kill_reader_threads')
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
          status_mutex = sess.instance_variable_get(:@status_mutex)

          status_mutex&.synchronize do
            sess.instance_variable_set(:@status, :closing)
            sess.instance_variable_set(:@manually_closed, true)
          end

          sess.instance_variable_set(:@recovering_from_network_failure, false)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.mark_session_closing')
        end

        def safely_close_build_transport(build_session)
          build_transport = build_session&.instance_variable_get(:@transport)
          build_transport&.close
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.close_build_transport')
        end

        def safely_close_log_channel
          @log_channel&.close if @log_channel&.open?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.connection.close_log_channel')
        end

        def rebuild_single_session(connection_name:)
          reset_pool if @pool
          safely_close_log_channel
          @log_channel = nil
          @session = Concurrent::AtomicReference.new(create_session_with_failover(connection_name: connection_name))
          @channel_thread = Concurrent::ThreadLocalVar.new(nil)
          @channel_registry = Concurrent::Hash.new
          start_session(session)
          qos_channel = session.create_channel(nil, settings[:channel][:session_worker_pool_size])
          apply_qos_and_close(qos_channel)
          Legion::Settings[:transport][:connected] = true
          host  = settings.dig(:connection, :host) || '127.0.0.1'
          port  = settings.dig(:connection, :port) || 5672
          user  = settings.dig(:connection, :user) || 'guest'
          vhost = settings.dig(:connection, :vhost) || '/'
          log.info "Connected to amqp://#{user}@#{host}:#{port}/#{vhost}"
        end

        def build_started_session(connection_name:)
          sess = create_session_with_failover(connection_name: connection_name)
          start_session(sess)
          sess
        end

        def start_session(sess)
          return unless sess.respond_to?(:start)
          return if sess.respond_to?(:open?) && sess.open?

          sess.start
        end

        def reusable_pool?(pool_size)
          @pool && @configured_pool_size == pool_size && @pool.connected? && session_open?
        end

        def reset_pool
          @pool&.shutdown
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
            true
          end
        end

        def clear_reconnect_state
          reconnect_mutex.synchronize do
            @reconnecting = false
          end
        end
      end
    end
  end
end
