require "bundler"
require "rails/hyperdrive/artifact_status"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"

module Rails
  module Hyperdrive
    # Requires no booted Rails and never raises — every failure comes back as
    # a skipped result.
    module AutoInstall
      DEVELOPMENT = "development".freeze

      Result = Struct.new(:installed, :outdated, :orphaned, :unwired, :skipped, :error, keyword_init: true) do
        def ran?
          skipped.nil?
        end

        def installed_anything?
          !Array(installed).empty?
        end

        def messages
          return [] unless ran?
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
          lines
        end
      end

      module_function

      def run(root: Dir.pwd, env: current_env, io: nil)
        root = File.expand_path(root.to_s)

        return skip(:not_development) unless development?(env)
        return skip(:not_initialized) unless File.exist?(File.join(root, InstallLayout::LOCK_PATH))

        artifacts = BundlerArtifactDiscovery.discover
        status = ArtifactStatus.compare(root: root, artifacts: artifacts)

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

        Result.new(installed: installed, outdated: status.outdated, orphaned: status.orphaned, unwired: unwired)
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
        Result.new(installed: [], outdated: [], orphaned: [], skipped: reason, error: error)
      end
    end
  end
end
