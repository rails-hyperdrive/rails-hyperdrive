require "mcp"
require "mcp/server/transports/streamable_http_transport"
require_relative "safety/rack_middleware"
require_relative "tools/describe_app"
require_relative "tools/run_ruby"
require_relative "tools/run_sql"
require_relative "tools/tail_logs"
require_relative "tools/list_models"
require_relative "tools/locate_source"
require_relative "tools/lookup_doc"
require_relative "tools/list_routes"
require_relative "resources/stack_profile"
require_relative "resources/skill"

module Rails
  module Hyperdrive
    module McpServer
      TOOLS = [
        Tools::DescribeApp,
        Tools::RunRuby,
        Tools::RunSql,
        Tools::TailLogs,
        Tools::ListModels,
        Tools::LocateSource,
        Tools::LookupDoc,
        Tools::ListRoutes
      ].freeze

      module_function

      def server
        @server ||= build_server
      end

      def rack_app(allowed_hosts: Safety::RackMiddleware::DEFAULT_ALLOWED_HOSTS)
        # The transport's own DNS-rebinding check requires same-origin (host:port);
        # it is disabled because Safety::RackMiddleware enforces the localhost
        # Origin allowlist, which accepts any port.
        @rack_app ||= Safety::RackMiddleware.new(
          ::MCP::Server::Transports::StreamableHTTPTransport.new(
            server, stateless: true, enable_json_response: true, dns_rebinding_protection: false
          ),
          allowed_hosts: allowed_hosts
        )
      end

      def reset!
        @server = nil
        @rack_app = nil
      end

      def build_server
        srv = ::MCP::Server.new(
          name: "hyperdrive",
          title: "Rails Hyperdrive",
          version: Rails::Hyperdrive::VERSION,
          instructions: "Rails Hyperdrive MCP server. Prefer locate_source/list_models before guessing.",
          tools: TOOLS,
          resources: [Resources::StackProfile.resource, *Resources::Skill.installed_resources],
          resource_templates: [Resources::Skill.template]
        )

        srv.resources_read_handler do |params|
          uri = params[:uri] || params["uri"]
          if uri == Resources::StackProfile::URI
            Resources::StackProfile.read(params)
          elsif uri.to_s.start_with?(Resources::Skill::URI_PREFIX)
            Resources::Skill.read(params)
          else
            raise ::MCP::Server::RequestHandlerError.new(
              "Resource not found: #{uri}", params, error_type: :invalid_params
            )
          end
        end

        srv
      end
    end
  end
end
