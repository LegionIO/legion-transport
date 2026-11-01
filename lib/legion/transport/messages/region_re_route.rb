# frozen_string_literal: true

module Legion
  module Transport
    module Messages
      class RegionReRoute < Legion::Transport::Message
        def exchange
          Legion::Transport::Exchanges::Task
        end

        def routing_key
          "region.reroute.#{target_region}"
        end

        def message
          {
            original_payload: @options[:original_payload] || @options.except(:target_region),
            target_region:    target_region,
            source_region:    source_region,
            rerouted_at:      Time.now.to_i
          }
        end

        def validate
          raise ArgumentError, 'target_region is required' unless @options[:target_region].is_a?(String) && !@options[:target_region].empty?

          @valid = true
        end

        private

        def target_region
          @options[:target_region]
        end

        def source_region
          @options[:source_region] ||
            Legion::Settings[:region][:current] ||
            'unknown'
        end
      end
    end
  end
end
