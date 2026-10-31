# frozen_string_literal: true

require 'legion/transport/exchanges/task'

module Legion
  module Transport
    module Messages
      class SubTask < Legion::Transport::Message
        include Legion::Transport::TaskEnvelope

        def exchange
          Legion::Transport::Exchanges::Task
        end

        def routing_key
          key = if @options.key?(:routing_key)
                  @options[:routing_key]
                elsif task_stage_present?(value: @options[:conditions])
                  task_route(name: :conditioner)
                elsif task_stage_present?(value: @options[:transformation])
                  task_route(name: :transform)
                elsif @options[:function_id].is_a? Integer
                  function = Legion::Data::Model::Function[@options[:function_id]]
                  "#{function.runner.extension.values[:exchange]}.#{function.runner.values[:queue]}.#{function.values[:name]}"
                elsif @options[:runner_routing_key].is_a?(String) && @options[:function].is_a?(String)
                  "#{@options[:runner_routing_key]}.#{@options[:function]}"
                end
          log.debug "SubTask routing_key=#{key} function_id=#{@options[:function_id]}"
          key
        end

        def validate
          raise TypeError unless @options[:function].is_a?(String) || @options[:function_id].is_a?(Integer)

          @valid = true
        end
      end
    end
  end
end
