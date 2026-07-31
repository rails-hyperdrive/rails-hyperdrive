require "rails/hyperdrive"
require "rails/hyperdrive/stack_profile"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_pipeline"

module Rails
  module Generators
    module Hyperdrive
      # Content plumbing for generators that drive InstallPipeline: environment
      # verification, stack parsing, artifact discovery, the pipeline
      # invocation, and the lock-derived summary listing.
      #
      # Included as a module, so its methods are NOT registered as Thor
      # commands (Thor's `method_added` hook fires only for methods defined
      # directly on the generator class). Each generator declares its own
      # ordered public step methods and delegates here.
      module ContentSyncSupport
        KIND_WIDTH = "guideline".length
        KIND_ORDER = %w[skill guideline stack].freeze
        INTERNAL_SOURCE_PREFIX = "internal@".freeze

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

          def say_status(kind, message, color = nil)
            @generator.say_status(kind, message, color)
          end

          def say(message = "")
            @generator.say(message)
          end
        end

        private

        def ensure_rails_development!
          unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
            say_status :error, "must be run inside a Rails app", :red
            raise Thor::Error, "hyperdrive: not in a Rails app"
          end
          unless ::Rails.respond_to?(:env) && ::Rails.env.development?
            env = ::Rails.respond_to?(:env) ? ::Rails.env.to_s : "unknown"
            warn "hyperdrive: must run with Rails.env=development (current: #{env})"
            raise Thor::Error, "hyperdrive: refuse to run outside development (Rails.env=#{env})"
          end
          # Thor's create_file / inject_into_file / append_to_file all honor
          # `options[:pretend]`. Translate our user-facing --dry-run to that.
          if options[:dry_run]
            self.options = options.merge(pretend: true).freeze
          end
        end

        def load_stack_profile
          @stack_profile = ::Rails::Hyperdrive::StackProfile.from_lockfile(
            ::Rails.root.join("Gemfile.lock").to_s,
            app_root: ::Rails.root.to_s
          )
        end

        def discover_bundle_artifacts
          @warnings = []
          @artifacts = ::Rails::Hyperdrive::BundlerArtifactDiscovery.discover(warnings: @warnings)
        end

        def run_install_pipeline(mode:)
          @pipeline = ::Rails::Hyperdrive::InstallPipeline.new(
            root: ::Rails.root.to_s,
            shell: ThorShell.new(self),
            artifacts: @artifacts,
            stack: stack,
            mode: mode,
            warnings: @warnings
          )
          @pipeline.call
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
