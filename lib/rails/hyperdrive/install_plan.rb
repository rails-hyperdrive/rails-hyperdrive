require "rails/hyperdrive/bundler_artifact_discovery"

module Rails
  module Hyperdrive
    # Phase 2 of the dedup contract: a name shipped by one source installs at
    # its canonical path; a name shipped by several installs every variant,
    # postfixed --<source_gem>.
    module InstallPlan
      Entry = Struct.new(:type, :artifact, :final_name, :dest, :collision, keyword_init: true) do
        # Both the installer and the lockfile comparison hash this, so a
        # postfixed skill's renamed `name:` has to be part of it.
        def install_ready_body
          body = BundlerArtifactDiscovery.install_ready_body(artifact)
          return body unless type == :skill && final_name != artifact.name
          body.sub(/^name:\s*.+$/, "name: #{final_name}")
        end

        def source_gem
          artifact.source_gem
        end

        def version
          artifact.spec_version
        end

        def source_label
          "#{source_gem}@#{version}"
        end

        def artifact_kind
          type.to_s
        end
      end

      module_function

      # A collision installs under a postfixed name, so the shipped name
      # disables every variant and a postfixed name disables just one.
      def build(artifacts, lock: nil)
        artifacts.group_by { |a| [a.artifact_type, a.name] }.flat_map do |(type, name), group|
          next [] if lock&.disabled?(type, name)

          collision = group.size > 1
          group.filter_map do |artifact|
            final_name = collision ? "#{name}--#{artifact.source_gem}" : name
            next if collision && lock&.disabled?(type, final_name)

            Entry.new(
              type: type,
              artifact: artifact,
              final_name: final_name,
              dest: dest_for(type, final_name),
              collision: collision
            )
          end
        end
      end

      def dest_for(type, final_name)
        case type
        when :skill     then ".claude/skills/#{final_name}/SKILL.md"
        when :guideline then ".claude/hyperdrive/guidelines/#{final_name}.md"
        end
      end

      def installed_name(type, dest)
        case type
        when :skill     then File.basename(File.dirname(dest))
        when :guideline then File.basename(dest, ".md")
        end
      end

      # An installed path carries the postfixed name, so the shipped name has to
      # match it too.
      def disabled_dest?(lock, type, dest)
        name = installed_name(type, dest)
        return false unless name
        lock.disabled?(type, name) || lock.disabled?(type, name.split("--").first.to_s)
      end
    end
  end
end
