# frozen_string_literal: true

require 'bunny/exceptions'

module Legion
  module Transport
    class PoolTimeout < StandardError; end
    class PoolClosed < StandardError; end
    class ClusterUnavailable < StandardError; end
    class PayloadTooLarge < StandardError; end
  end
end
