require "erb"

module Rails
  module Hyperdrive
    # Renders a skill's *.md.erb sources against the app's resolved bundle.
    # The template binding is sealed: exactly three helpers over the resolved
    # {gem name => Gem::Version} map, no app context, no arbitrary lookup.
    module SkillTemplate
      class Context
        def initialize(resolved)
          @resolved = resolved
        end

        def gem?(name, requirement = nil)
          version = @resolved[name.to_s]
          return false unless version
          requirement.nil? || SkillTemplate.version_matches?(requirement, version)
        end

        def any_gem?(*names)
          names.any? { |n| @resolved.key?(n.to_s) }
        end

        def gem_version(name)
          version = @resolved[name.to_s]
          version&.to_s
        end

        def template_binding
          binding
        end
      end

      module_function

      # Errors (ERB SyntaxError included) propagate; the caller decides how to
      # skip and warn.
      def render(source, resolved:)
        ERB.new(source, trim_mode: "-").result(Context.new(resolved).template_binding)
      end

      # Gem::Requirement.new does not parse a single comma-separated string, so
      # such strings are split into separate constraints first.
      def version_matches?(requirement_str, version)
        parts = Array(requirement_str).flat_map { |s| s.is_a?(String) ? s.split(",").map(&:strip) : s }
        Gem::Requirement.new(*parts).satisfied_by?(Gem::Version.new(version.to_s))
      rescue ArgumentError
        false
      end
    end
  end
end
