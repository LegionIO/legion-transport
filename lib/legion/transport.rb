# frozen_string_literal: true

require 'legion/transport/version'
require 'legion/settings'
require 'legion/logging'
require 'legion/logging/helper'
require 'legion/transport/settings'
require_relative 'transport/errors'
require_relative 'transport/routes'

module Legion
  module Transport
    if ENV['LEGION_MODE'] == 'lite'
      require_relative 'transport/in_process'
      TYPE = 'local'
      CONNECTOR = Legion::Transport::InProcess
    else
      require 'bunny'
      TYPE = 'bunny'
      CONNECTOR = ::Bunny
    end

    class << self
      include Legion::Logging::Helper

      def register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('transport', Legion::Transport::Routes)
        log.debug 'Legion::Transport routes registered with API'
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'transport.register_routes')
      end

      def logger
        require 'logger'
        @logger ||= ::Logger.new($stdout)
        desired_level = logger_level_value
        @logger.level = desired_level
        @logger
      end

      private

      def logger_level_value
        case transport_log_level.to_s.downcase
        when 'debug' then ::Logger::DEBUG
        when 'info'  then ::Logger::INFO
        when 'error' then ::Logger::ERROR
        when 'fatal' then ::Logger::FATAL
        else              ::Logger::WARN
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'transport.logger.level_lookup')
        ::Logger::WARN
      end

      def bunny_log_level_value
        case transport_log_level.to_s.downcase
        when 'debug' then :debug
        when 'info'  then :info
        when 'error' then :error
        when 'fatal' then :fatal
        else              :warn
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'transport.logger.bunny_level_lookup')
        :warn
      end

      def transport_log_level
        source = Legion::Settings[:transport]
        return source[:log_level] if source.is_a?(Hash) && source[:log_level]
        return source[:logger_level] if source.is_a?(Hash) && source[:logger_level]
        return source.dig(:logger, :level) if source.is_a?(Hash) && source.dig(:logger, :level)

        'warn'
      end
    end
  end

  require_relative 'transport/helpers/pool'
  require_relative 'transport/helpers/channel_pool'
  require_relative 'transport/helpers/policy'
  require_relative 'transport/common'
  require_relative 'transport/queue'
  require_relative 'transport/exchange'
  require_relative 'transport/message'
  require_relative 'transport/spool'
  require_relative 'transport/tenant_topology'
  require_relative 'transport/tenant_provisioner'
  require_relative 'transport/tenant_quota'
  require_relative 'transport/helper'
  require_relative 'transport/kafka'
end
