# frozen_string_literal: true

require_relative 'protocol'

module Legion
  module Transport
    module Task
      module Envelope
        def message
          @options.except(*Legion::Transport::Message::ENVELOPE_KEYS).merge(task_metadata)
        end

        def headers
          metadata = task_metadata
          super.tap do |message_headers|
            metadata.each_key { |key| message_headers.delete(key.to_s) }
            message_headers.delete('task_protocol_version')
            message_headers.merge!(metadata).merge!(task_protocol_version: Legion::Transport::Task::Protocol::VERSION)
          end
        end

        def publish_envelope_options(options:, **)
          key = routing_key
          raise ArgumentError, 'Task routing key must be a nonempty string' unless key.is_a?(String) && !key.strip.empty?

          super.merge(routing_key: key)
        end

        private

        def task_metadata
          @options.slice(*Legion::Transport::Task::Protocol::METADATA_FIELDS)
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
end
