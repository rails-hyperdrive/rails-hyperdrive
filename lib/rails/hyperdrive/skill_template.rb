require "erb"
require "rails/hyperdrive/bundler_artifact_discovery"

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
          requirement.nil? || BundlerArtifactDiscovery.version_matches?(requirement, version)
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
    end
  end
end
