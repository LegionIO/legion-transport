# frozen_string_literal: true

module Legion
  module Transport
    module TaskEnvelope
      def message
        @options.except(*Legion::Transport::Message::ENVELOPE_KEYS).merge(task_metadata)
      end

      def headers
        metadata = task_metadata
        super.except(*metadata.keys.map(&:to_s), 'task_protocol_version')
             .merge(metadata).merge(task_protocol_version: task_execution_settings.fetch(:protocol).fetch(:version))
      end

      def publish_envelope_options(options:, **)
        key = routing_key
        raise ArgumentError, 'Task routing key must be a nonempty string' unless key.is_a?(String) && !key.strip.empty?

        super.merge(routing_key: key)
      end

      private

      def task_metadata
        fields = task_execution_settings.fetch(:protocol).fetch(:metadata_fields).map(&:to_sym)
        @options.slice(*fields)
      end

      def task_stage_present?(value:, **)
        case value
        when String then !value.strip.empty?
        when Hash, Array then !value.empty?
        else !value.nil?
        end
      end
    end
  end
end
