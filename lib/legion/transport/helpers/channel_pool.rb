# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Transport
    module Helpers
      class ChannelPool
        include Legion::Logging::Helper

        def initialize(connection:, size: 10, prefetch: 1)
          @connection = connection
          @size       = size
          @prefetch   = prefetch
          @available  = []
          @in_use     = []
          @mutex      = Mutex.new
        end

        def borrow
          @mutex.synchronize do
            purge_closed_unsafe

            if (ch = @available.pop)
              @in_use << ch
              log.debug "ChannelPool borrow reused (available=#{@available.size} in_use=#{@in_use.size})"
              return ch
            end

            total = @available.size + @in_use.size
            return nil if total >= @size

            ch = @connection.create_channel
            ch.prefetch(@prefetch) if ch.respond_to?(:prefetch)
            @in_use << ch
            log.debug "ChannelPool borrow new channel (available=#{@available.size} in_use=#{@in_use.size})"
            ch
          end
        end

        def return(channel)
          @mutex.synchronize do
            @in_use.delete(channel)
            return unless channel.respond_to?(:open?) && channel.open?
            return if (@available.size + @in_use.size) >= @size

            @available << channel
            log.debug "ChannelPool return (available=#{@available.size} in_use=#{@in_use.size})"
          end
        end

        def purge_closed
          @mutex.synchronize { purge_closed_unsafe }
        end

        def close_all
          @mutex.synchronize do
            total = @available.size + @in_use.size
            (@available + @in_use).each do |ch|
              ch.close
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'transport.channel_pool.close_all', size: @size)
            end
            @available.clear
            @in_use.clear
            log.info "ChannelPool closed #{total} channel(s)"
          end
        end

        def size
          @mutex.synchronize { @available.size + @in_use.size }
        end

        private

        def purge_closed_unsafe
          @available.reject! { |c| !c.respond_to?(:open?) || !c.open? }
          @in_use.reject!    { |c| !c.respond_to?(:open?) || !c.open? }
        end
      end
    end
  end
end
