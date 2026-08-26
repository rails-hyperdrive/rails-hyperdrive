require "bundler"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/skill_template"

module Rails
  module Hyperdrive
    # Best-effort reconstruction of the install-ready body an artifact had at
    # the gem version a lock entry records, read from installed gem
    # directories. The result is sha-gated against the lock entry: anything
    # that does not rebuild to exactly the recorded bytes counts as
    # unavailable.
    module AncestorLocator
      module_function

      # Never raises; any failure returns nil (ancestor unavailable).
      def locate(kind:, relpath:, lock_entry:, final_name: nil, gem_paths: Gem.path, resolved: nil)
        return nil unless lock_entry&.source_gem && lock_entry.source_version && lock_entry.source_sha
        return nil if relpath.nil? || relpath.to_s.empty?

        Array(gem_paths).each do |home|
          gem_root = File.join(home.to_s, "gems", "#{lock_entry.source_gem}-#{lock_entry.source_version}")
          body = read_candidate(gem_root, relpath.to_s, kind: kind, resolved: resolved)
          next unless body

          ready = install_ready(body, kind: kind, final_name: final_name)
          return ready if DriftVerdict.body_sha(ready) == lock_entry.source_sha
        rescue StandardError
          next
        end
        nil
      rescue StandardError
        nil
      end

      def read_candidate(gem_root, relpath, kind:, resolved:)
        exact = File.join(gem_root, relpath)
        if File.file?(exact)
          return kind.to_s == "skill_support" ? File.binread(exact) : File.read(exact)
        end
        return nil unless relpath.end_with?(".md")

        twin = "#{exact}.erb"
        return nil unless File.file?(twin)

        map = resolved || resolved_bundle
        return nil unless map
        SkillTemplate.render(File.read(twin), resolved: map)
      end

      def install_ready(body, kind:, final_name:)
        type = InstallLayout::ARTIFACT_TYPES[kind.to_s]
        descriptor = type && InstallLayout.kind(type)
        return body unless descriptor

        ready = BundlerArtifactDiscovery.install_ready_body(
          BundlerArtifactDiscovery::Artifact.new(artifact_type: type, body: body)
        )
        return ready unless final_name && descriptor.collision_rewrites_name
        ready.sub(/^name:\s*.+$/, "name: #{final_name}")
      end

      def resolved_bundle
        ::Bundler.load.specs.to_a.each_with_object({}) { |s, h| h[s.name.to_s] = s.version }
      rescue StandardError
        nil
      end

      private_class_method :read_candidate, :install_ready, :resolved_bundle
    end
  end
end
