# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Transport
    module Connection
      module SSL
        include Legion::Logging::Helper

        def tls_options(tls_config: nil, port: nil)
          if defined?(Legion::Crypt::TLS)
            tls_config = Legion::Settings[:transport][:tls] if tls_config.nil?
            port ||= Legion::Settings[:transport][:connection][:port]

            tls = Legion::Crypt::TLS.resolve(tls_config, port: port)
            return {} unless tls[:enabled]

            Legion::Transport.logger.info '[Transport] TLS enabled for RabbitMQ connection'
            return {
              tls:                 true,
              tls_cert:            tls[:cert],
              tls_key:             tls[:key],
              tls_ca_certificates: [tls[:ca]].compact,
              verify_peer:         tls[:verify] != :none
            }
          end

          direct_tls_options
        end

        private

        def direct_tls_options
          transport = Legion::Settings[:transport]
          return {} unless transport[:tls]

          Legion::Transport.logger.info '[Transport] TLS enabled for RabbitMQ connection'

          {
            tls:                 true,
            tls_ca_certificates: [transport[:tls_ca_cert]].compact,
            tls_cert:            transport[:tls_client_cert],
            tls_key:             transport[:tls_client_key],
            verify_peer:         transport[:verify_peer] != false
          }
        end
      end
    end
  end
end
