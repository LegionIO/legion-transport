# frozen_string_literal: true

module Legion::Transport::Messages # rubocop:disable Style/ClassAndModuleChildren
  class Dynamic < Legion::Transport::Message
    include Legion::Transport::TaskEnvelope

    attr_accessor :options

    def type
      'task'
    end

    def message
      fields = task_execution_settings.fetch(:protocol).fetch(:metadata_fields).map(&:to_sym)
      args = @options.key?(:args) ? @options[:args] : @options.except(*ENVELOPE_KEYS, *fields)
      super.merge(args: args, function: function.values[:name])
    end

    def routing_key
      key = "#{function.runner.extension.values[:name]}.#{function.runner.values[:name]}.#{function.values[:name]}"
      log.debug "Dynamic routing_key=#{key} function_id=#{@options[:function_id]}"
      key
    end

    def exchange
      Legion::Transport::Exchange
    end

    def publish_exchange_name
      function.runner.extension.values[:exchange]
    end

    def function
      @function ||= Legion::Data::Model::Function[@options[:function_id]]
    end
  end
end
