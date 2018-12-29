require 'jrjackson'

module Legion
  module JSON
    # The Legion JSON parser when running on JRuby.
    class JrJackson
      def load(string)
        ::JrJackson::Json.load(string, symbolize_keys: true, raw: true)
      end

      def dump(object, options = {})
        ::JrJackson::Json.dump(object, options)
      end
    end
  end
end
