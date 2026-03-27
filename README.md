# Legion::Transport

Legion::Transport is the Ruby gem responsible for connecting LegionIO to its FIFO queue system (RabbitMQ over AMQP 0.9.1). It provides thread-safe connection management, exchange/queue abstractions, message publishing with optional encryption, and consumer wrappers.

**Version**: 1.4.1

## Features

- Thread-safe connection management using `concurrent-ruby`
- AMQP 0.9.1 client via `bunny`
- Topic-based exchange routing with priority queue support
- Optional message encryption via `legion-crypt`
- Dynamic credential retrieval from HashiCorp Vault
- Auto-recovery on connection loss (configurable attempts, 5s shutdown timeout)
- Dead letter exchange support
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

### Publishing a Message

```ruby
Legion::Transport::Messages::Task.new(
  function: 'my_function',
  queue: 'my_extension',
  routing_key: 'my_extension.my_function',
  task_id: SecureRandom.uuid
).publish
```

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

Supported server keys: `host:` (string), `hosts:` (array), `server:` (string), `servers:` (array). All are merged and deduped. Port 5672 is injected where omitted. Multiple hosts enable Bunny's cluster failover.

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
  "logger_level": "info",
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
      "x-max-priority": 255,
      "x-overflow": "reject-publish"
    }
  },
  "connection": {
    "read_timeout": 1,
    "heartbeat": 30,
    "automatically_recover": true,
    "continuation_timeout": 4000,
    "network_recovery_interval": 1,
    "connection_timeout": 1,
    "frame_max": 65536,
    "user": "guest",
    "password": "guest",
    "host": "127.0.0.1",
    "port": "5672",
    "vhost": "/",
    "recovery_attempts": 100,
    "logger_level": "info",
    "connected": false
  },
  "channel": {
    "default_worker_pool_size": 1,
    "session_worker_pool_size": 8
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
  use_vault_pki: false
}
```

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
