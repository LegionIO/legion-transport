# frozen_string_literal: true

require 'bunny/exceptions'

module Legion
  module Transport
    class PoolTimeout < StandardError; end
    class PoolClosed < StandardError; end
    class ClusterUnavailable < StandardError; end
    class PayloadTooLarge < StandardError; end
    class EncryptionNotReady < StandardError; end

    class PublishRejected < StandardError
      attr_reader :result

      def initialize(result:, **)
        @result = result
        super("Publication rejected: #{result[:status]}#{": #{result[:error]}" if result[:error]}")
      end
    end
  end
end
