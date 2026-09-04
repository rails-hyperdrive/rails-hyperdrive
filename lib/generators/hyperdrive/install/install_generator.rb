require "rails/generators"
require "rails/generators/base"
require "json"
require "rails/hyperdrive/companion_discovery"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/mcp_server"
require "generators/hyperdrive/content_sync_support"
require "generators/hyperdrive/gitignore_support"

module Rails
  module Generators
    module Hyperdrive
      class InstallGenerator < ::Rails::Generators::Base
        include ContentSyncSupport
        include GitignoreSupport

        ENGINE_MOUNT_TOKEN = "Rails::Hyperdrive::Engine"
        DEFAULT_MOUNT_AT = "/_hyperdrive".freeze

        MCP_JSON_PATH = ".mcp.json".freeze
        MCP_SERVER_KEY = "rails-hyperdrive".freeze

        GEMFILE = "Gemfile".freeze
        BUNDLER_PLUGIN = "bundler-hyperdrive".freeze

        CONFIG_TEMPLATE = <<~YAML.freeze
          # rails-hyperdrive settings. This file is yours: hyperdrive:init creates it
          # once, and no hyperdrive command writes to it afterwards.
          #
          # disabled: artifacts never to install, by name, per kind. Naming a
          #   collision-postfixed variant (foo--gem_a) opts out that one source only.
          #   A disabled artifact already on disk is removed on the next init/sync
          #   unless you edited it.
          # enabled: gems to scan as hyperdrive companions even though they do not
          #   opt in themselves; disabled: still wins per artifact.
          disabled:
            skills: []
            guidelines: []
            agents: []
            commands: []
          enabled: []
        YAML

        # No templates are rendered; source_root exists so Rails resolves the
        # sibling USAGE file for `--help`.
        source_root File.expand_path("templates", __dir__)

        class_option :mount_at,      type: :string,  default: DEFAULT_MOUNT_AT, desc: "Engine mount path."
        class_option :skip_content,  type: :boolean, default: false, desc: "Skip all .claude content, CLAUDE.md, the config file, and the lockfile; leave the .mcp.json, .gitignore, Gemfile, and mount steps."
        class_option :skip_mcp,      type: :boolean, default: false, desc: "Skip MCP setup entirely; write no .mcp.json entry and no engine mount."
        class_option :dry_run,       type: :boolean, default: false, desc: "Show what would change; write nothing."

        def verify_environment
          runner.verify_environment!
        end

        def discover_artifacts
          runner.discover_artifacts(skip: options[:skip_content])
        end

        # The write is forced: Thor's conflict prompt would otherwise block the
        # run waiting on stdin.
        def write_mcp_json
          return if options[:skip_mcp]

          existing = mcp_json_on_disk
          document = existing ? parse_mcp_json(existing) : {}
          return if document.nil?

          (document["mcpServers"] ||= {})[MCP_SERVER_KEY] = mcp_server_entry
          content = JSON.pretty_generate(document) + "\n"

          if existing == content
            say_status :unchanged, MCP_JSON_PATH, :blue
          else
            create_file MCP_JSON_PATH, content, force: true
          end
        end

        def ignore_discover_cache
          ensure_gitignored(::Rails::Hyperdrive::CompanionDiscovery::CACHE_RELATIVE_PATH)
        end

        # Any existing directive counts as registered — a path- or
        # version-qualified line is a deliberate choice this must not
        # duplicate or rewrite.
        def register_bundler_plugin
          gemfile = ::Rails.root.join(GEMFILE)
          unless File.exist?(gemfile)
            say_status :skip, "no #{GEMFILE} found; add plugin #{BUNDLER_PLUGIN.inspect} manually", :yellow
            return
          end

          body = File.read(gemfile)
          if body.match?(/^\s*plugin\s+["']#{BUNDLER_PLUGIN}["']/)
            say_status :identical, "#{GEMFILE} (#{BUNDLER_PLUGIN} plugin already registered)", :blue
            return
          end

          prefix = body.end_with?("\n") || body.empty? ? "" : "\n"
          append_to_file GEMFILE, "#{prefix}plugin #{BUNDLER_PLUGIN.inspect}\n"
        end

        def mount_engine
          return if options[:skip_mcp]

          routes_file = "config/routes.rb"
          unless File.exist?(::Rails.root.join(routes_file))
            say_status :skip, "no #{routes_file} found; skipping engine mount", :yellow
            return
          end

          contents = File.read(::Rails.root.join(routes_file))
          if contents.include?(ENGINE_MOUNT_TOKEN)
            say_status :identical, "#{routes_file} (engine already mounted)", :blue
            return
          end

          snippet = "  mount Rails::Hyperdrive::Engine => \"#{mount_path}\" if Rails.env.development?\n"
          inject_into_file routes_file, snippet, after: /Rails\.application\.routes\.draw do\s*\n/
        end

        # The settings are the user's, so an existing file is never rewritten or
        # reformatted.
        def bootstrap_config
          return if options[:skip_content]

          path = ::Rails::Hyperdrive::InstallLayout::CONFIG_PATH
          if File.exist?(::Rails.root.join(path))
            say_status :identical, "#{path} (already present)", :blue
          else
            create_file path, CONFIG_TEMPLATE
          end
        end

        # `--skip-content` writes no lockfile either: the lock is a manifest of
        # installed content, and an empty one would assert "zero files is the
        # managed set". A later init or sync reconstructs the full state.
        def sync_content
          return if options[:skip_content]
          runner.install(mode: :preserve)
        end

        def print_summary
          say ""
          say_status :done, "hyperdrive initialized", :green
          if options[:skip_mcp]
            say "  MCP: skipped (--skip-mcp)"
          else
            say "  Mount: #{mount_path} (in config/routes.rb)"
            say "  Server: #{::Rails::Hyperdrive::McpServer::TOOLS.size} MCP tools at http://localhost:3000#{mount_path}/mcp"
          end
          runner.summary_lines.each { |line| say line } unless options[:skip_content]
          # Every next step is about reaching the MCP endpoint.
          return if options[:skip_mcp]

          say ""
          say "  Next steps:"
          say "    1. bin/rails server"
          say "    2. Open Claude Code in this directory; it will read .mcp.json"
          say "    3. Verify the connection: #{connection_check_command}"
        end

        no_tasks do
          def connection_check_command
            "curl -s http://localhost:3000#{mount_path}/mcp " \
              "-H 'Content-Type: application/json' -H 'Accept: application/json' " \
              "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'"
          end

          def mcp_json_on_disk
            abs = ::Rails.root.join(MCP_JSON_PATH)
            File.exist?(abs) ? File.read(abs) : nil
          end

          def mcp_server_entry
            {
              "url" => "http://localhost:3000#{mount_path}/mcp",
              "type" => "http"
            }
          end

          # A file we can't parse is never overwritten — its contents are
          # unrecoverable.
          def parse_mcp_json(raw)
            document = JSON.parse(raw)
            return unmergeable_mcp_json("top-level value is not a JSON object") unless document.is_a?(Hash)

            servers = document["mcpServers"]
            unless servers.nil? || servers.is_a?(Hash)
              return unmergeable_mcp_json('"mcpServers" is not a JSON object')
            end

            document
          rescue JSON::ParserError => e
            unmergeable_mcp_json(e.message.lines.first.to_s.strip)
          end

          def unmergeable_mcp_json(reason)
            say_status :warn,
              "#{MCP_JSON_PATH} left unchanged (#{reason}); fix it and re-run to add the #{MCP_SERVER_KEY} server",
              :yellow
            nil
          end

          def mount_path
            raw = options[:mount_at].to_s
            raw = "/" + raw unless raw.start_with?("/")
            raw.length > 1 ? raw.chomp("/") : raw
          end
        end
      end
    end
  end
end
