require 'legion/json/version'
require 'legion/json/parse_error'
require 'multi_json'

module Legion
  module JSON
    class << self
      def parser
        @parser ||= MultiJson
      end

      def load(string, symbolize_keys = true)
        parser.load(string, symbolize_keys: symbolize_keys)
      rescue StandardError => e
        raise Legion::JSON::ParseError.build(e, string)
      end

      def dump(object, pretty = false)
        parser.dump(object, pretty: pretty)
      end
    end
  end
end
