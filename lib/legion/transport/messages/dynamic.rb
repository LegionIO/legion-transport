# frozen_string_literal: true

module Legion::Transport::Messages # rubocop:disable Style/ClassAndModuleChildren
  class Dynamic < Legion::Transport::Message
    attr_accessor :options

    def type
      'task'
    end

    def message
      { args:     @options[:args] || @options.except(*PUBLISH_OPTION_KEYS),
        function: function.values[:name] }
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
