module Legion
  module JSON
    # The Legion JSON parser error abstraction.
    class ParseError < StandardError
      attr_reader :data, :cause

      def self.build(original_error, data)
        new(original_error.message).tap do |error|
          error.instance_eval do
            @cause = original_error
            set_backtrace original_error.backtrace
            @data = data
          end
        end
      end
    end
  end
end
