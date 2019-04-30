require 'legion/json/version'
require 'legion/json/parse_error'

module Legion
  # Used to create JSON objects
  module JSON
    class << self
      # Set up the JSON parser. This method must be called before any
      # attempt to use the parser. This method is currently called at
      # the bottom of this file. The appropriate JSON parser will be
      # loaded for the current platform.
      #
      # @return [Object] parser.
      def setup!
        if RUBY_ENGINE == 'jruby'
          require 'jrjackson'
          require 'legion/json/jrjackson'
          @parser = Legion::JSON::JrJackson.new
        else
          require 'oj'
          Oj.default_options = { mode: :compat }
          require 'legion/json/oj'
          @parser = Legion::JSON::Oj.new
        end
      end

      # Load (and parse) a JSON string.
      #
      # @param string [String]
      # @return [Object]
      def load(string)
        @parser.load(string)
      rescue StandardError => e
        raise Legion::JSON::ParseError.build(e, string)
      end

      # Dump (generate) a JSON string from a Ruby object.
      #
      # @param object [Object]
      # @param options [Hash]
      def dump(object, options = {})
        @parser.dump(object, options)
      end
    end
  end
end

Legion::JSON.setup!
