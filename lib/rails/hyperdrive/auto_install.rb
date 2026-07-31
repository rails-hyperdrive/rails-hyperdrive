require "bundler"
require "rails/hyperdrive/artifact_status"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "rails/hyperdrive/stack_profile"

module Rails
  module Hyperdrive
    # Tops up an already-initialized application with artifacts its lockfile
    # does not record yet, and reports everything it left alone. Requires no
    # booted Rails, and never raises — every failure comes back as a skipped
    # result.
    module AutoInstall
      DEVELOPMENT = "development".freeze

      Result = Struct.new(:installed, :outdated, :orphaned, :skipped, :error, keyword_init: true) do
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
        return skip(:not_initialized) unless File.exist?(File.join(root, InstallPipeline::LOCK_PATH))

        artifacts = BundlerArtifactDiscovery.discover
        stack = StackProfile.from_lockfile(File.join(root, "Gemfile.lock"), app_root: root).to_h
        status = ArtifactStatus.compare(root: root, artifacts: artifacts, stack: stack)

        installed =
          if status.missing.empty?
            []
          else
            InstallPipeline.new(
              root: root,
              shell: InstallShell.new(root: root, io: io),
              artifacts: artifacts,
              stack: stack,
              mode: :additive
            ).call.installed
          end

        Result.new(installed: installed, outdated: status.outdated, orphaned: status.orphaned)
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
