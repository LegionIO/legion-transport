# frozen_string_literal: true

module Legion
  module Transport
    module Messages
      # Generic publish to an arbitrary exchange + routing key without requiring
      # legion-data or a function_id. Used by the /api/transport/publish route.
      class Direct < Legion::Transport::Message
        def exchange
          Legion::Transport::Exchange
        end

        def routing_key
          @options[:routing_key]
        end

        def message
          @options.except(:exchange, :routing_key, *PUBLISH_OPTION_KEYS)
        end

        def validate
          raise ArgumentError, 'exchange is required' unless @options[:exchange].is_a?(String) && !@options[:exchange].empty?
          raise ArgumentError, 'routing_key is required' unless @options[:routing_key].is_a?(String) && !@options[:routing_key].empty?

          @valid = true
        end
      end
    end
  end
end
