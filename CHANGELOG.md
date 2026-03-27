# Legion::Transport ChangeLog

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
