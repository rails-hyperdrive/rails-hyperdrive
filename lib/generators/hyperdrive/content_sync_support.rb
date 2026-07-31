require "rails/hyperdrive"
require "rails/hyperdrive/stack_profile"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/install_pipeline"

module Rails
  module Generators
    module Hyperdrive
      # Thor registers every public method defined directly on a generator
      # class as a runnable command, so these shared helpers must stay in an
      # included module or private.
      module ContentSyncSupport
        KIND_WIDTH = "guideline".length
        KIND_ORDER = %w[skill guideline stack].freeze

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
          # Thor's file-writing helpers honor options[:pretend], so --dry-run maps onto it.
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

        # The lock is the authoritative set: it includes untouched,
        # locally-modified, and orphaned files.
        def print_installed_artifacts
          entries = []
          @pipeline&.lock&.each_entry { |e| entries << e }
          return if entries.empty?

          support, listed = entries.partition { |e| e.kind.to_s == "skill_support" }
          # A carried SKILL.md entry can record an older source than its
          # supporting files, so counts key on the installed directory name,
          # which is unique across sources.
          support_counts = support
            .group_by { |e| ::Rails::Hyperdrive::InstallLayout.installed_name(:skill_support, e.path.to_s) }
            .transform_values(&:size)

          say "  #{installed_counts(listed)}"
          say ""
          group_by_source(listed).each do |source, group|
            say "    #{source}"
            group.each do |entry|
              name = display_name(entry)
              count = entry.kind.to_s == "skill" ? support_counts[name].to_i : 0
              suffix = count.positive? ? " (+#{quantify(count, "file")})" : ""
              say "      #{entry.kind.to_s.ljust(KIND_WIDTH)}  #{name}#{suffix}"
            end
          end
        end

        def installed_counts(entries)
          counts = entries.group_by { |e| e.kind.to_s }.transform_values(&:size)
          summary = "Installed #{quantify(counts["skill"].to_i, "skill")}, #{quantify(counts["guideline"].to_i, "guideline")}"
          counts["stack"].to_i.positive? ? "#{summary} + stack.md" : summary
        end

        def group_by_source(entries)
          entries
            .group_by { |e| e.source_label.to_s }
            .sort_by { |source, group| [group.first.source_gem == "internal" ? 1 : 0, source] }
            .map do |source, group|
              [source, group.sort_by { |e| [KIND_ORDER.index(e.kind.to_s) || KIND_ORDER.size, display_name(e)] }]
            end
        end

        def display_name(entry)
          path = entry.path.to_s
          return File.basename(path) if entry.kind.to_s == "stack"

          # A kind outside the install layout can only come from a hand-edited
          # lock, so it degrades to the filename instead of printing nothing.
          type = ::Rails::Hyperdrive::InstallLayout::ARTIFACT_TYPES[entry.kind.to_s]
          type ? ::Rails::Hyperdrive::InstallLayout.installed_name(type, path) : File.basename(path, ".md")
        end

        def quantify(count, noun)
          "#{count} #{noun}#{"s" unless count == 1}"
        end
      end
    end
  end
end
