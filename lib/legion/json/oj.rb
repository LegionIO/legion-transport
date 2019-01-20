module Legion
  module JSON
    # The Legion JSON parser when running on MRI.
    class Oj
      def load(string)
        ::Oj.load(string, symbol_keys: true)
      end

      def dump(object, options = {})
        options[:indent] = 2 if options[:pretty]
        ::Oj.dump(object, options)
      end
    end
  end
end
