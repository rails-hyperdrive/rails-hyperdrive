require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_layout"

module Rails
  module Hyperdrive
    # A name shipped by one source installs at its canonical path; a name
    # shipped by several installs every variant, postfixed --<source_gem>.
    module InstallPlan
      Entry = Struct.new(:type, :artifact, :final_name, :dest, :collision, keyword_init: true) do
        # The renamed name: is part of the hashed body, so a postfixed artifact
        # hashes to a stable value.
        def install_ready_body
          body = BundlerArtifactDiscovery.install_ready_body(artifact)
          return body unless kind&.collision_rewrites_name && final_name != artifact.name
          body.sub(/^name:\s*.+$/, "name: #{final_name}")
        end

        def support_files
          return [] unless kind&.dir_shaped?
          dir = File.dirname(dest)
          Array(artifact.support_files).map do |file|
            { path: file[:path], body: file[:body], dest: "#{dir}/#{file[:path]}",
              source_relpath: file[:source_relpath] }
          end
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

        def kind
          InstallLayout.kind(type)
        end
      end

      Result = Struct.new(:entries, :disabled, keyword_init: true)

      module_function

      # A collision installs under a postfixed name, so the shipped name
      # disables every variant and a postfixed name disables just one. The
      # postfixed form is honored whether or not a collision exists today, so
      # the opt-out survives a collision appearing or resolving.
      def build(artifacts, lock: nil)
        result = Result.new(entries: [], disabled: [])
        artifacts.group_by { |a| [a.artifact_type, a.name] }.each do |(type, name), group|
          collision = group.size > 1
          group.each do |artifact|
            final_name = collision ? InstallLayout.postfixed_name(name, artifact.source_gem) : name
            entry = Entry.new(
              type: type,
              artifact: artifact,
              final_name: final_name,
              dest: InstallLayout.dest_for(type, final_name),
              collision: collision
            )
            dropped = lock && (lock.disabled?(type, name) ||
                               lock.disabled?(type, InstallLayout.postfixed_name(name, artifact.source_gem)))
            (dropped ? result.disabled : result.entries) << entry
          end
        end
        result
      end

      # A supporting file is disabled through its owning skill's name. Given the
      # installing gem, a canonically-installed file also answers to the
      # postfixed name that disabled it while it was one of several variants.
      def disabled_dest?(lock, type, dest, source_gem: nil)
        name = InstallLayout.installed_name(type, dest)
        return false unless name
        lookup = type == :skill_support ? :skill : type
        base = InstallLayout.base_name(name)
        return true if lock.disabled?(lookup, name) || lock.disabled?(lookup, base)
        !source_gem.nil? && lock.disabled?(lookup, InstallLayout.postfixed_name(base, source_gem))
      end
    end
  end
end
