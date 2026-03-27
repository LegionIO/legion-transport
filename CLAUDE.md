# legion-transport: AMQP Transport Layer for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Ruby gem that manages the connection between LegionIO and its FIFO queue system (RabbitMQ over AMQP 0.9.1). Provides abstractions for exchanges, queues, messages, and consumers with thread-safe connection management.

**GitHub**: https://github.com/LegionIO/legion-transport
**Version**: 1.4.1
**License**: Apache-2.0

## Architecture

```
Legion::Transport
├── Connection          # Thread-safe RabbitMQ session/channel management
│   ├── SSL             # TLS configuration (cert, key, CA, Vault PKI)
│   └── Vault           # Vault-based credential retrieval (stub)
├── InProcess           # Lite mode adapter: stub Session/Channel/Exchange/Queue/Consumer delegating to Local
├── Exchange            # Base exchange class (extends Bunny::Exchange)
│   └── Exchanges/
│       ├── Task        # Task routing exchange
│       ├── Node        # Node communication exchange (infrastructure: swarms, services, heartbeats)
│       ├── Agent       # Agent communication exchange (identity-bound: GAIA frames, preferences, proactive)
│       ├── Crypt       # Encryption exchange
│       ├── Extensions  # Extension exchange
│       ├── Lex         # LEX exchange (inherits Extensions)
│       └── Logging     # Log event exchange (legion.logging) for structured log event publishing
├── Queue               # Base queue class (extends Bunny::Queue)
│   └── Queues/
│       ├── Node        # Node queue
│       ├── Agent       # Per-agent queue (auto-delete, routing key: agent.<agent_id>)
│       ├── NodeCrypt   # Node encryption queue
│       ├── NodeStatus  # Node status queue
│       ├── TaskLog         # Task logging queue
│       ├── TaskUpdate      # Task update queue
│       └── RegionOutbound  # Cross-region outbound queue for mesh routing
├── Message             # Base message class with publish, encode, encrypt
│   └── Messages/
│       ├── Task        # Task messages with dynamic routing keys
│       ├── SubTask     # Subtask messages (conditions, transforms)
│       ├── Dynamic     # Dynamic function-based messages
│       ├── CheckSubtask
│       ├── LexRegister
│       ├── RequestClusterSecret
│       ├── TaskLog
│       └── TaskUpdate
├── Consumer            # AMQP consumer with auto-generated tags
├── Common              # Shared utilities (channel mgmt, options merging, consumer tags)
├── Helper              # Injectable transport mixin for LEX extensions
├── Local               # In-memory pub/sub for local development mode (no RabbitMQ)
├── Spool               # Disk-backed message buffer: persist messages when RabbitMQ unavailable, replay on reconnect
├── TenantProvisioner   # Creates per-tenant exchanges + queues on first publish; idempotent with TTL cache
├── TenantQuota         # Per-tenant rate limiting and message quota enforcement
├── TenantTopology      # Tracks per-tenant exchange/queue topology (discovery, cleanup)
├── Settings            # Default configuration with env var overrides
└── Version             # 1.4.1
```

## Key Design Patterns

### Force Reconnect

`Connection.force_reconnect` performs a socket-first teardown (closes the underlying TCP socket before calling `Bunny::Session#close`) to break stuck connections that don't respond to the normal close protocol. Tracks recovery rate over a 5-window/60s sliding window. Calls registered `on_force_reconnect` callbacks after reconnection. Sets a shutdown flag to prevent reconnection loops during intentional shutdown.

```ruby
Legion::Transport::Connection.force_reconnect
Legion::Transport::Connection.on_force_reconnect { |info| alert_on_call(info) }
```

### AMQP Client / Lite Mode
Uses `bunny` gem for AMQP 0.9.1. The entry point sets `Legion::Transport::TYPE` and `Legion::Transport::CONNECTOR` as constants. When `LEGION_MODE=lite` env var is set, `TYPE = 'local'` and `CONNECTOR = InProcess` instead of Bunny. `Connection.lite_mode?` checks `TYPE == 'local'`. `Connection.setup` returns an InProcess session in lite mode, skipping Bunny entirely.

### Thread-Safe Connection Management
- `Concurrent::AtomicReference` wraps the AMQP session (one per process)
- `Concurrent::ThreadLocalVar` provides per-thread channels
- Auto-recovery on blocked/unblocked/recovery events

### Options Merging
`Common#options_builder` deep-merges default options -> class options -> instance options. Used by both Exchange and Queue constructors.

### Auto-Recreate on Mismatch
Both Exchange and Queue classes catch `PreconditionFailed` errors (parameter mismatch with existing RabbitMQ declarations) and attempt to delete + recreate once before raising.

## Dependencies

| Gem | Purpose |
|-----|---------|
| `bunny` (>= 2.23) | CRuby AMQP client |
| `concurrent-ruby` (>= 1.2) | Thread-safe data structures |
| `legion-json` | JSON serialization |
| `legion-settings` | Configuration management |

Optional runtime dependencies:
- `legion-crypt` - Message encryption support
- `legion-data` - Database models (used by Dynamic/SubTask messages)
- `legion-logging` - Structured logging

## Configuration

Settings are loaded via `Legion::Transport::Settings` with env var overrides:

| Env Var | Default | Description |
|---------|---------|-------------|
| `transport.connection.host` | `127.0.0.1` | RabbitMQ host |
| `transport.connection.port` | `5672` | RabbitMQ port |
| `transport.connection.user` | `guest` | RabbitMQ user |
| `transport.connection.password` | `guest` | RabbitMQ password |
| `transport.connection.vhost` | `/` | RabbitMQ vhost |
| `transport.prefetch` | `2` | Consumer prefetch count |
| `transport.messages.encrypt` | `false` | Enable message encryption |
| `transport.messages.ttl` | `nil` | Message TTL |
| `transport.messages.persistent` | `true` | Persistent messages |

Vault integration: RabbitMQ credentials are managed by the LeaseManager via `lease://rabbitmq#username` / `lease://rabbitmq#password` URI references in transport settings. The lease path (e.g., `rabbitmq/creds/agent`) is configured in `crypt.vault.leases.rabbitmq.path`.

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/transport.rb` | Entry point, connector detection (Bunny vs InProcess), logger/settings |
| `lib/legion/transport/connection.rb` | Session/channel lifecycle (setup, reconnect, shutdown, lite_mode?) |
| `lib/legion/transport/connection/ssl.rb` | TLS settings module |
| `lib/legion/transport/connection/vault.rb` | Vault PKI integration (stub) |
| `lib/legion/transport/in_process.rb` | Lite mode adapter: stub Session, Channel, Exchange, Queue, Consumer |
| `lib/legion/transport/common.rb` | Shared module (channel access, deep_merge, consumer tags) |
| `lib/legion/transport/helper.rb` | Injectable transport mixin for LEX extensions |
| `lib/legion/transport/exchange.rb` | Base Exchange class |
| `lib/legion/transport/exchanges/agent.rb` | Agent exchange for identity-bound communication |
| `lib/legion/transport/queue.rb` | Base Queue class |
| `lib/legion/transport/queues/agent.rb` | Per-agent queue (auto-delete, keyed by agent_id) |
| `lib/legion/transport/message.rb` | Base Message class with publish/encode/encrypt |
| `lib/legion/transport/consumer.rb` | AMQP consumer wrapper |
| `lib/legion/transport/spool.rb` | Disk-backed message buffer (~/.legionio/spool, 10MB/file, 500MB total, 3-day TTL) |
| `lib/legion/transport/tenant_provisioner.rb` | Per-tenant exchange/queue creation with TTL idempotency cache |
| `lib/legion/transport/tenant_quota.rb` | Per-tenant rate limiting and message quota enforcement |
| `lib/legion/transport/tenant_topology.rb` | Per-tenant topology tracking (discovery, cleanup) |
| `lib/legion/transport/queues/region_outbound.rb` | Cross-region outbound queue for mesh routing |
| `lib/legion/transport/settings.rb` | Default config, env var loading, host resolution |
| `lib/legion/transport/version.rb` | Version constant |
| `spec/` | RSpec test suite |

## Node vs Agent Exchange

Two identity-scoped exchanges separate infrastructure traffic from agent-bound traffic:

| Exchange | Routing Key Pattern | Use Case |
|----------|-------------------|----------|
| `node` | `node.<fqdn/nodename>` | Infrastructure: swarm coordination, service heartbeats, non-identity traffic |
| `agent` | `agent.<agent_id>` | Identity-bound: GAIA cognitive frames, preference queries, proactive messages |

**Agent queue defaults** differ from standard queues:
- `durable: false` — agent queues are ephemeral (recreated on connect)
- `auto_delete: true` — cleaned up when the agent disconnects
- Dead letter exchange: `agent.dlx`
- Agent ID defaults to `Legion::Settings['client']['name']` if not provided

The `agent` exchange is used by `legion-gaia` for inbound cognitive frames (replacing the former `gaia` exchange routing) and by `lex-mesh` for async preference queries via `reply_to` + `correlation_id` RPC.

## Queue Defaults

All queues are created with:
- `durable: true` - survives broker restart
- `manual_ack: true` - explicit acknowledgment required
- `x-max-priority: 255` - priority queue support
- `x-overflow: reject-publish` - rejects new messages when full
- Dead letter exchange: `<exchange>.dlx`

## Exchange Defaults

All exchanges are created as:
- `type: topic` - supports routing key pattern matching
- `durable: true` - survives broker restart
- `auto_delete: false` - persists when no queues bound

## Testing

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

Spec count: 448+ examples (force_reconnect, recovery tracking, tenant provisioner specs added in v1.4.x)

---

**Maintained By**: Matthew Iverson (@Esity)
