require "mcp"
require "rails/hyperdrive/install_layout"

module Rails
  module Hyperdrive
    module Resources
      module Skill
        URI_TEMPLATE = "hyperdrive://skills/{name}"
        URI_PREFIX = "hyperdrive://skills/"
        # Skill names follow the SKILL.md/.claude convention: lowercase letters,
        # digits, hyphens. Anything else is rejected to prevent path traversal
        # via `hyperdrive://skills/../../etc/passwd`.
        NAME_PATTERN = /\A[a-z0-9][a-z0-9_\-]*\z/.freeze

        module_function

        def template
          ::MCP::ResourceTemplate.new(
            uri_template: URI_TEMPLATE,
            name: "Installed skill",
            description: "Markdown body of an installed #{InstallLayout::SKILLS_DIR}/<name>/SKILL.md",
            mime_type: "text/markdown"
          )
        end

        # Enumerated once at server build time, so skills installed by a fresh
        # `hyperdrive:init` only appear after a dev-server restart.
        def installed_resources
          return [] unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
          skills_root = ::Rails.root.join(InstallLayout::SKILLS_DIR)
          return [] unless Dir.exist?(skills_root)
          Dir.glob(::Rails.root.join(InstallLayout.dest_for(:skill, "*")).to_s).sort.map do |path|
            name = InstallLayout.installed_name(:skill, path)
            next unless name.match?(NAME_PATTERN)
            ::MCP::Resource.new(
              uri: "#{URI_PREFIX}#{name}",
              name: name,
              description: "Skill: #{name}",
              mime_type: "text/markdown"
            )
          end.compact
        end

        def read(params)
          uri = params[:uri] || params["uri"]
          name = uri.to_s.sub(URI_PREFIX, "")
          unless name.match?(NAME_PATTERN)
            raise ::MCP::Server::RequestHandlerError.new(
              "Resource not found: #{uri}", params, error_type: :invalid_params
            )
          end
          path = ::Rails.root.join(InstallLayout.dest_for(:skill, name))
          unless File.exist?(path)
            raise ::MCP::Server::RequestHandlerError.new(
              "Resource not found: #{uri}", params, error_type: :invalid_params
            )
          end
          [{ uri: uri, mimeType: "text/markdown", text: File.read(path) }]
        end
      end
    end
  end
end
