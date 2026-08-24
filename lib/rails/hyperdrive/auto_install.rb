require "bundler"
require "rails/hyperdrive/artifact_status"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "rails/hyperdrive/lock_file"

module Rails
  module Hyperdrive
    # Requires no booted Rails and never raises — every failure comes back as
    # a skipped result.
    module AutoInstall
      DEVELOPMENT = "development".freeze

      Result = Struct.new(:installed, :outdated, :orphaned, :unwired, :fence_warnings, :halted, :skipped, :error,
        keyword_init: true) do
        def ran?
          skipped.nil?
        end

        def installed_anything?
          !Array(installed).empty?
        end

        def messages
          return [] unless ran?
          return [halted] if halted

          lines = []
          unless Array(installed).empty?
            lines << "installed #{installed.size} artifact(s):"
            installed.each { |path| lines << "  #{path}" }
          end
          lines << "installed guideline(s) are not in context yet — run bin/rails hyperdrive:sync" if unwired
          stale = Array(outdated) + Array(orphaned)
          unless stale.empty?
            lines << "#{stale.size} artifact(s) need attention — run bin/rails hyperdrive:sync"
            stale.each { |entry| lines << "  #{entry}" }
          end
          Array(fence_warnings).each { |warning| lines << warning }
          lines
        end
      end

      module_function

      def run(root: Dir.pwd, env: current_env, io: nil)
        root = File.expand_path(root.to_s)

        return skip(:not_development) unless development?(env)
        return skip(:not_initialized) unless File.exist?(File.join(root, InstallLayout::LOCK_PATH))

        lock = LockFile.load(File.join(root, InstallLayout::LOCK_PATH))
        return halted(lock.schema_ahead_message(InstallLayout::LOCK_PATH)) if lock.schema_ahead?

        fence_warnings = []
        bundled_gems = []
        artifacts = BundlerArtifactDiscovery.discover(
          enabled_gems: lock.enabled_gems, fence_warnings: fence_warnings, bundled_gems: bundled_gems
        )
        status = ArtifactStatus.compare(root: root, artifacts: artifacts, bundled_gems: bundled_gems)

        installed = []
        unwired = false

        unless status.missing.empty?
          pipeline = InstallPipeline.new(
            root: root,
            shell: InstallShell.new(root: root, io: io),
            artifacts: artifacts,
            mode: :additive
          )
          installed = pipeline.call.installed
          # This runs from a bundle install, which must not edit CLAUDE.md, so a
          # guideline landing in an app with no import line stays out of context
          # until the user runs a sync.
          unwired = pipeline.lock.claude_md_state.nil? && (installed & pipeline.lock.guideline_paths).any?
        end

        Result.new(installed: installed, outdated: status.outdated, orphaned: status.orphaned,
          unwired: unwired, fence_warnings: fence_warnings)
      rescue StandardError => e
        skip(:error, e)
      end

      # Rails may never boot in this process, and this guard fronts a write
      # into the working tree, which a deploy or a CI container must never
      # have modified underneath it.
      def development?(env)
        return false unless env.to_s == DEVELOPMENT
        return false if ENV["CI"] && !ENV["CI"].empty?
        !frozen_bundle?
      end

      def current_env
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || DEVELOPMENT
      end

      def frozen_bundle?
        ::Bundler.respond_to?(:frozen_bundle?) && ::Bundler.frozen_bundle?
      rescue StandardError
        false
      end

      def skip(reason, error = nil)
        Result.new(installed: [], outdated: [], orphaned: [], fence_warnings: [], skipped: reason, error: error)
      end

      # A completed run that installed nothing and has a reason to print.
      def halted(reason)
        Result.new(installed: [], outdated: [], orphaned: [], fence_warnings: [], halted: reason)
      end
    end
  end
end
