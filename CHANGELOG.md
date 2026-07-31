# Legion::Transport ChangeLog

## [Unreleased]

## [1.4.30] - 2026-07-31

### Fixed
- Fixed DLX recovery loop (`Bunny::ChannelAlreadyClosed` on `legion.*.dlx` exchanges and queues). The `declare_dlx` method recorded DLX topology on a short-lived channel that was immediately closed after declaration; Bunny's automatic recovery then repeatedly attempted to re-declare on the dead channel, looping forever. Now uses `exchange_declare_without_recording_topology` and `queue_declare_without_recording_topology` so the DLX (durable on the server) is not tracked for client-side recovery. Also added explicit `ChannelAlreadyClosed` handling in `ensure_dlx` and `recreate_dlx` to fail once with context instead of looping.

## [1.4.29] - 2026-05-22

### Added
- `Message#headers` now emits best-effort `x-legion-version` when `Legion::VERSION` is loaded, alongside the existing `legion_protocol_version` protocol marker.

## [1.4.28] - 2026-05-17

### Fixed
- Fixed sweep closing channels that still have active Bunny consumers: subscription actors are instantiated on pool threads that subsequently die, but the channel is handed off to Bunny's `ConsumerWorkPool`. The sweep now checks `channel.consumers` and skips channels with registered consumers.

## [1.4.27] - 2026-05-17

### Fixed
- Fixed race condition in channel registry iteration: `sweep_dead_thread_channels` and `close_all_tracked_channels` used `.each` on the live hash while parallel boot threads (`hook_subscription_actors_pooled`) concurrently called `track_channel`, raising `"can't add a new key into hash during iteration"` on Ruby 3.4. Replaced with `.keys.each` which snapshots the key list into an Array before iterating.

## [1.4.26] - 2026-05-16

### Fixed
- Fixed channel leak caused by concurrent-ruby's IO-pool thread lifecycle: `TimerTask` (used by `Every` actors) dispatches onto `global_io_executor` threads that idle-timeout after 60s; thread-local Bunny channels were never closed when those threads died, eventually exhausting RabbitMQ's `channel_max` (1024). Added a `@channel_registry` that tracks publisher channels by owning thread and sweeps orphaned channels from dead threads before creating new ones.
- `Connection.shutdown` now explicitly closes all tracked publisher channels before tearing down the session.
- `Connection.force_reconnect` resets the channel registry to prevent stale references after reconnection.

## [1.4.25] - 2026-05-15

### Added
- `Message#identity_headers` now emits `x-legion-identity-db-principal-id` and `x-legion-identity-db-identity-id` as integer AMQP headers when non-nil, enabling downstream consumers (e.g. legion-apollo `inject_identity_context`) to use the DB primary keys without string parsing. Nil values are omitted.

## [1.4.24] - 2026-05-11

### Fixed
- `TenantProvisioner#provision` and `#deprovision` now use `Legion::Transport::Connection.channel` (the public API) instead of the non-existent `Legion::Transport.connection.create_channel`. (Closes #15)
- `TenantProvisioner` now wraps internally-acquired channels in `ensure` blocks so channels are closed even when provision/deprovision raises. (Closes #15)
- `TenantProvisioner#deprovision` now guards against accidental deletion of global exchanges: skips when topology is disabled, and refuses to delete when `tenant_id` is nil, blank, or `'default'`. (Closes #15)
- `TenantTopology#shared?` no longer over-matches: previously `start_with?('legion.')` matched `legion.controlled`; now uses exact set membership with explicit dot-separated sub-path check (`name == entry || name.start_with?("#{entry}.")`). (Closes #15)
- `TenantTopology` now reads `shared_exchanges` and `prefix_format` from `transport.tenant_topology` settings with sensible defaults, instead of hardcoding them. (Closes #15)
- `TenantQuota` now uses per-tenant mutexes instead of a single global mutex, and sweeps stale counter entries (entries inactive for `STALE_SECONDS = 300`) to prevent unbounded map growth. (Closes #15)
- DLX exchange declarations now use an isolated channel to prevent cascading failures
- Added self-healing delete-and-recreate logic for mismatched DLX exchanges (PreconditionFailed)
- Added `exclusive: true` to Node and Agent queues for RabbitMQ 4.x compatibility (transient_nonexcl_queues deprecation)
- Fixed `topology_mode?` to check `worker?` instead of `agent?` for exchange/queue declarations


## [1.4.23] - 2026-05-05

### Added
- `Message#publish` now supports live-request reliability options: `mandatory: true`, `publisher_confirm: true`, `publish_confirm_timeout_ms:`, `spool: false`, and structured publish results with `:accepted`, `:unroutable`, `:nacked`, `:confirm_timeout`, `:spooled`, or `:failed` status.
- Structured publish result hash: `{ status:, accepted:, exchange:, routing_key:, message_id:, correlation_id:, return_reply_code:, return_reply_text: }` returned when any reliability option is active.
- `reply_to:` field included in AMQP envelope options for RPC-style request/reply patterns.
- `routing_key:` override in publish options allows callers to redirect a message at publish time without constructing a new message instance.
- `persistent:` can now be overridden per-publish via options (previously only set at message construction).

### Changed
- `Message#publish` signature changed from `publish(options = @options)` to `publish(options = nil)` — passed options now **merge** with default `@options` instead of replacing them outright. Existing callers passing no arguments are unaffected.

## [1.4.22] - 2026-04-24

### Added
- `x-legion-identity-trust` header on AMQP messages alongside existing `x-legion-identity-canonical-name`

## [1.4.21] - 2026-04-17

### Fixed
- `Message#expiration` now falls back to `:ttl` from transport message settings, so the `transport.messages.ttl` setting is honored at publish time. (Fixes #20)
- `Messages::SubTask#validate` now accepts `function_id: Integer` as an alternative to `function: String`, matching the actual routing paths available in `routing_key`. (Fixes #20)
- `Messages::TaskUpdate#validate` now enforces that `task_id` is a positive Integer and `status` is one of the declared valid statuses, raising `InvalidTaskId`/`InvalidTaskStatus` respectively instead of silently passing invalid payloads. (Fixes #20)
- `/api/transport/publish` now uses `Messages::Direct` (a new generic message class) instead of `Messages::Dynamic`, which required `function_id` and `Legion::Data`. The new class publishes to any arbitrary exchange + routing key. (Fixes #20)
- `Spool.write` now accepts and persists envelope metadata (`headers`, `priority`, `message_id`, `correlation_id`, `persistent`). `Message#spool_message` passes these fields through so replayed messages can reconstruct the original AMQP publish. (Fixes #19)
- `Spool.evict_oldest` now evicts files when `max_total_bytes` is exceeded, not only when `max_files` is exceeded. Previously the total-bytes limit was checked in `over_limits?` but never acted on in the eviction loop. (Fixes #19)
- `Spool.count` and `Spool.drain` now stream files line-by-line via `File.foreach` instead of loading entire files with `File.readlines`. (Fixes #19)

### Added
- `Messages::Direct` — generic publish message that accepts an arbitrary exchange name and routing key without requiring `Legion::Data` or a `function_id`. Used by the `/api/transport/publish` route.

## [1.4.20] - 2026-04-17

### Fixed
- `Connection.channel` now raises `IOError` when the session is nil (during `force_reconnect` teardown) or not open (during Bunny automatic recovery). Both cases previously surfaced as unhandled `NoMethodError`/`RuntimeError` that bypassed `Message#publish`'s spool rescue. Messages are now spooled cleanly during the entire recovery window. (Fixes #27)
- `Connection.shutdown` now calls `pre_mark_sessions_closing` at the top of teardown, disabling Bunny auto-recovery on the primary session, log channel session, and build session before Vault can revoke the RabbitMQ credential. This stops the spurious reconnect loop when shutting down with Vault-managed credentials. (Fixes #28)

## [1.4.18] - 2026-04-13

### Added
- `Queue#nack_or_dlq(delivery_tag, retry_count:, threshold:)` — convenience helper: rejects with `requeue: true` when `retry_count < threshold`, dead-letters with `requeue: false` otherwise
- `engine:` field in `SubTask#message` — included when provided, omitted via `.compact` when absent; enables fleet pipeline engine propagation through the task chain

## [1.4.16] - 2026-04-07

### Added
- `Exchange#passive?` — mode-aware passive declare: returns false when `dynamic_rmq_creds` is disabled (default), true during bootstrap phase, false for infra/agent after identity resolves, true for worker mode (credential scoping phase 5)
- `Queue#passive?` — same mode-aware logic for queues, with worker own-queue exception (workers actively declare their own queues)
- `Queue#own_queue?` — checks `Identity::Process.queue_prefix` to determine if a queue belongs to this process; workers can actively declare own queues but passively assert shared queues
- `Exchange#credential_scoping_enabled?`, `Exchange#bootstrap_phase?`, `Exchange#topology_mode?` — private helpers with `defined?` guards for optional dependencies
- `Queue#credential_scoping_enabled?`, `Queue#bootstrap_phase?`, `Queue#topology_mode?` — same private helpers on Queue
- Passive declare strips queue arguments (`x-dead-letter-exchange`, `x-queue-type`) to avoid `PreconditionFailed` on argument mismatch
- `ensure_dlx` skips DLX creation when `credential_scoping_enabled? && (bootstrap_phase? || !topology_mode?)` — only infra/agent create shared DLX topology
- `PreconditionFailed` guard on Exchange and Queue: worker and bootstrap modes raise instead of deleting and recreating shared topology

## [1.4.15] - 2026-04-06

### Added
- Layered TTL resolution in Helper (`transport_default_ttl` — LEX-overridable, reads Settings)
- `transport_session_open?` / `transport_channel_open?` / `transport_lite_mode?` — real connection status
- `transport_channel` — convenience accessor for the current thread's AMQP channel
- `transport_spool_count` — pending spooled message count for degraded-mode awareness
- `transport_publish` — convenience method to publish to default exchange with auto TTL and JSON encoding
- AMQP identity headers: `Message#headers` injects `x-legion-identity-{canonical-name,id,kind,mode,source}` from `Identity::Process` when resolved (Wire Format Phase 3)
- `identity_process_resolved?` and `identity_headers` private helpers extracted from `inject_identity_headers` for testability

## [1.4.14] - 2026-04-03

### Fixed
- `build_bunny_opts` single-host branch overwrote user-configured host with stale `resolved_hosts` default (`127.0.0.1`), causing AMQP auth failures against the wrong broker

## [1.4.13] - 2026-04-02

### Added
- Runtime `legion-logging` dependency for transport logging helpers and exception handling
- Helper-based logging and `handle_exception` coverage across transport connection, queue, message, spool, Kafka, and tenant internals

### Changed
- Transport defaults now fall back to `warn` log level unless explicitly overridden
- Added more `info`-level operational logging for connection lifecycle, pool usage, spool activity, tenant topology, quorum policy, and Kafka actions

### Fixed
- `Transport.logger` now honors `transport.log_level` while still supporting legacy `transport.logger_level`
- Connection setup now recreates closed sessions, normalizes single-host `host:port` values, starts pooled sessions before use, and serializes forced reconnects
- Session teardown now marks sessions as intentionally closing before close attempts, reducing recovery interference during shutdown
- Region header injection now skips `Legion::Region.current` lookups when affinity is `any` and no explicit region is configured

## [1.4.12] - 2026-03-30

### Fixed
- `Transport.logger` now delegates to `Legion::Logging` when it is defined and responds to `:warn`, falling back to a stdlib `::Logger` only when Legion::Logging is unavailable

## [1.4.11] - 2026-03-30

### Fixed
- Close throwaway QoS channel after `basic_qos` in `Connection.setup` and `setup_pool` — previously leaked on every setup/reconnect cycle (closes #10)
- Close old `@log_channel` before replacing in `Connection.setup` and `log_channel` accessor — previously leaked on every reconnect
- Close old `@channel` before retry in `Exchange#initialize` rescue path — previously leaked on `PreconditionFailed`/`ChannelAlreadyClosed`
- Close old `@channel` before replacing in `Exchange#channel` rescue path — previously leaked on `ChannelLevelException`
- Close old `@channel` before replacing in `Queue#initialize` rescue path — previously leaked on `PreconditionFailed`

## [1.4.10] - 2026-03-30

### Fixed
- `Queue#queue_name`, `Queue#dlx_exchange_name`, `Exchange#exchange_name`, and `Message#exchange_name` now use boundary-walking namespace derivation instead of hard-coded positional indices, fixing broken name generation for nested sub-module extensions (closes #8)

### Added
- `Common::NAMESPACE_BOUNDARIES` constant defining module names that delimit extension segments from transport internals
- `Common#derive_segments` / `Common#derive_extension_parts` / `Common#derive_leaf` private helpers for namespace-aware name derivation
- `Common#camelize_to_snake` private helper for CamelCase to snake_case conversion with acronym support

## [1.4.8] - 2026-03-28

### Added
- `Legion::Transport::Kafka` optional adapter for event streaming alongside RabbitMQ (closes #4)
- `Kafka::Producer` — thread-safe rdkafka producer with lazy init, JSON auto-encoding, partition key, header forwarding, and delivery confirmation
- `Kafka::Consumer` — subscribe to topics with consumer group semantics; replay from offset or timestamp via isolated replay group
- `Kafka::Admin` — idempotent `ensure_topic` (create or confirm-exists) via rdkafka admin client
- `Kafka::IncomingMessage` — clean wrapper over raw rdkafka messages exposing topic/partition/offset/key/headers/timestamp/payload with `decoded_payload` JSON parse helper
- `Kafka::DEFAULTS` — full default config hash covering producer, consumer, admin, and security (SASL/SSL) settings; all values env-var overridable under `transport.kafka.*` namespace
- `Legion::Transport::Settings.kafka` — merges Kafka defaults into the transport settings hash; `transport.kafka.enabled: false` by default
- Feature-flagged: Kafka is opt-in (`transport.kafka.enabled: true` or `ENV['transport.kafka.enabled'] = 'true'`); `rdkafka` gem is a soft optional dependency not listed in gemspec
- 56 new specs covering the Kafka module, Producer, IncomingMessage, and DEFAULTS (all rdkafka interaction mocked — no broker required)

## [1.4.7] - 2026-03-28

### Added
- `Legion::Transport::Routes` self-registering Sinatra route module (`lib/legion/transport/routes.rb`): extracts all `/api/transport/*` route handlers from LegionIO. Self-registers with `Legion::API.register_library_routes('transport', Routes)` during boot. Includes fallback helpers for standalone mounting.

## [1.4.6] - 2026-03-27

### Fixed
- `create_dedicated_session` in lite mode now returns the shared `InProcess::Session` (if open) rather than creating a new one, preventing `Session#close` from inadvertently resetting process-global in-memory queue state
- README "Full Default Settings" JSON corrected: `port` is now an integer (`5672`) matching the actual integer type in `Settings.connection`
- README "Dedicated Sessions" section updated to clarify that lite-mode sessions share process-global in-process transport and are not isolated from other sessions

### Changed
- `spec/legion/transport/connection_lite_spec.rb` now explicitly requires `legion/transport/in_process` to ensure `InProcess::Session` is always loaded regardless of `LEGION_MODE` env var or spec execution order

## [1.4.5] - 2026-03-27

### Added
- `Connection.create_dedicated_session` class method for creating isolated AMQP connections separate from the main transport session; returns an `InProcess::Session` in lite mode

## [1.4.4] - 2026-03-26

### Removed
- `grab_vault_creds` legacy method from `Settings` — RabbitMQ credentials are now exclusively managed by the LeaseManager via `lease://rabbitmq#username` / `lease://rabbitmq#password` URI references. The removed method hardcoded the wrong Vault path (`rabbitmq/creds/legion` instead of `rabbitmq/creds/agent`).

## [1.4.3] - 2026-03-26

### Added
- `dlx_enabled` opt-out method for queue DLX creation
- `dlx_exchange_name` method for per-LEX DLX naming
- Per-LEX DLX queue declaration in `ensure_dlx`

## [1.4.2] - 2026-03-26

### Fixed
- register `after_recovery_attempts_exhausted` callback to trigger `force_reconnect` when Bunny exhausts all recovery attempts, preventing process hang requiring `kill -9`

## [1.4.1] - 2026-03-25

### Added
- `Legion::Transport::PayloadTooLarge` error class
- `max_payload_bytes` setting (default 1,048,576 bytes / 1MB), overridable via `transport.max_payload_bytes` env var
- `Message.max_payload_bytes` class method returns the configured limit with fallback to 1MB
- `Message#validate_payload_size` private method: checks serialized payload `bytesize` against limit and raises `PayloadTooLarge` before any AMQP interaction

## [1.4.0] - 2026-03-25

### Added
- `Connection.force_reconnect`: full session replacement when pathological recovery loop detected (closes #1)
- `Connection.on_force_reconnect(&block)`: register callbacks invoked after force reconnect
- Recovery rate tracking: sliding window (`RECOVERY_WINDOW = 60s`, `MAX_RECOVERIES_PER_WINDOW = 5`) triggers `force_reconnect` automatically
- `Connection#tear_down_session`: socket-first teardown (breaks IO.select in reader threads), orderly close with 3s timeout, thread kill as last resort
- `Connection#kill_reader_threads`: forcibly terminates stuck Bunny reader loop threads
- `Connection.shutdown` sets `@shutting_down` flag to prevent `force_reconnect` during teardown

### Fixed
- Fix exchange instance cache inheritance: subclasses now correctly read from parent's @instance_cache, preventing boot crash
- Fix Connection#session: add missing `return` so nil check works correctly
- Fix infinite recovery loop on network interface change: Bunny recovery cycles endlessly when the underlying NIC changes; now detected and broken via force reconnect
- Fix shutdown hang when Bunny is mid-recovery: `tear_down_session` disables recovery flag, closes transport socket first, and kills reader threads on timeout
- Message#publish: use `cached_instance` when available to reuse the exchange instance cache instead of always calling `.new`
- Message#publish: rescue `Timeout::Error` alongside other network errors so timeouts also spool

### Changed
- Bump read_timeout from 1 to 3 seconds
- Bump continuation_timeout from 4000 to 8000 milliseconds
- Bump session_worker_pool_size from 8 to 16

## [1.3.14] - 2026-03-24

### Fixed
- CI workflow: pass `needs-rabbitmq: true` to shared CI workflow so RabbitMQ service container starts for specs

## [1.3.13] - 2026-03-24

### Added
- `Connection.open_build_session` / `close_build_session`: disposable parallel AMQP session for extension loading; `Thread.current[:legion_build_session]` flag routes channel calls to build session
- `Connection.log_channel`: dedicated `@log_channel` on the main session for log-event publishing; auto-recovers if channel closes
- `Exchange#initialize`: accepts `channel:` option to use an explicit channel instead of the shared pool channel
- `Transport::Connection::Vault` module: Vault PKI TLS options via `#vault_pki_tls_options`; writes cert/key/CA chain to tempfiles for Bunny mTLS connections

### Changed
- `Transport::Connection` now includes `Connection::Vault` and merges PKI TLS options into Bunny opts when `transport.tls.vault_pki: true` and `security.mtls.enabled: true`

## [1.3.12] - 2026-03-24

### Added
- Connection pool activated when `connection_pool_size > 1` (default: 1 — single session, no behavior change)
- `Connection.setup_pool` private method: creates `Helpers::Pool` and checks out primary session
- `Connection.channel` uses pool for channel creation when pool is active
- `Connection.shutdown` drains pool if active

### Fixed
- Agent queue explicitly declares `x-queue-type: classic` (quorum queues require durability; auto-delete agent queues must use classic type)

## [1.3.11] - 2026-03-24

### Changed
- Reindex docs: update CLAUDE.md and README with InProcess adapter and Helper mixin docs

## [1.3.10] - 2026-03-24

### Added
- `Legion::Transport::InProcess` adapter module for lite mode: stub Session, Channel, Exchange, Queue, Consumer classes that mirror the Bunny API but delegate to Transport::Local in-memory pub/sub
- Conditional CONNECTOR selection: `LEGION_MODE=lite` env var loads InProcess instead of Bunny
- `Connection.lite_mode?` class method checks `TYPE == 'local'`
- `Connection.setup` returns InProcess session in lite mode, skipping Bunny entirely
- `Connection.shutdown` handles lite mode with simple session close

## [1.3.9] - 2026-03-22

### Added
- `Legion::Transport::Helper` mixin module with transport convenience methods for LEX extensions (transport_path, transport_class, messages, queues, exchanges, default_exchange, transport_connected?)

## [1.3.8] - 2026-03-22

### Fixed
- Shutdown no longer hangs when Bunny is mid-recovery: disable auto-recovery flag, close with 5s timeout, force-close transport socket on timeout
- Reduce default `recovery_attempts` from 100 to 10 (20s max retry vs 200s); configurable via `transport.connection.recovery_attempts` env var

## [1.3.7] - 2026-03-22

### Changed
- Updated gemspec dependency version constraints: `legion-json >= 1.2.0`, `legion-settings >= 1.3.12`

## [1.3.6] - 2026-03-22

### Changed
- Added `Legion::Logging` calls (guarded with `defined?`) to all previously silent rescue blocks
- `connection/ssl.rb`: debug log on `tls_settings` and `transport_port` failures
- `connection.rb`: debug log on `channel_open?` and `session_open?` failures; warn log on `apply_quorum_policy_if_enabled` failure
- `exchange.rb`: warn log on `delete` precondition failure
- `helpers/channel_pool.rb`: debug log on channel close failure in `close_all`
- `helpers/pool.rb`: debug log on connection close failure in `shutdown`
- `message.rb`: debug log on region header lookup failure; warn log on `exchange_name_for_spool` failure
- `queue.rb`: warn log on `delete` precondition failure
- `settings.rb`: use `Legion::Logging.warn` (with stdlib `warn` fallback) for settings merge failure
- `spool.rb`: debug logs on file read/delete/size failures in `count`, `evict_stale`, `over_limits?`, `evict_oldest`
- `tenant_provisioner.rb`: debug log on exchange delete failure in `deprovision`
- `tenant_quota.rb`: debug log on quota settings lookup failure
- `tenant_topology.rb`: debug logs on `current_tenant_id` and `transport_settings` failures
- `transport.rb`: stdlib `warn` on logger level lookup failure (Logging not yet available at that point)

## [1.3.5] - 2026-03-22

### Changed
- Boot connection log now includes username and vhost: `amqp://user@host:port/vhost`

## [1.3.4] - 2026-03-22

### Added
- Comprehensive logging across transport operations using `Legion::Logging` (guarded with `defined?`)
- `connection.rb`: `.info` on successful connect (host:port), `.info` on shutdown, `.debug` on per-thread channel creation
- `consumer.rb`: `.info` on subscribe with queue name and consumer tag
- `message.rb`: `.debug` on successful publish (exchange, routing_key, class), `.debug` when encryption is applied
- `messages/task.rb`: `.debug` on routing_key derivation
- `messages/subtask.rb`: `.debug` on routing_key derivation with function_id
- `messages/dynamic.rb`: `.debug` on routing_key/function_id derivation
- `local.rb`: `.info` on setup and shutdown, `.debug` on publish and subscribe
- `helpers/pool.rb`: `.warn` on pool timeout, `.debug` on checkout/checkin with pool state
- `helpers/channel_pool.rb`: `.debug` on channel borrow/return with pool state, `.info` on close_all
- `tenant_provisioner.rb`: `.info` on provision/deprovision success, `.warn` on failure
- `tenant_quota.rb`: `.warn` before raising quota exceeded errors (message rate and byte rate)

## [1.3.3] - 2026-03-22

### Added
- TLS/mTLS direct-settings path in `Connection::SSL#tls_options`: reads `transport.tls`, `transport.tls_ca_cert`, `transport.tls_client_cert`, `transport.tls_client_key`, and `transport.verify_peer` from Legion::Settings when `Legion::Crypt::TLS` is not available
- `verify_peer` defaults to `true` when not explicitly set to `false`
- Logging via `Legion::Logging.info '[Transport] TLS enabled for RabbitMQ connection'` (guarded with `defined?`) when TLS is configured via either path
- 7 new specs covering direct-settings TLS path (358 total, 0 failures)

## [1.3.2] - 2026-03-21

### Added
- `Legion::Transport::Exchanges::Logging`: topic exchange (`legion.logging`) for structured log event publishing
- `Legion::Transport::Queues::RegionOutbound`: durable outbound queues for cross-region message routing (per-peer, skips current region)
- `Legion::Transport::Messages::RegionReRoute`: re-route message type for forwarding tasks to target regions

## [1.3.0] - 2026-03-21

### Added
- RabbitMQ cluster support: `cluster_nodes`, `connection_pool_size`, `region`, `management_port`, `quorum_queue_policy` settings
- Cluster node rotation: `cluster_nodes` merged into `resolved_hosts` with shuffle for load distribution
- Connection pool (`Helpers::Pool`): mutex-protected pool of Bunny sessions with configurable size and timeout
- Channel pool (`Helpers::ChannelPool`): per-connection ring buffer of channels with borrow/return
- Region header injection: `x-legion-region` and `x-legion-region-affinity` headers on published messages when region is configured
- Quorum queue policy helper (`Helpers::Policy`): idempotent HTTP PUT to RabbitMQ Management API, opt-in via `quorum_queue_policy.enabled`
- Connection failover: retry loop across all cluster nodes on TCPConnectionFailed/AuthFailure/ECONNREFUSED
- `Legion::Transport::PoolTimeout` and `Legion::Transport::ClusterUnavailable` error classes

### Changed
- `connection_timeout` default 1 -> 10, `network_recovery_interval` default 1 -> 2
- `build_bunny_opts` now merges `cluster_nodes` into resolved hosts before building Bunny options

## [1.2.9] - 2026-03-21

### Changed
- `Connection::SSL` module refactored to use `Legion::Crypt::TLS.resolve` for TLS configuration
- Removed legacy `use_tls?`, `tls_cert`, `tls_key`, `ca_certs`, `verify_peer?` methods
- TLS options now merged into Bunny connection opts via `tls_options` method
- SSL module auto-required and included in `Connection` class

## [1.2.8] - 2026-03-21

### Added
- `TenantTopology` module: exchange/queue name prefixing with tenant context (`t.<tenant_id>.<name>`); disabled by default; shared exchanges (`legion.control`, `legion.health`, `legion.audit`) are never prefixed; delegates to `Legion::TenantContext.current_tenant_id` when no explicit tenant_id given
- `TenantProvisioner` module: provisions and deprovisions RabbitMQ topology (topic exchanges for tasks/results/events + fanout DLX) for a given tenant; accepts optional channel kwarg for reuse
- `TenantQuota` module: application-level sliding-window rate limiting per tenant; enforces `messages_per_second` and `bytes_per_second` limits from settings; raises `TenantQuota::QuotaExceededError` on violation
- `Settings.tenant_topology` defaults block: `enabled: false`, `prefix_format`, `shared_exchanges`, `auto_provision: true`, `quotas: {}`
- 61 new specs covering all three modules (227 total, 0 failures)

## [1.2.7] - 2026-03-20

### Added
- `legion_protocol_version: '2.0'` header on all published AMQP messages

## [1.2.6] - 2026-03-20

### Changed
- Version bump to trigger CI rebuild

## [1.2.5] - 2026-03-20

### Added
- `Settings.resolve_hosts` — merges `host:`, `hosts:`, `server:`, `servers:` into a unified deduped list with default AMQP port (5672) injected where missing
- `Settings::DEFAULT_AMQP_PORT` constant (5672)
- Multi-host RabbitMQ cluster failover via Bunny's native `hosts:` parameter when 2+ hosts configured
- Support for `server:` and `servers:` keys in transport settings (consistency with legion-cache)

### Fixed
- Port default changed from string `"5672"` to integer `5672` — fixes SSL auto-detect comparison in `Connection::SSL.use_tls?` which compared against integer `5671`
- SSL port auto-detect now uses `.to_i` for robustness

## [1.2.4] - 2026-03-20

### Fixed
- Add `logger` gem as runtime dependency for Ruby 4.0 compatibility (extracted from stdlib)
- Disable DNS bootstrap in test environment to prevent `NameError` from legion-settings 1.3.5

## [1.2.3] - 2026-03-19

### Added
- `Legion::Transport::Spool` JSONL disk buffer for offline message persistence when AMQP is unavailable
- Automatic spool intercept on `Message#publish` Bunny connection errors with configurable limits
- Spool drain reads oldest-first with file rotation and stale eviction (72hr TTL, 10MB/file, 500MB total, 100 files max)

## [1.2.2] - 2026-03-17

### Added
- `Exchanges::Agent` topic exchange for identity-bound agent communication
- `Queues::Agent` per-agent queue (`agent.<agent_id>`) with auto-delete lifecycle
- Agent exchange separates identity-scoped traffic from infrastructure node traffic

## [1.2.1] - 2026-03-16

### Added
- `Legion::Transport::Local` in-memory pub/sub for local development mode (no RabbitMQ required)

### Changed
- Specs for all previously untested messages/, queues/, and exchanges/ subdirectories
- Coverage for 18 source files: 7 messages, 5 queues, 4 exchanges (plus task message)
- Line coverage increased from 65.9% to 81.64%

## v1.2.0
Moving from BitBucket to GitHub. All git history is reset from this point on
