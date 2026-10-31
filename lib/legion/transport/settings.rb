# frozen_string_literal: true

require 'legion/logging'
require 'legion/logging/helper'
require 'legion/settings'

module Legion
  module Transport
    module Settings
      extend Legion::Logging::Helper

      class ConfigurationError < ArgumentError; end

      module Helper
        def transport_task_publication_settings
          Legion::Settings.register_library(:transport, Legion::Transport::Settings.default) unless Legion::Settings.loader&.merged_modules&.key?(:transport)
          policy = Legion::Settings[:transport][:task_publication]
          raise ConfigurationError, 'transport.task_publication must be a Hash' unless policy.is_a?(Hash)

          %i[publisher_confirm mandatory return_result spool].each do |key|
            next if [true, false].include?(policy[key])

            raise ConfigurationError, "transport.task_publication.#{key} must be true or false"
          end
          timeout = policy[:publish_confirm_timeout_ms]
          unless timeout.is_a?(Integer) && timeout.positive?
            raise ConfigurationError, 'transport.task_publication.publish_confirm_timeout_ms must be a positive Integer'
          end

          policy
        end
      end

      def self.connection
        host = ENV['transport.connection.host'] || '127.0.0.1'
        port = (ENV['transport.connection.port'] || DEFAULT_AMQP_PORT).to_i

        existing = Legion::Settings.dig(:transport, :connection) || {}
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
          logger_level:              resolve_log_level,
          connected:                 false,
          resolved_hosts:            resolve_hosts(
            host: host, hosts: Array(extra_hosts),
            server: extra_server, servers: Array(extra_servers),
            port: port
          )
        }
      end

      DEFAULT_AMQP_PORT = 5672

      def self.resolve_log_level
        ENV['transport.log_level'] || ENV['transport.logger_level'] || 'warn'
      end

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
          encrypt:                    ENV['transport.messages.encrypt'] == 'true',
          ttl:                        ENV.fetch('transport.messages.ttl', nil),
          priority:                   ENV['transport.messages.priority'].to_i,
          persistent:                 ENV.fetch('transport.messages.persistent', 'true') == 'true',
          app_id:                     'legion',
          protocol_version:           '2.0',
          region_affinity:            'prefer_local',
          encryption_timeout_seconds: 5
        }
      end

      def self.tenant_topology
        {
          enabled:          false,
          prefix_format:    't.%<tenant_id>s.%<name>s',
          shared_exchanges: %w[legion.control legion.health legion.audit],
          auto_provision:   true,
          quotas:           {}
        }
      end

      def self.kafka
        require_relative 'kafka/defaults'
        Legion::Transport::Kafka::DEFAULTS.dup.tap do |k|
          k[:enabled] = ENV['transport.kafka.enabled'] == 'true'
          k[:brokers] = ENV['transport.kafka.brokers'].split(',').map(&:strip) if ENV['transport.kafka.brokers']
          k[:consumer_group] = ENV['transport.kafka.consumer_group'] if ENV['transport.kafka.consumer_group']
        end
      end

      def self.default
        cluster_csv = ENV.fetch('transport.cluster_nodes', '')
        {
          type:                 'rabbitmq',
          connected:            false,
          logger_level:         resolve_log_level,
          messages:             messages,
          task_publication:     {
            publisher_confirm: true, mandatory: true, return_result: true, publish_confirm_timeout_ms: 5000, spool: false
          },
          prefetch:             ENV.fetch('transport.prefetch', '2').to_i,
          exchanges:            exchanges,
          queues:               queues,
          connection:           connection,
          channel:              channel,
          tenant_topology:      tenant_topology,
          kafka:                kafka,
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
  Legion::Settings.register_library(:transport, Legion::Transport::Settings.default)
rescue StandardError => e
  Legion::Transport::Settings.handle_exception(e, level: :fatal, handled: true, operation: 'transport.settings.register')
end
