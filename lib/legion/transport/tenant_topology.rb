# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Transport
    module TenantTopology
      extend Legion::Logging::Helper

      DEFAULT_SHARED_EXCHANGES = %w[legion.control legion.health legion.audit].freeze
      DEFAULT_PREFIX_FORMAT = 't.%<tenant_id>s.%<name>s'

      def self.exchange_name(base_name, tenant_id: nil)
        name = base_name.to_s
        return name if name.empty? || !enabled? || shared?(name)

        scoped_name(name: name, tenant_id: resolve_tenant_id(tenant_id: tenant_id))
      end

      def self.queue_name(base_name, tenant_id: nil)
        name = base_name.to_s
        return name if name.empty? || !enabled?

        scoped_name(name: name, tenant_id: resolve_tenant_id(tenant_id: tenant_id))
      end

      def self.resolve_tenant_id(tenant_id: nil)
        value = (tenant_id || current_tenant_id).to_s.strip
        value.empty? ? 'default' : value
      end

      def self.shared?(name)
        configured_shared_exchanges.any? do |entry|
          name == entry || name.start_with?("#{entry}.")
        end
      end

      def self.enabled?
        settings = transport_settings
        settings.is_a?(Hash) && settings.dig(:tenant_topology, :enabled) == true
      end

      def self.current_tenant_id
        return nil unless defined?(Legion::TenantContext)

        Legion::TenantContext.current
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :tenant_topology_current_tenant_id)
        nil
      end

      private_class_method def self.scoped_name(name:, tenant_id:)
        return name if tenant_id == 'default'

        marker = '__legion_resource_name__'
        template = format(prefix_format, tenant_id: tenant_id, name: marker)
        pattern = Regexp.escape(template).sub(marker, '.+')
        return name if name.match?(/\A#{pattern}\z/)

        format(prefix_format, tenant_id: tenant_id, name: name)
      end

      private_class_method def self.prefix_format
        settings = transport_settings
        return DEFAULT_PREFIX_FORMAT unless settings.is_a?(Hash)

        settings.dig(:tenant_topology, :prefix_format) || DEFAULT_PREFIX_FORMAT
      end

      private_class_method def self.configured_shared_exchanges
        settings = transport_settings
        return DEFAULT_SHARED_EXCHANGES unless settings.is_a?(Hash)

        Array(settings.dig(:tenant_topology, :shared_exchanges)).tap do |arr|
          return DEFAULT_SHARED_EXCHANGES if arr.empty?
        end
      end

      private_class_method def self.transport_settings
        Legion::Settings[:transport] || {}
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :tenant_topology_transport_settings)
        {}
      end
    end
  end
end
