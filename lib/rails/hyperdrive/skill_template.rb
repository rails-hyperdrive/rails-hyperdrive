require "erb"

module Rails
  module Hyperdrive
    # Renders a skill's *.md.erb sources against the app's resolved bundle.
    # The three helpers are the only supported template API, but the binding is
    # an ordinary object rather than a sandbox: a template runs arbitrary Ruby
    # with the privileges of whoever triggered discovery.
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

      # Canonical render binding: every gem reads as present at any requested
      # version, so an if/elsif/else contributes only its first branch and
      # templates meant for this render must use additive if blocks. There is
      # no bundle to resolve against, so gem_version is nil.
      class CanonicalContext
        def gem?(_name, _requirement = nil)
          true
        end

        def any_gem?(*)
          true
        end

        def gem_version(_name)
          nil
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

      def render_canonical(source)
        ERB.new(source, trim_mode: "-").result(CanonicalContext.new.template_binding)
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
