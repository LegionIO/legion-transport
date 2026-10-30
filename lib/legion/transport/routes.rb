# frozen_string_literal: true

# Self-registering route module for legion-transport.
# All routes previously defined in LegionIO/lib/legion/api/transport.rb now live here
# and are mounted via Legion::API.register_library_routes when legion-transport boots.
#
# LegionIO/lib/legion/api/transport.rb is preserved for backward compatibility but guards
# its registration with defined?(Legion::Transport::Routes) so double-registration is avoided.

require 'legion/logging/helper'

module Legion
  module Transport
    module Routes
      extend Legion::Logging::Helper

      def self.registered(app)
        register_helpers(app)
        register_status(app)
        register_discovery(app)
        register_publish(app)
        register_spool_recovery(app)
        register_tenant_migration(app)
      end

      def self.register_helpers(app)
        app.helpers Legion::Logging::Helper
        register_json_helpers(app)
        register_transport_helpers(app)
        register_admin_errors(app)
      end

      def self.register_json_helpers(app)
        app.helpers do
          unless method_defined?(:json_response)
            define_method(:json_response) do |data, status_code: 200|
              content_type :json
              status status_code
              Legion::JSON.dump({ data: data })
            end
          end

          unless method_defined?(:json_error)
            define_method(:json_error) do |code, message, status_code: 400|
              content_type :json
              status status_code
              Legion::JSON.dump({ error: { code: code, message: message } })
            end
          end

          unless method_defined?(:parse_request_body)
            define_method(:parse_request_body) do
              raw = request.body.read
              return {} if raw.nil? || raw.empty?

              begin
                parsed = Legion::JSON.load(raw)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: :parse_request_body)
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code: 'invalid_json', message: 'request body is not valid JSON' } })
              end

              unless parsed.respond_to?(:transform_keys)
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code:    'invalid_request_body',
                                                  message: 'request body must be a JSON object' } })
              end

              parsed.transform_keys(&:to_sym)
            end
          end
        end
      end

      def self.register_transport_helpers(app)
        app.helpers do
          unless method_defined?(:transport_subclasses)
            define_method(:transport_subclasses) do |base_class|
              ObjectSpace.each_object(Class)
                         .select { |klass| klass < base_class }
                         .map { |klass| { name: klass.name } }
                         .sort_by { |h| h[:name].to_s }
            rescue NameError => e
              handle_exception(e, level: :warn, handled: true, operation: :transport_subclasses)
              []
            end
          end
        end
      end

      def self.register_status(app)
        app.get '/api/transport' do
          connected = begin
            Legion::Settings[:transport][:connected]
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: :transport_status_connected)
            false
          end
          session_open = begin
            Legion::Transport::Connection.session_open?
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: :transport_status_session_open)
            false
          end
          channel_open = begin
            Legion::Transport::Connection.channel_open?
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: :transport_status_channel_open)
            false
          end
          connector = defined?(Legion::Transport::TYPE) ? Legion::Transport::TYPE.to_s : 'unknown'

          json_response({ connected: connected, session_open: session_open,
                          channel_open: channel_open, connector: connector })
        end
      end

      def self.register_discovery(app)
        app.get '/api/transport/exchanges' do
          klass = defined?(Legion::Transport::Exchange) ? Legion::Transport::Exchange : nil
          json_response(klass ? transport_subclasses(klass) : [])
        end

        app.get '/api/transport/queues' do
          klass = defined?(Legion::Transport::Queue) ? Legion::Transport::Queue : nil
          json_response(klass ? transport_subclasses(klass) : [])
        end
      end

      def self.register_publish(app)
        app.post '/api/transport/publish' do
          log.debug "API: POST /api/transport/publish params=#{params.keys}"
          body = parse_request_body
          unless body[:exchange]
            log.warn 'API POST /api/transport/publish returned 422: exchange is required'
            halt 422, json_error('missing_field', 'exchange is required', status_code: 422)
          end
          unless body[:routing_key]
            log.warn 'API POST /api/transport/publish returned 422: routing_key is required'
            halt 422, json_error('missing_field', 'routing_key is required', status_code: 422)
          end

          message = Legion::Transport::Messages::Direct.new(
            exchange: body[:exchange], routing_key: body[:routing_key], **(body[:payload] || {})
          )
          result = message.publish(return_result: true, publisher_confirm: true, mandatory: true)
          raise IOError, 'publisher returned no delivery result' unless result.is_a?(Hash)

          published = result[:status] == :accepted && result[:accepted] == true
          status_code = if published
                          201
                        else
                          case result[:status]
                          when :spooled then 202
                          when :unroutable then 422
                          when :confirm_timeout then 504
                          else 503
                          end
                        end
          log.info "API: transport publish status=#{result[:status]} exchange=#{body[:exchange]} routing_key=#{body[:routing_key]}"
          json_response(result.merge(published: published, exchange: body[:exchange], routing_key: body[:routing_key]),
                        status_code: status_code)
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: :transport_publish)
          json_error('publish_error', e.message, status_code: 500)
        end
      end

      def self.register_admin_errors(app)
        app.helpers do
          define_method(:transport_admin_request) do |&operation|
            operation.call
          rescue KeyError => e
            handle_exception(e, level: :warn, handled: true, operation: :transport_admin_request)
            json_error('recovery_not_found', e.message, status_code: 404)
          rescue ArgumentError, TypeError, Legion::Transport::Spool::LegacyRecordError => e
            handle_exception(e, level: :warn, handled: true, operation: :transport_admin_request)
            json_error('invalid_recovery_request', e.message, status_code: 422)
          rescue Legion::Transport::EncryptionNotReady => e
            handle_exception(e, level: :warn, handled: true, operation: :transport_admin_request)
            json_error('encryption_not_ready', e.message, status_code: 503)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: :transport_admin_request)
            json_error('transport_recovery_failed', e.message, status_code: 503)
          end
        end
      end

      def self.register_spool_recovery(app)
        app.get '/api/transport/spool' do
          transport_admin_request { json_response(Legion::Transport::Spool.status) }
        end
        app.get '/api/transport/spool/recovery' do
          transport_admin_request do
            entries = Legion::Transport::Spool.recovery_entries(status: params['status'],
                                                                limit:  Integer(params.fetch('limit', '100')),
                                                                offset: Integer(params.fetch('offset', '0')))
            json_response(entries)
          end
        end
        app.get '/api/transport/spool/recovery/:id' do
          transport_admin_request { json_response(Legion::Transport::Spool.recovery_record(id: params['id'])) }
        end
        app.post '/api/transport/spool/recovery/:id/repair' do
          transport_admin_request do
            result = Legion::Transport::Spool.repair_record(id: params['id'], changes: parse_request_body)
            json_response(result, status_code: 202)
          end
        end
        app.post '/api/transport/spool/recovery/:id/retry' do
          transport_admin_request do
            result = Legion::Transport::Spool.retry_recovery(id: params['id'])
            status_code = case result[:status]
                          when 'ready', 'waiting' then 202
                          when 'delivered' then 200
                          else 422
                          end
            json_response(result, status_code: status_code)
          end
        end
      end

      def self.register_tenant_migration(app)
        app.post '/api/transport/tenants/:tenant_id/migrate' do
          transport_admin_request do
            body = parse_request_body
            result = Legion::Transport::TenantMigration.migrate(
              tenant_id: params['tenant_id'], queues: body[:queues], dry_run: body.fetch(:dry_run, false),
              max_messages: body.fetch(:max_messages, 10_000), timeout: body.fetch(:timeout, 30)
            )
            status_code = case result[:status]
                          when :planned, :completed then 200
                          when :pending then 202
                          when :blocked then 409
                          else 503
                          end
            status_code = 422 if result[:errors].any? { |error| %w[ArgumentError KeyError TypeError].include?(error[:error_class]) }
            json_response(result, status_code: status_code)
          end
        end
      end

      class << self
        private :register_helpers, :register_json_helpers, :register_transport_helpers,
                :register_status, :register_discovery, :register_publish, :register_admin_errors,
                :register_spool_recovery, :register_tenant_migration
      end
    end
  end
end
