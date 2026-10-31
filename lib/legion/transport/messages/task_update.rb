# frozen_string_literal: true

require 'legion/transport/exchanges/task'

module Legion
  module Exception
    class InvalidTaskStatus < ArgumentError; end
    class InvalidTaskId < ArgumentError; end
  end
end

module Legion
  module Transport
    module Messages
      class TaskUpdate < Legion::Transport::Message
        include Legion::Transport::TaskEnvelope

        def routing_key
          task_route(name: :task_update)
        end

        def exchange
          Legion::Transport::Exchanges::Task
        end

        def valid_status
          task_execution_settings.fetch(:statuses).keys.map { |name| task_status(name: name) }
        end

        def validate
          raise Legion::Exception::InvalidTaskId unless @options[:task_id].is_a?(Integer) && @options[:task_id].positive?
          raise Legion::Exception::InvalidTaskStatus unless valid_status.include?(@options[:status])

          @valid = true
        end
      end
    end
  end
end
