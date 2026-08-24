require "yaml"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/gem_manifest"
require "rails/hyperdrive/gemspec_locator"

module Rails
  module Hyperdrive
    # Author-side check of a companion gem's hyperdrive.yml, run in the
    # companion's own repo. Where the installer warns and falls open — so that
    # a manifest written for a newer schema never blocks an install — this
    # fails, and unknown keys fail outright: the author's own rails-hyperdrive
    # is the one that knows the whole schema. A manifest that passes draws no
    # gating warning at install time.
    module ManifestLint
      Error = GemspecLocator::Error

      ROOT_KEYS = %w[gem gems hyperdrive_version skills guidelines].freeze
      SKILL_ENTRY_KEYS = %w[gem gems hyperdrive_version conditional].freeze
      GUIDELINE_ENTRY_KEYS = %w[gem gems hyperdrive_version].freeze
      CONDITIONAL_ENTRY_KEYS = %w[gem gems].freeze
      RETIRED_VERSION_KEYS = %w[versions version].freeze
      RETIRED_VERSION_HINT = "is not a gating key; put the requirement on the gem: member, " \
                             "e.g. `- name: \">= 1.0\"`".freeze

      # `manifest` is nil when the gem ships none, which is legal.
      Result = Struct.new(:manifest, :problems, keyword_init: true)

      # Discovery resolves every root against an installed gem's path; in the
      # companion's repo that is the checkout.
      RepoSpec = Struct.new(:name, :full_gem_path, :metadata, keyword_init: true)

      module_function

      def check(gemspec: nil, dir: Dir.pwd)
        spec, gem_root = GemspecLocator.load_spec(gemspec, dir)
        relpath = GemManifest.manifest_relpath(spec)
        path = File.join(gem_root, relpath)
        return Result.new(manifest: nil, problems: []) unless File.file?(path)

        repo_spec = RepoSpec.new(name: spec.name, full_gem_path: gem_root, metadata: spec.metadata || {})
        Result.new(manifest: relpath, problems: problems_in(path, repo_spec))
      end

      def problems_in(path, repo_spec)
        problems = []
        root = parse_root(path, problems)
        return problems if root.nil?

        check_keys(root, ROOT_KEYS, "top level", problems)
        check_gate(root, "top level", problems)

        skills = shipped_skills(repo_spec)
        each_entry(root, "skills", skills.keys, "skill directory", problems) do |key, entry|
          where = "skills entry '#{key}'"
          check_keys(entry, SKILL_ENTRY_KEYS, where, problems)
          check_gate(entry, where, problems)
          check_conditional(entry["conditional"], where, skills[key], problems) if entry.key?("conditional")
        end

        guidelines = shipped_guidelines(repo_spec)
        each_entry(root, "guidelines", guidelines, "guideline", problems) do |key, entry|
          where = "guidelines entry '#{key}'"
          check_keys(entry, GUIDELINE_ENTRY_KEYS, where, problems)
          check_gate(entry, where, problems)
        end

        problems
      end

      # nil means nothing further is readable; an empty manifest is legal.
      def parse_root(path, problems)
        root = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
        return {} if root.nil?
        return root.transform_keys(&:to_s) if root.is_a?(Hash)

        problems << "root must be a YAML map"
        nil
      rescue Psych::SyntaxError => e
        problems << "malformed YAML (#{e.message})"
        nil
      rescue StandardError => e
        problems << "unreadable (#{e.message})"
        nil
      end

      def each_entry(root, section, shipped, shipped_label, problems)
        value = root[section]
        return if value.nil?
        unless value.is_a?(Hash)
          problems << "#{section}: must be a map of #{shipped_label} keys to gating maps"
          return
        end

        value.each do |key, entry|
          key = key.to_s
          problems << "#{section} entry '#{key}' names no shipped #{shipped_label}" unless shipped.include?(key)
          unless entry.is_a?(Hash)
            problems << "#{section} entry '#{key}' must be a map of gating keys"
            next
          end
          yield key, entry.transform_keys(&:to_s)
        end
      end

      def check_keys(map, allowed, where, problems)
        (map.keys - allowed).each do |key|
          problems << if RETIRED_VERSION_KEYS.include?(key)
            "#{where}: '#{key}:' #{RETIRED_VERSION_HINT}"
          else
            "#{where}: unknown key '#{key}'#{did_you_mean(key, allowed)}; " \
              "allowed keys are #{allowed.join(", ")}"
          end
        end
      end

      def did_you_mean(key, allowed)
        near = allowed.find { |a| a.start_with?(key) || key.start_with?(a) }
        near ? " (did you mean '#{near}'?)" : ""
      end

      # The parse rules come from GemManifest itself, so a form it accepts is
      # never reported here and a form it falls open on always is. A parser
      # warning counts as a failure: it names a spelling that installs, but not
      # as written.
      def check_gate(map, where, problems, fence: true)
        problems << "#{where}: gem: and gems: are aliases; keep only one" if map.key?("gem") && map.key?("gems")

        gem_key = GemManifest.gem_key(map)
        if gem_key.present
          parsed = GemManifest.parse_targets(gem_key.value)
          if parsed.nil? || parsed.targets.empty?
            problems << "#{where}: gem: must name #{GemManifest::GEM_FORMS}"
          elsif parsed.warning
            problems << "#{where}: gem: #{parsed.warning}"
          end
        end

        return unless fence && map.key?("hyperdrive_version")
        return unless GemManifest.malformed_fence?(map["hyperdrive_version"])
        problems << "#{where}: hyperdrive_version: must be a version requirement, e.g. \">= 0.8\""
      end

      # `shipped` is nil when the owning skills entry names no shipped
      # directory, which is already reported — every key would repeat it.
      def check_conditional(value, where, shipped, problems)
        unless value.is_a?(Hash)
          problems << "#{where}: conditional: must be a map of supporting-file path to a gating map"
          return
        end

        value.each do |key, entry|
          key = key.to_s
          inner = "#{where} conditional key '#{key}'"
          if BundlerArtifactDiscovery::SKILL_FILE_NAMES.include?(key)
            problems << "#{inner}: the entry's own gem: gates the whole skill"
          elsif shipped && !shipped.include?(key)
            problems << "#{inner}: names no shipped supporting file"
          end

          unless entry.is_a?(Hash)
            problems << "#{inner}: must be a map with gem:"
            next
          end
          entry = entry.transform_keys(&:to_s)
          check_keys(entry, CONDITIONAL_ENTRY_KEYS, inner, problems)
          check_gate(entry, inner, problems, fence: false)
          problems << "#{inner}: gem: is required" unless GemManifest.gem_key(entry).present
        end
      end

      # Maps each skill's manifest key to the dir-relative paths of its
      # supporting files, as shipped: a template-side file is keyed by its
      # *.md.erb name, the one a conditional: entry names.
      def shipped_skills(repo_spec)
        found = BundlerArtifactDiscovery.skill_paths(repo_spec, warnings: [])
        found.each_with_object({}) do |(path, support_root, rel), h|
          template_dir = File.dirname(path)
          template_dir = nil if File.expand_path(template_dir) == File.expand_path(support_root)
          h[rel] = h.fetch(rel, []) |
                   support_paths(support_root, "**/*") | support_paths(template_dir, "**/*.md.erb")
        end
      end

      def support_paths(root, glob)
        return [] if root.nil?

        Dir.glob(File.join(root, glob)).filter_map do |file|
          next unless File.file?(file)
          rel = file.delete_prefix("#{root}/")
          next if BundlerArtifactDiscovery::SKILL_FILE_NAMES.include?(File.basename(rel))
          rel
        end
      end

      def shipped_guidelines(repo_spec)
        BundlerArtifactDiscovery.guideline_paths(repo_spec).map { |p| File.basename(p) }
      end

      private_class_method :problems_in, :parse_root, :each_entry, :check_keys, :did_you_mean,
                           :check_gate, :check_conditional, :shipped_skills, :support_paths,
                           :shipped_guidelines
    end
  end
end
