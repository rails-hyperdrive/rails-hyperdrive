require "rack"
require "uri"
require "json"

module Rails
  module Hyperdrive
    module Safety
      # Defense-in-depth gate for every request that hits the MCP transport.
      class RackMiddleware
        DEFAULT_ALLOWED_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

        def initialize(app, allowed_hosts: DEFAULT_ALLOWED_HOSTS)
          @app = app
          @allowed_hosts = allowed_hosts
        end

        def call(env)
          unless dev?
            return forbid("hyperdrive is dev-only (Rails.env=#{rails_env})")
          end

          origin = env["HTTP_ORIGIN"]
          if origin && !origin_allowed?(origin)
            return forbid("origin not allowed: #{origin}")
          end

          @app.call(env)
        end

        private

        def dev?
          Rails::Hyperdrive.dev_mode?
        end

        def rails_env
          defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env : "unknown"
        end

        def origin_allowed?(origin)
          host = URI.parse(origin).host
          @allowed_hosts.include?(host)
        rescue URI::InvalidURIError
          false
        end

        def forbid(reason)
          body = { error: "forbidden", reason: reason }.to_json
          [403, { "content-type" => "application/json" }, [body]]
        end
      end
    end
  end
end
