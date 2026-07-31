require "rails/generators"
require "rails/generators/base"
require "generators/hyperdrive/content_sync_support"

module Rails
  module Generators
    module Hyperdrive
      # Content-only by contract: no step may write a bootstrap artifact
      # (.mcp.json, the engine mount, the initializer, the .gitignore rule).
      class SyncGenerator < ::Rails::Generators::Base
        include ContentSyncSupport

        # No templates are rendered; source_root exists so Rails resolves the
        # sibling USAGE file for `--help`.
        source_root File.expand_path("templates", __dir__)

        class_option :overwrite, type: :boolean, default: false, desc: "Restore locally-modified managed files to the gem-shipped content."
        class_option :dry_run,   type: :boolean, default: false, desc: "Show what would change; write nothing."

        def verify_environment
          ensure_rails_development!
        end

        def parse_stack_profile
          load_stack_profile
        end

        def discover_artifacts
          discover_bundle_artifacts
        end

        def sync_content
          run_install_pipeline(mode: options[:overwrite] ? :overwrite : :preserve)
        end

        def print_summary
          say ""
          say_status :done, "hyperdrive synced", :green
          print_installed_artifacts
        end
      end
    end
  end
end
