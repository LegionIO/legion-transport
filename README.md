# Legion::Transport

Legion::Transport is the Ruby gem responsible for connecting LegionIO to its FIFO queue system (RabbitMQ over AMQP 0.9.1). It provides thread-safe connection management, exchange/queue abstractions, message publishing with optional encryption, and consumer wrappers.

**Version**: 1.4.31

## Features

- Thread-safe connection management using `concurrent-ruby`
- AMQP 0.9.1 client via `bunny`
- Topic-based exchange routing with priority queue support
- Optional message encryption via `legion-crypt`
- Dynamic credential retrieval from HashiCorp Vault
- Auto-recovery on connection loss (configurable attempts, 5s shutdown timeout)
- Dead letter exchange support
- Reliable publish with publisher confirms, mandatory routing, and structured result reporting
- Spool buffer for disk-backed message persistence when RabbitMQ is unavailable
- `InProcess` adapter for lite mode (`LEGION_MODE=lite`): no RabbitMQ required, uses in-memory pub/sub
- `Helper` mixin for LEX extensions: `transport_path`, `transport_class`, `messages`, `queues`, `exchanges`

## Supported Ruby Versions

- Ruby >= 3.4

## Installation

```bash
gem install legion-transport
```

Or add to your Gemfile:

```ruby
gem 'legion-transport'
```

## Usage

### Basic Connection

```ruby
require 'legion/transport'

Legion::Transport::Connection.setup
Legion::Transport::Connection.channel  # => Bunny::Channel
Legion::Transport::Connection.session  # => Bunny::Session
```

### Dedicated Sessions

`Connection.create_dedicated_session` creates a separate AMQP connection independent of the shared main session. Useful for consumers that need their own connection (e.g., a dedicated log channel or a build pipeline connection). In lite mode it returns the shared `InProcess::Session` (in-process transport is process-global; true session isolation is not available in lite mode).

```ruby
session = Legion::Transport::Connection.create_dedicated_session(name: 'my-log-session')
channel = session.create_channel
# use channel independently of the main transport session
```

### Publishing a Message

```ruby
Legion::Transport::Messages::Task.new(
  function: 'my_function',
  queue: 'my_extension',
  routing_key: 'my_extension.my_function',
  task_id: SecureRandom.uuid
).publish
```

### Reliable Publish

Pass reliability options to `#publish` to get structured feedback on message delivery:

```ruby
msg = Legion::Transport::Messages::Task.new(
  function: 'process_order',
  routing_key: 'orders.process',
  correlation_id: SecureRandom.uuid
)

result = msg.publish(
  mandatory: true,              # broker returns message if unroutable
  publisher_confirm: true,      # wait for broker acknowledgment
  publish_confirm_timeout_ms: 500, # confirm wait timeout
  spool: false                  # disable disk spool on failure (fail fast)
)

result[:status]   # => :accepted, :unroutable, :nacked, :confirm_timeout, :spooled, or :failed
result[:accepted] # => true/false
```

Options merge with the message's defaults — you can override `routing_key:` or `persistent:` per-publish without constructing a new message.

Mandatory publishing waits for publisher confirmation before reporting routed acceptance. Confirm waits use Bunny's zero-argument API and retire a timed-out channel so late acknowledgments cannot contaminate the next send. A timeout is an unknown delivery outcome, not proof that the broker rejected the message.

### Spooling and automatic replay

Connection failures can persist the already encoded wire payload, complete AMQP envelope, effective broker destination, and tenant identity. `:spooled` means the disk write succeeded; a full spool or failed write returns `:failed`.

- Startup, native recovery, and forced recovery schedule one asynchronous replay worker. Network operations run outside spool-write and connection locks.
- Replay uses the original ciphertext and IV, checks the stored tenant's encoded-byte quota, and removes records only after routed broker confirmation.
- Delivery is **at least once**: interruption after broker acceptance but before confirmation is recorded can cause redelivery. Consumers must tolerate duplicates.
- Concurrent appends are not part of a drainer's claimed file. Shutdown retains the unconfirmed tail for the next startup.
- Configure `Legion::Settings[:transport][:spool][:directory]` or pass `directory:` to `Spool.setup`; the default is `~/.legionio/spool`. Capacity limits reject new writes rather than deleting pending messages.
- Manual `Spool.drain` callbacks acknowledge a record only by returning literal `true`.

Older unversioned JSONL files upgrade automatically during replay; no migration command or opt-in is required. Their raw payloads are encoded once, with saved routing, tenant and envelope metadata preserved. Saved encryption flags and evidence of an earlier encrypted attempt take precedence over the current encryption default; explicit plaintext and cluster-secret bootstrap requests remain supported. A stale saved IV is replaced with the IV for the newly encoded bytes, not reused.

The claimed file is streamed to a locked replacement, flushed and fsynced, then atomically renamed before any upgraded record is published. Interrupted conversion retains the original data; interruption after conversion replays the stored wire bytes without re-encrypting. Missing key readiness or extension classes still loading at startup are retried automatically. Concurrent appends and existing versioned records remain intact.

Records already missing essential information—such as an old `Direct` fallback that never saved its broker exchange—remain on disk with a specific error. Replay never invents a destination or drops malformed records.

### Encryption policy

`transport.messages.encrypt: true` or `encrypt: true` requires a ready cluster secret. An unready key raises `Legion::Transport::EncryptionNotReady` before publishing or spooling plaintext. Encryption itself is bounded by `crypt.cluster_secret_timeout` (five seconds when unset). Explicit `encrypt: false` and the cluster-secret bootstrap message remain deliberately unencrypted.

### HTTP publish outcomes

`POST /api/transport/publish` requests mandatory routing and publisher confirmation. Responses distinguish accepted (`201`), spooled/deferred (`202`), unroutable (`422`), confirm timeout (`504`), and failed/nacked (`503`) results. `published: true` is returned only for accepted publication; unexpected exceptions return an error response.

### Creating a Queue

```ruby
queue = Legion::Transport::Queues::Node.new
queue.subscribe do |delivery_info, properties, payload|
  # process message
  queue.acknowledge(delivery_info.delivery_tag)
end
```

### Creating an Exchange

```ruby
exchange = Legion::Transport::Exchanges::Task.new
exchange.publish(payload, routing_key: 'task.my_runner.my_function')
```

## Connection Configuration

```json
{
  "transport": {
    "connection": {
      "host": "rabbitmq1.example.com",
      "servers": ["rabbitmq2.example.com", "rabbitmq3.example.com:5673"],
      "port": 5672,
      "user": "legion",
      "password": "secret",
      "vhost": "/"
    }
  }
}
```

Supported server keys: `host:` (string), `hosts:` (array), `server:` (string), `servers:` (array). All are merged and deduped. Port 5672 is injected where omitted. Connection setup attempts each configured host, including the AMQP handshake, and closes failed attempts before moving to the next host.

### Pooling and recovery

- Set `transport.connection_pool_size` above `1` to enable lazy session pooling. Publisher channels are reused per thread and tracked for cleanup.
- Pool checkout uses one monotonic deadline for waiting and connection creation. Shutdown wakes blocked callers with `Legion::Transport::PoolClosed`; a late factory result is closed instead of returning to the pool.
- `Connection.shutdown` shares a five-second teardown deadline across owned sessions, closes their sockets, and stops consumer workers. Channel or session creation racing with shutdown cannot install stale resources.
- `Connection.force_reconnect` permits one active reconnect. It restores existing consumer/channel/queue objects, declarations, bindings, and QoS before running `on_force_reconnect` callbacks. Cancelled consumers remain cancelled, and repeated reconnects reuse publisher channels.
- Restoration failures return `false`, close the failed replacement, and retain the subscription snapshot for a later reconnect attempt. Restoration refuses to rebind channels while old consumer workers remain alive.
- Recovery snapshots have their own five-second deadline. If an old Bunny channel/consumer lock is stuck, reconnect returns `false` without detaching the old session; release the lock and retry.
- Shutdown invalidates the entire in-flight reconnect generation. A cancelled snapshot, replacement attempt, or cleanup cannot reopen transport, tear down a newer session, or clear a newer reconnect owner's guard.
- Intentional teardown stops socket readers before closing their sockets, avoiding Bunny 2.x asynchronous network errors in the session-owning thread. An open lite-mode connection needs no network recovery and retains its consumers during `force_reconnect`.

### Tenant topology and quotas

Enable `transport.tenant_topology.enabled` to scope ordinary queue/exchange declarations, bindings, and DLXs to the active `Legion::TenantContext.current` identity. The default format is `t.<tenant_id>.<name>`; disabled topology and the `default` tenant retain unprefixed names. Configured shared exchanges remain shared. Exchange caches include tenant, effective name, declaration options, and explicit channel context.

`TenantProvisioner.provision(tenant_id)` creates the same `task`, `results`, and `events` resources and corresponding dead-letter topology used by producers and consumers. Message and helper publishing enforce per-tenant message/encoded-byte limits; replay preserves the stored tenant instead of using its worker's ambient context.

Enabling isolation on an existing unprefixed deployment requires an explicit topology/data migration. Queue, exchange, and DLX mismatches now fail without delete-and-recreate repair. Required DLX provisioning errors prevent source-queue construction.

### Lite delivery

Lite mode supports exchange-scoped direct, fanout, and topic bindings (`*` matches one word; `#` matches zero or more). Only undelivered messages remain pending; callbacks run outside the global storage mutex, and cancellation unregisters callbacks before completing. Session shutdown retires its own queues and consumers without resetting unrelated sessions.

Direct `Local.subscribe` callers must specify `exchange_name:` for named exchanges; omitting it subscribes only to the default exchange:

```ruby
Legion::Transport::Local.subscribe('worker.run', exchange_name: 'events') { |payload| puts payload }
Legion::Transport::Local.publish('events', 'worker.run', 'work')
```

## Configuration

Configuration is managed through `legion-settings` with environment variable overrides:

| Setting | Env Var | Default |
|---------|---------|---------|
| Host | `transport.connection.host` | `127.0.0.1` |
| Port | `transport.connection.port` | `5672` |
| User | `transport.connection.user` | `guest` |
| Password | `transport.connection.password` | `guest` |
| VHost | `transport.connection.vhost` | `/` |
| Prefetch | `transport.prefetch` | `2` |
| Encrypt | `transport.messages.encrypt` | `false` |
| TTL | `transport.messages.ttl` | `nil` |
| Persistent | `transport.messages.persistent` | `true` |

### Full Default Settings

```json
{
  "type": "rabbitmq",
  "connected": false,
  "logger_level": "warn",
  "messages": {
    "encrypt": false,
    "ttl": null,
    "priority": 0,
    "persistent": true
  },
  "prefetch": 2,
  "exchanges": {
    "type": "topic",
    "arguments": {},
    "auto_delete": false,
    "durable": true,
    "internal": false
  },
  "queues": {
    "manual_ack": true,
    "durable": true,
    "exclusive": false,
    "block": false,
    "auto_delete": false,
    "arguments": {
      "x-queue-type": "quorum"
    }
  },
  "connection": {
    "read_timeout": 3,
    "heartbeat": 30,
    "automatically_recover": true,
    "continuation_timeout": 8000,
    "network_recovery_interval": 2,
    "connection_timeout": 10,
    "frame_max": 65536,
    "user": "guest",
    "password": "guest",
    "host": "127.0.0.1",
    "port": 5672,
    "vhost": "/",
    "recovery_attempts": 10,
    "logger_level": "warn",
    "connected": false
  },
  "channel": {
    "default_worker_pool_size": 1,
    "session_worker_pool_size": 16
  }
}
```

### Vault Integration

RabbitMQ credentials are managed by the LeaseManager via `lease://` URI references in transport settings:

```json
{
  "transport": {
    "connection": {
      "user": "lease://rabbitmq#username",
      "password": "lease://rabbitmq#password"
    }
  }
}
```

The lease path (e.g., `rabbitmq/creds/agent`) is configured in `crypt.vault.leases.rabbitmq.path`.

### TLS Support

TLS can be configured through transport settings:

```ruby
# Settings under [:transport][:tls]
{
  use_tls: true,
  tls_cert: '/path/to/cert.pem',
  tls_key: '/path/to/key.pem',
  ca_certs: '/path/to/ca.pem',
  verify_peer: true,
  vault_pki: false
}
```

Vault-issued PEM files remain owned by their Bunny session through native recovery and are explicitly removed when that session is retired or connection creation fails.

## Dependencies

| Gem | Version | Purpose |
|-----|---------|---------|
| `bunny` | >= 2.23 | AMQP 0.9.1 client |
| `concurrent-ruby` | >= 1.2 | Thread-safe data structures |
| `legion-json` | any | JSON serialization |
| `legion-settings` | any | Configuration management |

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

Apache-2.0
