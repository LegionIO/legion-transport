# frozen_string_literal: true

require 'legion/transport/exchanges/task'

module Legion
  module Transport
    module Messages
      class CheckSubtask < Legion::Transport::Message
        include Legion::Transport::TaskEnvelope

        def exchange
          Legion::Transport::Exchanges::Task
        end

        def exchange_name
          'Legion::Transport::Exchanges::Task'
        end

        def routing_key
          task_route(name: :check_subtask)
        end

        def validate
          @valid = true
        end
      end
    end
  end
end
