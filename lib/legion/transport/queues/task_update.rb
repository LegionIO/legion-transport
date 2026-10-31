# frozen_string_literal: true

require 'legion/transport/task_protocol'

module Legion
  module Transport
    module Queues
      class TaskUpdate < Legion::Transport::Queue
        include Legion::Transport::TaskProtocol::Helper

        def queue_name
          task_route(name: :task_update)
        end

        def queue_options
          hash = {}
          hash[:manual_ack] = true
          hash[:durable] = true
          hash[:exclusive] = false
          hash[:block] = false
          hash[:arguments] = { 'x-dead-letter-exchange': 'task.dlx' }
          hash
        end
      end
    end
  end
end
