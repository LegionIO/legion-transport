# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'tenant_topology'
require_relative 'exchanges/task'

module Legion
  module Transport
    module TenantProvisioner
      extend Legion::Logging::Helper

      EXCHANGE_NAMES = %w[task results events].freeze

      def self.provision(tenant_id, channel: nil)
        tenant_id = TenantTopology.resolve_tenant_id(tenant_id: tenant_id)
        ch = channel || Legion::Transport::Connection.channel
        begin
          EXCHANGE_NAMES.each do |base_name|
            declaration = exchange_declaration(name: base_name, tenant_id: tenant_id)
            ch.public_send(declaration[:type], declaration[:name], durable: true, auto_delete: false)
            dlx_name = TenantTopology.exchange_name("#{base_name}.dlx", tenant_id: tenant_id)
            Legion::Transport::Queue.allocate.declare_dlx(dlx_name, ch)
          end
        ensure
          safely_close_channel(channel: ch) unless channel
        end
        log.info "Provisioned tenant topology for tenant_id=#{tenant_id}"
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: 'transport.tenant_provisioner.provision',
                         tenant_id: tenant_id)
        raise
      end

      def self.deprovision(tenant_id, channel: nil)
        return log.debug('Skipping deprovision: topology disabled') unless TenantTopology.enabled?

        tid = tenant_id.to_s.strip
        if tid.empty? || tid == 'default'
          log.warn "Skipping deprovision: refusing to delete global exchanges for tenant_id=#{tenant_id.inspect}"
          return
        end

        ch = channel || Legion::Transport::Connection.channel
        begin
          EXCHANGE_NAMES.each do |base_name|
            [base_name, "#{base_name}.dlx"].each do |resource|
              next if TenantTopology.shared?(resource)

              name = TenantTopology.exchange_name(resource, tenant_id: tid)
              begin
                ch.exchange_delete(name)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: 'transport.tenant_provisioner.deprovision_exchange',
                                 tenant_id: tid, exchange_name: name)
              end
            end
          end
        ensure
          safely_close_channel(channel: ch) unless channel
        end
        log.info "Deprovisioned tenant topology for tenant_id=#{tid}"
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: 'transport.tenant_provisioner.deprovision',
                         tenant_id: tid)
        raise
      end

      private_class_method def self.exchange_declaration(name:, tenant_id:)
        klass = name == 'task' ? Legion::Transport::Exchanges::Task : Legion::Transport::Exchange
        klass.declaration(name: name, tenant_id: tenant_id)
      end

      private_class_method def self.safely_close_channel(channel:)
        channel.close if channel.respond_to?(:close)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'transport.tenant_provisioner.close_channel')
      end
    end
  end
end
