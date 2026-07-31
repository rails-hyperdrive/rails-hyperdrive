require "rails/generators"
require "rails/generators/base"
require "json"
require "rails/hyperdrive"
require "rails/hyperdrive/stack_profile"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/companion_discovery"
require "generators/hyperdrive/gitignore_support"

module Rails
  module Generators
    module Hyperdrive
      # Backs `bin/rails hyperdrive:init` and `bin/rails hyperdrive:update`.
      #
      # init   — first-run + idempotent re-sync; skips locally-modified files.
      # update — same pipeline, but force-overwrites locally-modified files.
      #
      # rails-hyperdrive ships no content. It walks the bundle for companion
      # gems' skills + guidelines, installs them, generates stack.md, maintains
      # the index.md aggregator, and injects exactly one `@`-include line into
      # CLAUDE.md.
      class InstallGenerator < ::Rails::Generators::Base
        include GitignoreSupport

        ENGINE_MOUNT_TOKEN = "Rails::Hyperdrive::Engine"
        DEFAULT_MOUNT_AT = "/_hyperdrive".freeze

        MCP_JSON_PATH = ".mcp.json".freeze
        MCP_SERVER_KEY = "rails-hyperdrive".freeze

        KIND_WIDTH = "guideline".length
        KIND_ORDER = %w[skill guideline stack].freeze
        INTERNAL_SOURCE_PREFIX = "internal@".freeze

        source_root File.expand_path("templates", __dir__)

        # Routes InstallPipeline's writes through Thor, so its output and
        # `--dry-run` handling cover installed content too.
        class ThorShell
          def initialize(generator)
            @generator = generator
          end

          def create_file(path, content)
            @generator.create_file(path, content, force: true)
          end

          def append_to_file(path, content)
            @generator.append_to_file(path, content)
          end

          def remove_file(path)
            @generator.remove_file(path)
          end

          def say_status(kind, message, color = nil)
            @generator.say_status(kind, message, color)
          end

          def say(message = "")
            @generator.say(message)
          end
        end

        class_option :mount_at,      type: :string,  default: DEFAULT_MOUNT_AT, desc: "Engine mount path."
        class_option :skip_content,  type: :boolean, default: false, desc: "Skip all .claude content, CLAUDE.md, and the lockfile; write only .mcp.json and the mount."
        class_option :dry_run,       type: :boolean, default: false, desc: "Show what would change; write nothing."
        class_option :force_install, type: :boolean, default: false, desc: "Force-overwrite locally-modified files (same as update)."
        class_option :update,        type: :boolean, default: false, desc: "Update mode: force-overwrite locally-modified files."

        def verify_environment
          unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
            say_status :error, "must be run inside a Rails app", :red
            raise Thor::Error, "hyperdrive: not in a Rails app"
          end
          unless ::Rails.respond_to?(:env) && ::Rails.env.development?
            env = ::Rails.respond_to?(:env) ? ::Rails.env.to_s : "unknown"
            warn "hyperdrive: hyperdrive:init must run with Rails.env=development (current: #{env})"
            raise Thor::Error, "hyperdrive: refuse to run outside development (Rails.env=#{env})"
          end
          # Thor's create_file / inject_into_file / append_to_file all honor
          # `options[:pretend]`. Translate our user-facing --dry-run to that.
          if options[:dry_run]
            self.options = options.merge(pretend: true).freeze
          end
        end

        def parse_stack_profile
          @stack_profile = ::Rails::Hyperdrive::StackProfile.from_lockfile(
            ::Rails.root.join("Gemfile.lock").to_s,
            app_root: ::Rails.root.to_s
          )
        end

        def discover_artifacts
          @warnings = []
          @artifacts =
            if options[:skip_content]
              []
            else
              ::Rails::Hyperdrive::BundlerArtifactDiscovery.discover(warnings: @warnings)
            end
        end

        # The write is forced: Thor's conflict prompt would otherwise block the
        # run waiting on stdin.
        def write_mcp_json
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

        # The `hyperdrive:discover` cache is the only gitignored
        # rails-hyperdrive artifact — the lockfile `.hyperdrive/lock.yml` stays
        # git-tracked. Ignore the specific file, not the `.hyperdrive/`
        # directory.
        def ignore_discover_cache
          ensure_gitignored(::Rails::Hyperdrive::CompanionDiscovery::CACHE_RELATIVE_PATH)
        end

        def write_initializer
          return if mount_path == DEFAULT_MOUNT_AT
          template "initializer.rb.tt", "config/initializers/hyperdrive.rb"
        end

        def mount_engine
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

        # `--skip-content` writes no lockfile either: the lock is a manifest of
        # installed content, and an empty one would assert "zero files is the
        # managed set". A later init/update reconstructs the full state.
        def sync_content
          return if options[:skip_content]

          @pipeline = ::Rails::Hyperdrive::InstallPipeline.new(
            root: ::Rails.root.to_s,
            shell: ThorShell.new(self),
            artifacts: @artifacts,
            stack: stack,
            mode: update_mode? ? :update : :init,
            warnings: @warnings
          )
          @pipeline.call
        end

        def print_summary
          say ""
          say_status :done, "hyperdrive #{update_mode? ? "updated" : "initialized"}", :green
          say "  Mount: #{mount_path} (in config/routes.rb)"
          print_installed_artifacts unless options[:skip_content]
          say ""
          say "  Next steps:"
          say "    1. bin/rails server"
          say "    2. Open Claude Code in this directory; it will read .mcp.json"
          say "    3. Verify the connection: curl http://localhost:3000#{mount_path}/mcp"
        end

        # ---------- helpers ----------

        no_tasks do
          def update_mode?
            options[:update] || options[:force_install]
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

          # Normalize the user-supplied mount path.
          def mount_path
            raw = options[:mount_at].to_s
            raw = "/" + raw unless raw.start_with?("/")
            raw.length > 1 ? raw.chomp("/") : raw
          end

          def stack
            @stack_profile.to_h
          end

          # Reads the lock the pipeline leaves behind, so the listing states the
          # app's resulting content: untouched, locally-modified, and orphaned
          # files included.
          def print_installed_artifacts
            entries = []
            @pipeline&.lock&.each_entry { |e| entries << e }
            return if entries.empty?

            say "  #{installed_counts(entries)}"
            say ""
            group_by_source(entries).each do |source, group|
              say "    #{source}"
              group.each do |entry|
                say "      #{entry[:artifact].to_s.ljust(KIND_WIDTH)}  #{display_name(entry)}"
              end
            end
          end

          def installed_counts(entries)
            counts = entries.group_by { |e| e[:artifact].to_s }.transform_values(&:size)
            summary = "Installed #{quantify(counts["skill"].to_i, "skill")}, #{quantify(counts["guideline"].to_i, "guideline")}"
            counts["stack"].to_i.positive? ? "#{summary} + stack.md" : summary
          end

          def group_by_source(entries)
            entries
              .group_by { |e| e[:source].to_s }
              .sort_by { |source, _| [source.start_with?(INTERNAL_SOURCE_PREFIX) ? 1 : 0, source] }
              .map do |source, group|
                [source, group.sort_by { |e| [KIND_ORDER.index(e[:artifact].to_s) || KIND_ORDER.size, display_name(e)] }]
              end
          end

          def display_name(entry)
            path = entry[:path].to_s
            case entry[:artifact].to_s
            when "skill" then File.basename(File.dirname(path))
            when "stack" then File.basename(path)
            else File.basename(path, ".md")
            end
          end

          def quantify(count, noun)
            "#{count} #{noun}#{"s" unless count == 1}"
          end
        end
      end
    end
  end
end
