# frozen_string_literal: true

require 'digest'
require 'timeout'
require 'legion/json'
require 'legion/logging/helper'
require_relative 'tenant_topology'
require_relative 'tenant_quota'
require_relative 'connection'

module Legion
  module Transport
    module TenantMigration
      extend Legion::Logging::Helper

      class Blocked < StandardError; end
      class Pending < StandardError; end

      ORIGINAL_EXCHANGE_HEADER = 'x-legion-original-exchange'
      TENANT_HEADERS = %w[tenant_id tenant-id x-tenant-id x-legion-tenant-id legion_tenant_id].freeze
      QUEUE_OPTIONS = %i[durable exclusive auto_delete arguments].freeze
      EXCHANGE_OPTIONS = %i[durable auto_delete internal arguments].freeze
      @registry = {}
      @registry_mutex = Mutex.new

      class << self
        def register_queue(tenant_id:, name:, options:, source_dlx: nil, **)
          return if tenant_id == 'default' || name.to_s.empty?
          return if options[:passive] || options[:no_declare]

          source = legacy_name(name: name.to_s, tenant_id: tenant_id, resource: :queue)
          declaration = {
            name: source, options: snapshot(value: options.slice(*QUEUE_OPTIONS)), bindings: [],
            source_dlx: source_dlx && legacy_name(name: source_dlx.to_s, tenant_id: tenant_id, resource: :exchange)
          }
          @registry_mutex.synchronize do
            existing = @registry[[tenant_id, source]]
            declaration[:bindings] = existing[:bindings] if existing
            @registry[[tenant_id, source]] = declaration
          end
          source
        end

        def register_binding(tenant_id:, name:, exchange:, options:, remove: false, **)
          return if tenant_id == 'default' || name.to_s.empty?

          source = legacy_name(name: name.to_s, tenant_id: tenant_id, resource: :queue)
          exchange_name = exchange.respond_to?(:name) ? exchange.name : exchange.to_s
          binding = {
            exchange: legacy_name(name: exchange_name, tenant_id: tenant_id, resource: :exchange),
            routing_key: options[:routing_key] || options[:key] || '', arguments: snapshot(value: options[:arguments] || {})
          }
          if exchange.respond_to?(:type)
            binding[:exchange_type] = exchange.type.to_s
            if exchange.respond_to?(:durable?)
              binding[:exchange_options] = { durable: exchange.durable?, auto_delete: exchange.auto_delete?,
                                             internal: exchange.internal?, arguments: snapshot(value: exchange.arguments) }
            end
          end
          @registry_mutex.synchronize do
            declaration = @registry[[tenant_id, source]]
            next unless declaration

            bindings = declaration[:bindings].reject do |item|
              matches = item.values_at(:exchange, :routing_key, :arguments) == binding.values_at(:exchange, :routing_key, :arguments)
              binding = item.merge(binding) if matches
              matches
            end
            bindings << binding unless remove
            @registry[[tenant_id, source]] = declaration.merge(bindings: bindings)
          end
        end

        def registered_queues(tenant_id:, **)
          declarations = @registry_mutex.synchronize do
            @registry.filter_map { |(tenant, _name), declaration| declaration if tenant == tenant_id.to_s }
          end
          snapshot(value: declarations)
        end

        def migrate(tenant_id:, queues: nil, max_messages: 10_000, timeout: 30, dry_run: false, **)
          result = { tenant_id: nil, status: :planned, moved: 0, queues: [], errors: [] }
          result[:tenant_id] = tenant_id.to_s.strip
          session = nil
          transfers = []
          validate_request!(tenant_id: result[:tenant_id], max_messages: max_messages, timeout: timeout, dry_run: dry_run)
          definitions = queues.nil? ? registered_queues(tenant_id: result[:tenant_id]) : queues
          result[:queues] = migration_plan(tenant_id: result[:tenant_id], definitions: definitions)
          raise Blocked, 'Lite mode has no persisted broker topology to migrate; use a RabbitMQ transport connection' if Connection.lite_mode?

          limits = { deadline: monotonic_now + timeout, max_messages: max_messages }
          Timeout.timeout(timeout) do
            session = Connection.create_dedicated_session(name: 'legion-tenant-migration')
            # Losing this session loses the broker locks. Never recover them transparently.
            session.instance_variable_set(:@automatically_recover, false)
            lock_sources(session: session, plans: result[:queues]) unless dry_run
            inspect_sources(session: session, plans: result[:queues])
            raise Blocked, 'Stop all source consumers before migrating; see per-queue consumer counts' if result[:queues].any? do |plan|
              plan[:consumers].positive?
            end
            return result if dry_run

            channel = session.create_channel
            declare_targets(channel: channel, plans: result[:queues])
            result[:queues].each do |plan|
              transfer_queue(channel: channel, plan: plan, result: result, transfers: transfers, limits: limits)
            end
            result[:status] = result[:queues].all? { |plan| plan[:remaining].zero? } ? :completed : :pending
          end
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.tenant_migration.migrate', tenant_id: result[:tenant_id])
          result[:status] = error_status(error: e)
          result[:errors] << { error_class: e.class.name, error: e.message }
          result[:queues].each do |plan|
            next if plan[:status] == :completed

            plan[:status] = result[:status]
          end
          result
        ensure
          cleanup_transfers(session: session, transfers: transfers)
          Connection.send(:tear_down_session, sess: session) if session
        end

        private

        def validate_request!(tenant_id:, max_messages:, timeout:, dry_run:, **)
          raise ArgumentError, 'dry_run must be true or false' unless dry_run.equal?(true) || dry_run.equal?(false)
          if tenant_id.empty? || tenant_id == 'default'
            raise Blocked,
                  'An explicit non-default tenant_id is required; ambient tenant context is not migration ownership'
          end
          raise Blocked, 'Enable transport.tenant_topology before planning or migrating broker data' unless TenantTopology.enabled?
          raise ArgumentError, 'max_messages must be a positive Integer' unless max_messages.is_a?(Integer) && max_messages.positive?
          raise ArgumentError, 'timeout must be finite and positive' unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        end

        def migration_plan(tenant_id:, definitions:, **)
          unless definitions.is_a?(Array) && !definitions.empty?
            raise Blocked, 'No tenant queue declarations are registered; instantiate/bind the tenant queues or supply an explicit queues manifest'
          end

          plans = definitions.flat_map { |definition| queue_plans(definition: definition, tenant_id: tenant_id) }
          deduplicated = plans.group_by { |plan| plan[:source] }.map do |source, entries|
            raise Blocked, "Conflicting migration declarations for #{source}" unless entries.uniq.one?

            entries.first
          end
          targets = deduplicated.map { |plan| plan[:target] }
          raise Blocked, 'Multiple source queues resolve to the same target; provide unambiguous queue declarations' unless targets.uniq.size == targets.size
          raise Blocked, 'A migration target is also a selected source queue' if targets.intersect?(deduplicated.map { |plan| plan[:source] })

          deduplicated
        end

        def queue_plans(definition:, tenant_id:, **)
          raise ArgumentError, 'Every queues entry must be a Hash' unless definition.is_a?(Hash)

          entry = definition.transform_keys(&:to_sym)
          raise ArgumentError, 'Queue bindings must be an Array' unless entry.fetch(:bindings).is_a?(Array)

          source = entry.fetch(:name).to_s
          raise ArgumentError, 'Legacy source queue names must be nonempty' if source.empty?

          target = TenantTopology.queue_name(source, tenant_id: tenant_id)
          raise Blocked, "Source #{source} is already tenant scoped; supply the legacy source name" if source == target

          options = queue_options(entry: entry, target: target)
          arguments = options[:arguments]
          source_dlx = entry[:source_dlx] || arguments['x-dead-letter-exchange']
          bindings = entry.fetch(:bindings).map { |binding| target_binding(binding: binding, tenant_id: tenant_id) }
          if source_dlx && !source_dlx.to_s.empty?
            source_dlx = legacy_name(name: source_dlx.to_s, tenant_id: tenant_id, resource: :exchange)
            target_dlx = TenantTopology.exchange_name(source_dlx, tenant_id: tenant_id)
            raise Blocked, "Shared DLQ #{source_dlx}.queue cannot be assigned to a single tenant" if source_dlx == target_dlx

            arguments['x-dead-letter-exchange'] = target_dlx
          else
            arguments.delete('x-dead-letter-exchange')
          end
          options[:arguments] = arguments
          plans = [queue_plan(source: source, target: target, options: options, bindings: bindings)]
          if target_dlx
            plans << queue_plan(source: "#{source_dlx}.queue", target: "#{target_dlx}.queue",
                                options: { durable: true, auto_delete: false, exclusive: false, arguments: { 'x-queue-type' => 'classic' } },
                                bindings: [{ exchange: target_dlx, exchange_type: 'fanout', routing_key: '#', arguments: {},
                                             exchange_options: { durable: true, auto_delete: false } }])
          end
          plans
        end

        def queue_options(entry:, target:, **)
          raise ArgumentError, 'Queue options must be a Hash' unless entry.fetch(:options).is_a?(Hash)

          options = { durable: true, auto_delete: false, exclusive: false }.merge(entry.fetch(:options).transform_keys(&:to_sym).slice(*QUEUE_OPTIONS))
          raise Blocked, "Target #{target} cannot be exclusive to the short-lived migration connection" if options[:exclusive]
          raise ArgumentError, 'Queue arguments must be a Hash' unless options[:arguments].nil? || options[:arguments].is_a?(Hash)

          options[:arguments] = snapshot(value: options[:arguments] || {}).transform_keys(&:to_s)
          options
        end

        def queue_plan(source:, target:, options:, bindings:, **)
          { source: source, target: target, options: options, bindings: bindings, status: :planned, moved: 0, remaining: nil, consumers: nil }
        end

        def target_binding(binding:, tenant_id:, **)
          raise ArgumentError, 'Every binding must be a Hash' unless binding.is_a?(Hash)

          entry = binding.transform_keys(&:to_sym)
          name = entry.fetch(:exchange).to_s
          raise ArgumentError, 'Bindings must name a non-default exchange' if name.empty?
          raise ArgumentError, 'Binding exchange_options must be a Hash' unless entry[:exchange_options].nil? || entry[:exchange_options].is_a?(Hash)
          raise ArgumentError, 'Binding arguments must be a Hash' unless entry[:arguments].nil? || entry[:arguments].is_a?(Hash)

          {
            exchange: TenantTopology.exchange_name(name, tenant_id: tenant_id),
            exchange_type: entry.fetch(:exchange_type, 'topic').to_s,
            exchange_options: { durable: true, auto_delete: false }.merge((entry[:exchange_options] || {}).transform_keys(&:to_sym).slice(*EXCHANGE_OPTIONS)),
            routing_key: entry.fetch(:routing_key, ''), arguments: entry[:arguments] || {}
          }
        end

        def lock_sources(session:, plans:, **)
          channel = session.create_channel
          plans.sort_by { |plan| plan[:source] }.each do |plan|
            lock_name = "legion.tenant-migration.lock.#{Digest::SHA256.hexdigest(plan[:source])}"
            channel.queue(lock_name, durable: false, exclusive: true, auto_delete: true, arguments: { 'x-queue-type' => 'classic' })
          rescue Bunny::ResourceLocked => e
            raise Blocked, "Another migration owns source #{plan[:source]}; retry after it finishes (#{e.message})"
          end
        end

        def inspect_sources(session:, plans:, **)
          channel = session.create_channel
          plans.each do |plan|
            state = channel.queue_declare(plan[:source], passive: true)
            plan[:remaining] = state.message_count
            plan[:consumers] = state.consumer_count
            plan[:initial_count] = state.message_count
          rescue StandardError => e
            raise Blocked, "Cannot inspect legacy source #{plan[:source]}; verify the queue exists and is accessible (#{e.class}: #{e.message})"
          end
        end

        def declare_targets(channel:, plans:, **)
          # Declare every DLX and target before moving any message; target consumers may already be active.
          plans.each do |plan|
            plan[:bindings].each do |binding|
              channel.exchange(binding[:exchange], binding[:exchange_options].merge(type: binding[:exchange_type]))
            end
            channel.queue(plan[:target], plan[:options])
            plan[:bindings].each do |binding|
              channel.queue_bind(plan[:target], binding[:exchange], routing_key: binding[:routing_key], arguments: binding[:arguments])
            end
          end
        end

        def transfer_queue(channel:, plan:, result:, transfers:, limits:, **)
          if result[:moved] >= limits[:max_messages]
            plan[:status] = plan[:remaining].zero? ? :completed : :pending
            return
          end

          source_channel = channel.connection.create_channel
          delivery = nil
          transfer = create_transfer_exchange(channel: channel, plan: plan, transfers: transfers)
          loop do
            state = source_channel.queue_declare(plan[:source], passive: true)
            plan[:remaining] = state.message_count
            plan[:consumers] = state.consumer_count
            raise Blocked, "Source #{plan[:source]} acquired active consumers; stop them before retrying" if state.consumer_count.positive?
            break if state.message_count.zero? || result[:moved] >= limits[:max_messages]

            delivery, properties, payload = source_channel.basic_get(plan[:source], manual_ack: true)
            break unless delivery

            plan[:remaining] = nil
            validate_tenant!(headers: properties[:headers] || {}, payload: payload, content_encoding: properties[:content_encoding],
                             tenant_id: result[:tenant_id])
            TenantQuota.check_publish(result[:tenant_id], message_size: payload.bytesize)
            envelope = properties.to_h.merge(routing_key: delivery.routing_key)
            envelope[:headers] = (envelope[:headers] || {}).merge(ORIGINAL_EXCHANGE_HEADER => delivery.exchange)
            confirm_transfer(transfer: transfer, payload: payload, envelope: envelope, deadline: limits[:deadline])

            source_channel.acknowledge(delivery.delivery_tag)
            delivery = nil
            plan[:moved] += 1
            result[:moved] += 1
          end
          plan[:status] = plan[:remaining].zero? ? :completed : :pending
        rescue StandardError => e
          plan[:error] = e.message
          raise
        ensure
          requeue_delivery(channel: source_channel, delivery: delivery, plan: plan) if delivery
        end

        def create_transfer_exchange(channel:, plan:, transfers:, **)
          transfer_name = "legion.tenant-migration.transfer.#{Digest::SHA256.hexdigest(plan[:source])}"
          # A source broker lock excludes other migrations while reclaiming a crashed owner's transfer.
          channel.exchange_delete(transfer_name)
          transfer = channel.fanout(transfer_name, durable: false, auto_delete: true)
          transfers << transfer.name
          channel.queue_bind(plan[:target], transfer.name)
          channel.confirm_select unless channel.using_publisher_confirmations?
          transfer
        end

        def confirm_transfer(transfer:, payload:, envelope:, deadline:, **)
          remaining = deadline - monotonic_now
          raise Pending, 'Migration timed out before target acceptance; retry to resume' unless remaining.positive?

          returned = nil
          transfer.on_return { |info, _properties, _payload| returned = "#{info.reply_code}: #{info.reply_text}" }
          transfer.publish(payload, **envelope, mandatory: true)
          confirmed = Timeout.timeout(remaining) { transfer.channel.wait_for_confirms }
          return if confirmed && returned.nil?

          raise Pending, "Target did not confirm routed acceptance (#{returned || 'broker nack'}); retry to resume"
        end

        def requeue_delivery(channel:, delivery:, plan:, **)
          return unless channel&.open?

          Timeout.timeout(1) do
            channel.reject(delivery.delivery_tag, true)
            # Reject is asynchronous; an immediate passive declaration can still report zero.
            loop do
              remaining = channel.queue_declare(plan[:source], passive: true).message_count
              if remaining.positive?
                plan[:remaining] = remaining
                break
              end
              sleep 0.01
            end
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.tenant_migration.requeue', source: plan[:source])
          plan[:remaining] = nil
          plan[:requeue_error] = "Session teardown will requeue unsettled deliveries: #{e.message}"
        end

        def validate_tenant!(headers:, payload:, content_encoding:, tenant_id:, **)
          identities = headers.filter_map { |key, value| value if TENANT_HEADERS.include?(key.to_s) }
          # Inspect only cleartext JSON identity metadata, never decrypt or rewrite wire bytes.
          if [nil, '', 'identity', 'utf-8'].include?(content_encoding) && payload.match?(/\A[ \t\r\n]*\{/)
            begin
              document = Legion::JSON.load(payload)
            rescue Legion::JSON::ParseError => e
              log.warn "Cannot inspect opaque migration payload metadata (#{e.class}); preserving wire bytes and checking tenant headers"
            end
            identities << document[:tenant_id] if document.is_a?(Hash) && document.key?(:tenant_id)
          end
          conflicts = identities.compact.map(&:to_s).reject { |identity| identity == tenant_id }
          return if conflicts.empty?

          raise Blocked,
                "Source message tenant identity #{conflicts.uniq.inspect} conflicts with requested tenant #{tenant_id}; message remains in the source queue"
        end

        def cleanup_transfers(session:, transfers:, **)
          return unless session&.open?

          Timeout.timeout(1) do
            channel = session.create_channel
            transfers.each { |name| channel.exchange_delete(name) }
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'transport.tenant_migration.cleanup_transfers')
        end

        def error_status(error:, **)
          case error
          when Blocked then :blocked
          when Pending, Timeout::Error, TenantQuota::QuotaExceededError then :pending
          else :failed
          end
        end

        def legacy_name(name:, tenant_id:, resource:, **)
          marker = '__legion_migration_resource__'
          resolved = TenantTopology.public_send("#{resource}_name", marker, tenant_id: tenant_id)
          return name if resolved == marker || (resource == :exchange && TenantTopology.shared?(name))

          prefix, suffix = resolved.split(marker, 2)
          return name unless name.start_with?(prefix) && name.end_with?(suffix) && name.length > prefix.length + suffix.length

          name[prefix.length, name.length - prefix.length - suffix.length]
        end

        def snapshot(value:, **)
          case value
          when Hash then value.to_h { |key, item| [key, snapshot(value: item)] }
          when Array then value.map { |item| snapshot(value: item) }
          when String then value.dup
          else value
          end
        end

        def monotonic_now
          ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
