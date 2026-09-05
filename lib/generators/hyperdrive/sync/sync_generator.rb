require "rails/generators"
require "rails/generators/base"
require "generators/hyperdrive/content_sync_support"

module Rails
  module Generators
    module Hyperdrive
      # Content-only by contract: no step may write a bootstrap artifact
      # (.mcp.json, the engine mount, the .gitignore rule).
      class SyncGenerator < ::Rails::Generators::Base
        include ContentSyncSupport

        # No templates are rendered; source_root exists so Rails resolves the
        # sibling USAGE file for `--help`.
        source_root File.expand_path("templates", __dir__)

        class_option :overwrite, type: :boolean, default: false, desc: "Restore locally-modified managed files to the gem-shipped content."
        class_option :merge,     type: :boolean, default: false, desc: "Three-way-merge upstream changes into locally-modified files; falls back to sidecar delivery."
        class_option :sidecar,   type: :boolean, default: false, desc: "Deliver upstream changes for locally-modified files to <file>.new sidecars."
        class_option :dry_run,   type: :boolean, default: false, desc: "Show what would change; write nothing."
        class_option :resolve,   type: :boolean, default: false, desc: "Hand each unresolved <file>.new sidecar to the resolver command in .hyperdrive/config.yml; delivers to sidecars unless --merge is given."

        def verify_options
          chosen = %i[overwrite merge sidecar].select { |flag| options[flag] }
          chosen << :resolve if options[:resolve] && options[:overwrite]
          return if chosen.size <= 1
          raise Thor::Error,
            "hyperdrive: #{chosen.map { |flag| "--#{flag}" }.join(" and ")} are mutually exclusive; pick one"
        end

        def verify_environment
          runner.verify_environment!
        end

        def verify_resolver
          runner.verify_resolver! if options[:resolve]
        end

        def discover_artifacts
          runner.discover_artifacts
        end

        def sync_content
          mode =
            if options[:overwrite]  then :overwrite
            elsif options[:merge]   then :merge
            elsif options[:sidecar] || options[:resolve] then :sidecar
            else :preserve
            end
          runner.install(mode: mode)
        end

        def resolve_sidecars
          runner.resolve_sidecars(dry_run: options[:dry_run]) if options[:resolve]
        end

        def print_summary
          say ""
          say_status :done, "hyperdrive synced", :green
          runner.summary_lines.each { |line| say line }
        end
      end
    end
  end
end
