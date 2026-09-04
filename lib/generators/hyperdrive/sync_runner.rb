require "thor"
require "rails/hyperdrive"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/config_file"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/lock_file"
require "generators/hyperdrive/install_summary"

module Rails
  module Generators
    module Hyperdrive
      # Owns the init/sync sequence. Each phase is an idempotent memoizer and
      # `install` forces the ones it needs, so no call order can install with a
      # half-built input set.
      class SyncRunner
        def initialize(shell:, root: nil)
          @shell = shell
          @root = root&.to_s
        end

        def verify_environment!
          unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
            @shell.say_status :error, "must be run inside a Rails app", :red
            raise Thor::Error, "hyperdrive: not in a Rails app"
          end
          unless ::Rails.respond_to?(:env) && ::Rails.env.development?
            env = ::Rails.respond_to?(:env) ? ::Rails.env.to_s : "unknown"
            warn "hyperdrive: must run with Rails.env=development (current: #{env})"
            raise Thor::Error, "hyperdrive: refuse to run outside development (Rails.env=#{env})"
          end
        end

        def discover_artifacts(skip: false)
          @artifacts ||= skip ? [] : ::Rails::Hyperdrive::BundlerArtifactDiscovery.discover(
            enabled_gems: enabled_gems, report: report
          )
        end

        def install(mode:)
          verify_lock_schema!
          @pipeline = ::Rails::Hyperdrive::InstallPipeline.new(
            root: root,
            shell: @shell,
            artifacts: discover_artifacts,
            mode: mode,
            report: report,
            config: config
          )
          @pipeline.call
        end

        def summary_lines
          InstallSummary.lines(lock_entries)
        end

        private

        # Raised from install, so it stops the run before any content write —
        # a dry run included.
        def verify_lock_schema!
          return unless lock.schema_ahead?

          message = lock.schema_ahead_message(::Rails::Hyperdrive::InstallLayout::LOCK_PATH)
          @shell.say_status :error, message, :red
          raise Thor::Error, "hyperdrive: #{message}"
        end

        # Resolved lazily so verify_environment! can report a missing Rails app
        # before anything dereferences ::Rails.root.
        def root
          @root ||= ::Rails.root.to_s
        end

        def report
          @report ||= ::Rails::Hyperdrive::BundlerArtifactDiscovery::Report.new
        end

        def lock
          @lock ||= ::Rails::Hyperdrive::LockFile.load(
            File.join(root, ::Rails::Hyperdrive::InstallLayout::LOCK_PATH)
          )
        end

        def config
          @config ||= ::Rails::Hyperdrive::ConfigFile.load(
            File.join(root, ::Rails::Hyperdrive::InstallLayout::CONFIG_PATH)
          )
        end

        def enabled_gems
          config.enabled_gems
        end

        def lock_entries
          entries = []
          @pipeline&.lock&.each_entry { |e| entries << e }
          entries
        end
      end
    end
  end
end
