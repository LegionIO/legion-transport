# frozen_string_literal: true

module Legion
  module Transport
    module TaskProtocol
      STATUSES = {
        queued: 'task.queued', running: 'task.running', completed: 'task.completed',
        exception: 'task.exception', failed: 'task.failed', skipped: 'task.skipped',
        cancelled: 'task.cancelled', expired: 'task.expired', delayed: 'task.delayed',
        dispatching: 'task.dispatching', multiplied: 'task.multiplied', retry_pending: 'task.retry_pending',
        unknown: 'task.unknown', conditioner_queued: 'conditioner.queued', conditioner_failed: 'conditioner.failed',
        conditioner_exception: 'conditioner.exception', transformer_queued: 'transformer.queued',
        transformer_succeeded: 'transformer.succeeded', transformer_validation_failed: 'transformer.validation_failed',
        transformer_failed: 'transformer.failed', blocked: 'task.blocked'
      }.freeze
      TERMINAL_STATUSES = STATUSES.values_at(
        :completed, :failed, :exception, :skipped, :cancelled, :expired, :multiplied, :conditioner_failed,
        :conditioner_exception, :transformer_validation_failed, :transformer_failed, :unknown, :blocked
      ).freeze
      LEGACY_TERMINAL_STATUSES = %w[completed complete failed error cancelled canceled timeout timed_out exception skipped expired multiplied].freeze
      ROUTES = {
        check_subtask: 'task.subtask.check', conditioner: 'task.subtask.conditioner',
        transform: 'task.subtask.transform', task_update: 'task.update'
      }.freeze
      MESSAGE_TYPES = {
        check_subtask: 'check_subtask', subtask: 'subtask', task: 'task', dynamic: 'dynamic', transform: 'transform'
      }.freeze
      VERSION = 1
      METADATA_FIELDS = %i[
        task_id parent_id master_id chain_id relationship_id function_id function runner_class
        runner_routing_key trigger_function_id trigger_runner_id debug engine schema engine_options
        principal_id principal_type worker_id tenant_id source correlation_id message_id attempt_id
        execution_token depth deadline_at schedule_id occurrence_id definition_version
        originating_principal_id originating_principal_type
      ].freeze

      module Helper
        def task_status(name:)
          raise ArgumentError, "Unknown task status name: #{name.inspect}" unless (name.is_a?(String) || name.is_a?(Symbol)) && STATUSES.key?(name.to_sym)

          STATUSES.fetch(name.to_sym)
        end

        def task_route(name:)
          raise ArgumentError, "Unknown task route name: #{name.inspect}" unless (name.is_a?(String) || name.is_a?(Symbol)) && ROUTES.key?(name.to_sym)

          ROUTES.fetch(name.to_sym)
        end

        def task_terminal_status?(status:)
          TERMINAL_STATUSES.include?(status) || LEGACY_TERMINAL_STATUSES.include?(status)
        end
      end
    end
  end
end
