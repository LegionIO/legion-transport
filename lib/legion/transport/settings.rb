# frozen_string_literal: true

require 'legion/settings'

module Legion
  module Transport
    module Settings
      def self.connection
        host = ENV['transport.connection.host'] || '127.0.0.1'
        port = (ENV['transport.connection.port'] || DEFAULT_AMQP_PORT).to_i

        existing = defined?(Legion::Settings) ? (Legion::Settings[:transport][:connection] || {}) : {}
        extra_server  = existing[:server]
        extra_servers = existing[:servers] || []
        extra_hosts   = existing[:hosts] || []

        {
          read_timeout:              3,
          heartbeat:                 (ENV['transport.connection.heartbeat'] || 30).to_i,
          automatically_recover:     true,
          continuation_timeout:      8000,
          network_recovery_interval: (ENV['transport.connection.recovery_interval'] || 2).to_i,
          connection_timeout:        (ENV['transport.connection.connection_timeout'] || 10).to_i,
          frame_max:                 65_536,
          user:                      ENV['transport.connection.user'] || 'guest',
          password:                  ENV['transport.connection.password'] || 'guest',
          host:                      host,
          port:                      port,
          vhost:                     ENV['transport.connection.vhost'] || '/',
          recovery_attempts:         (ENV['transport.connection.recovery_attempts'] || 10).to_i,
          logger_level:              ENV['transport.log_level'] || 'info',
          connected:                 false,
          resolved_hosts:            resolve_hosts(
            host: host, hosts: Array(extra_hosts),
            server: extra_server, servers: Array(extra_servers),
            port: port
          )
        }
      end

      DEFAULT_AMQP_PORT = 5672

      def self.resolve_hosts(host: nil, hosts: [], server: nil, servers: [], port: nil)
        port ||= DEFAULT_AMQP_PORT

        all = Array(hosts) + Array(servers) + Array(host) + Array(server)
        all = ["127.0.0.1:#{port}"] if all.empty?

        all.map! { |s| s.to_s.include?(':') ? s.to_s : "#{s}:#{port}" }
        all.uniq
      end

      def self.channel
        {
          default_worker_pool_size: ENV['transport.channel.default_worker_pool_size'] || 1,
          session_worker_pool_size: ENV['transport.channel.session_worker_pool_size'] || 16
        }
      end

      def self.queues
        {
          manual_ack:  true,
          durable:     true,
          exclusive:   false,
          block:       false,
          auto_delete: false,
          arguments:   { 'x-queue-type': 'quorum' }
        }
      end

      def self.exchanges
        {
          type:        'topic',
          arguments:   {},
          auto_delete: false,
          durable:     true,
          internal:    false
        }
      end

      def self.messages
        {
          encrypt:    ENV['transport.messages.encrypt'] == 'true',
          ttl:        ENV.fetch('transport.messages.ttl', nil),
          priority:   ENV['transport.messages.priority'].to_i,
          persistent: ENV['transport.messages.persistent'] == 'true'
        }
      end

      def self.tenant_topology
        {
          enabled:          false,
          prefix_format:    't.%<tenant_id>s.',
          shared_exchanges: %w[legion.control legion.health legion.audit],
          auto_provision:   true,
          quotas:           {}
        }
      end

      def self.default
        cluster_csv = ENV.fetch('transport.cluster_nodes', '')
        {
          type:                 'rabbitmq',
          connected:            false,
          logger_level:         ENV['transport.logger_level'] || 'info',
          messages:             messages,
          prefetch:             ENV['transport.prefetch'].to_i,
          exchanges:            exchanges,
          queues:               queues,
          connection:           connection,
          channel:              channel,
          tenant_topology:      tenant_topology,
          cluster_nodes:        cluster_csv.empty? ? [] : cluster_csv.split(',').map(&:strip),
          connection_pool_size: (ENV['transport.connection_pool_size'] || 1).to_i,
          max_payload_bytes:    (ENV['transport.max_payload_bytes'] || 1_048_576).to_i,
          region:               ENV.fetch('transport.region', nil),
          management_port:      (ENV['transport.management_port'] || 15_672).to_i,
          quorum_queue_policy:  {
            enabled:        ENV['transport.quorum_queue_policy.enabled'] == 'true',
            pattern:        ENV['transport.quorum_queue_policy.pattern'] || '^legion\\.',
            delivery_limit: (ENV['transport.quorum_queue_policy.delivery_limit'] || 5).to_i
          }
        }
      end
    end
  end
end

begin
  Legion::Settings.merge_settings('transport', Legion::Transport::Settings.default) if Legion.const_defined?('Settings')
rescue StandardError => e
  if defined?(Legion::Logging)
    Legion::Logging.warn("Legion::Transport settings merge failed: #{e.message}")
  else
    warn "Legion::Transport settings merge failed: #{e.message}"
  end
end
