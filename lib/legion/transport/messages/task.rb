# frozen_string_literal: true

module Legion
  module Transport
    module Messages
      class Task < Legion::Transport::Message
        def exchange
          if @options.key?(:exchange) && @options[:exchange].is_a?(String)
            Legion::Transport::Exchange
          else
            Legion::Transport::Exchanges::Task
          end
        end

        def message
          @options.except(*PUBLISH_OPTION_KEYS)
        end

        def routing_key
          key = if @options.key? :routing_key
                  @options[:routing_key]
                elsif @options[:conditions].is_a?(String) && @options[:conditions].length > 2
                  'task.subtask.conditioner'
                elsif @options[:transformation].is_a?(String) && @options[:transformation].length > 2
                  'task.subtask.transform'
                elsif @options[:queue].is_a?(String) && @options[:function].is_a?(String)
                  "#{@options[:queue]}.#{@options[:function]}"
                end
          log.debug "Task routing_key=#{key}"
          key
        end

        def validate
          raise TypeError unless @options[:function].is_a? String

          @valid = true
        end
      end
    end
  end
end
