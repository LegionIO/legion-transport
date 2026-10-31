# frozen_string_literal: true

module Legion
  module Transport
    module Messages
      class Task < Legion::Transport::Message
        include Legion::Transport::TaskEnvelope

        def exchange
          if @options.key?(:exchange) && @options[:exchange].is_a?(String)
            Legion::Transport::Exchange
          else
            Legion::Transport::Exchanges::Task
          end
        end

        def routing_key
          key = if @options.key? :routing_key
                  @options[:routing_key]
                elsif task_stage_present?(value: @options[:conditions])
                  task_route(name: :conditioner)
                elsif task_stage_present?(value: @options[:transformation])
                  task_route(name: :transform)
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
