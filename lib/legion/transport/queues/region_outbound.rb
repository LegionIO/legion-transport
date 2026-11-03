# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Transport
    module Queues
      module RegionOutbound
        extend Legion::Logging::Helper

        module_function

        def declare_all
          peers = Legion::Settings[:region][:peers]
          return [] unless peers.is_a?(Array) && !peers.empty?

          current = defined?(Legion::Region) ? Legion::Region.current : nil
          peers.reject { |p| p == current }.map do |peer|
            declare_outbound(peer)
          end
        end

        def declare_outbound(target_region)
          queue_name = queue_name_for(target_region)
          channel = Legion::Transport::Connection.channel
          channel.queue(
            queue_name,
            durable:   true,
            arguments: { 'x-dead-letter-exchange' => 'tasks.dlx' }
          )
          log.info "Declared region outbound queue=#{queue_name} target_region=#{target_region}"
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.region_outbound.declare',
                           target_region: target_region, queue_name: queue_name)
          nil
        end

        def queue_name_for(target_region)
          "legion.tasks.outbound.#{target_region}"
        end
      end
    end
  end
end
