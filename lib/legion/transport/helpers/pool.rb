# frozen_string_literal: true

require 'English'
require 'legion/logging/helper'
require 'timeout'

module Legion
  module Transport
    module Helpers
      class Pool
        include Legion::Logging::Helper

        CLOSE_TIMEOUT = 1

        def initialize(size: 1, timeout: 5, &block)
          @size          = size
          @timeout       = timeout
          @factory       = block
          @available     = []
          @in_use        = []
          @creating      = 0
          @closed        = false
          @close_session = nil
          @mutex         = Mutex.new
          @condition     = ConditionVariable.new
        end

        def checkout
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + @timeout

          loop do
            connection = reserve_connection(deadline: deadline)
            return create_connection(deadline: deadline) unless connection
            return connection unless connection.respond_to?(:closed?) && connection.closed?

            checkin(connection)
          end
        end

        def checkin(connection)
          available = connection.respond_to?(:open?) && connection.open?
          owned = @mutex.synchronize do
            next false unless @in_use.delete(connection)

            @available << connection if available && !@closed
            @condition.broadcast
            true
          end
          close_connection(connection: connection) if owned && !available
        end

        def size
          @mutex.synchronize { @available.size + @in_use.size }
        end

        def sessions
          @mutex.synchronize { @available + @in_use }
        end

        def shutdown(&close_session)
          detached = @mutex.synchronize do
            # In-flight factories retain this teardown even after shutdown returns.
            @close_session = close_session unless @closed
            @closed = true
            connections = @available + @in_use
            @available.clear
            @in_use.clear
            @condition.broadcast
            connections
          end

          failure = nil
          detached.each do |connection|
            close_connection(connection: connection)
          rescue StandardError => e
            failure ||= e
          end
          raise failure if failure

          log.info "Pool shutdown complete size=#{@size}"
          nil
        end

        def connected?
          sessions.any? { |connection| connection.respond_to?(:open?) && connection.open? }
        end

        private

        def reserve_connection(deadline:)
          @mutex.synchronize do
            loop do
              raise Legion::Transport::PoolClosed, 'connection pool is shut down' if @closed

              remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              raise Legion::Transport::PoolTimeout, 'timed out waiting for available connection' if remaining <= 0

              if (connection = @available.pop)
                @in_use << connection
                return connection
              end

              if @available.size + @in_use.size + @creating < @size
                @creating += 1
                return nil
              end

              @condition.wait(@mutex, remaining)
            end
          end
        end

        def create_connection(deadline:)
          connection = nil
          registered = false
          begin
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            raise Legion::Transport::PoolTimeout, 'timed out creating pool connection' if remaining <= 0

            # The factory must clean up partially started sessions when interrupted.
            Timeout.timeout(remaining, Legion::Transport::PoolTimeout, 'timed out creating pool connection') do
              connection = @factory.call
            end

            @mutex.synchronize do
              raise Legion::Transport::PoolClosed, 'connection pool is shut down' if @closed
              raise Legion::Transport::PoolTimeout, 'timed out creating pool connection' if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline

              @in_use << connection
              registered = true
            end
            connection
          ensure
            @mutex.synchronize do
              @creating -= 1
              @condition.broadcast
            end
            close_connection(connection: connection, failure: $ERROR_INFO) if connection && !registered
          end
        end

        def close_connection(connection:, failure: nil)
          close_session = @mutex.synchronize { @close_session }
          if close_session
            close_session.call(connection)
          else
            Timeout.timeout(CLOSE_TIMEOUT) { connection.close }
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: 'transport.pool.close', size: @size)
          raise(failure || e)
        end
      end
    end
  end
end
