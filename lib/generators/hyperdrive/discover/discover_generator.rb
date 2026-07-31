require "rails/generators"
require "rails/generators/base"
require "rails/hyperdrive"
require "rails/hyperdrive/companion_discovery"
require "generators/hyperdrive/gitignore_support"

module Rails
  module Generators
    module Hyperdrive
      # Read-only with respect to the app: never edits the Gemfile and never installs gems.
      class DiscoverGenerator < ::Rails::Generators::Base
        include GitignoreSupport

        CACHE_RULE = ::Rails::Hyperdrive::CompanionDiscovery::CACHE_RELATIVE_PATH

        source_root __dir__

        class_option :refresh, type: :boolean, default: false,
          desc: "Ignore the cached results and re-query rubygems."

        def verify_environment
          return if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
          say_status :error, "must be run inside a Rails app", :red
          raise Thor::Error, "hyperdrive: not in a Rails app"
        end

        def ensure_cache_gitignored
          ensure_gitignored(CACHE_RULE)
        end

        def discover_and_report
          result = ::Rails::Hyperdrive::CompanionDiscovery.new(
            lockfile_path: ::Rails.root.join("Gemfile.lock").to_s,
            cache_path: ::Rails.root.join(CACHE_RULE).to_s,
            refresh: options[:refresh]
          ).run

          if result.status == :unavailable
            say_status :unavailable, "rubygems discovery unavailable — #{result.detail}; no cached results", :yellow
            return
          end

          say_status :stale, "rubygems unreachable; showing #{format_age(result.age_seconds)} cached results — #{result.detail}", :yellow if result.status == :stale

          report_suggestions(result.suggestions)
          report_warnings(result.warnings)
        end

        no_tasks do
          def report_suggestions(suggestions)
            if suggestions.empty?
              say_status :none, "no rails-hyperdrive companion gems found for your stack", :blue
              return
            end

            say ""
            say "Found gems with rails-hyperdrive content for your stack:"
            suggestions.each { |s| say "  #{format_line(s)}" }

            to_add = suggestions.reject(&:installed)
            return if to_add.empty?

            say ""
            to_add.each { |s| say "Run: bundle add #{s.gem_name} --group=development" }
            say "Then: bin/rails hyperdrive:init"
          end

          def format_line(suggestion)
            marker = suggestion.installed ? "✓" : "!"
            companion = "#{suggestion.gem_name} #{suggestion.version}"
            lhs =
              if suggestion.matched_target
                "#{suggestion.matched_target} #{suggestion.matched_version}   → #{companion}"
              else
                "#{companion} (applies to any stack)"
              end
            status = suggestion.installed ? "(installed)" : "(suggested)"
            artifacts =
              if suggestion.installed || suggestion.artifacts.empty?
                ""
              else
                " — ships #{suggestion.artifacts.join(" + ")}"
              end
            "#{marker} #{lhs}#{artifacts}  #{status}"
          end

          def report_warnings(warnings)
            return if warnings.empty?
            say ""
            say_status :warn, "discovery skipped #{warnings.size} gem(s):", :yellow
            warnings.each { |w| say "    - #{w}" }
          end

          def format_age(seconds)
            return "cached" unless seconds
            hours = (seconds / 3600.0).round
            hours <= 1 ? "~1h-old" : "~#{hours}h-old"
          end
        end
      end
    end
  end
end
