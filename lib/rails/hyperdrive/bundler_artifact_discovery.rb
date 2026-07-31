require "yaml"
require "bundler"

module Rails
  module Hyperdrive
    # Discovers the two artifact types — skills and guidelines — shipped by any
    # gem in the bundle under the published convention:
    #
    #   <gem-source>/lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md   # skill
    #   <gem-source>/lib/<gem_name>/hyperdrive/guidelines/<name>.md     # guideline
    #
    # Skills additionally honor a `rails_hyperdrive_skills_dir` gemspec metadata
    # override (the union of the convention path and the override path).
    #
    # Each artifact carries YAML frontmatter with four required fields:
    #   name:        kebab-case identity (equals filename/dir stem)
    #   description: single sentence
    #   gem:         the TARGET gems (resolved + version-matched in the bundle)
    #   versions:    Gem::Requirement matched against each target's version
    #
    # Target vs. source: `gem:` names the *targets* — one name, a comma-separated
    # list, or a YAML list. `spec.name` during the walk is the *source*
    # (provenance / audit header / conflict postfix). An artifact matches when
    # ANY declared target is in the bundle at a satisfying version; `target_gem`
    # then carries every target that matched. `"*"` anywhere in the list is
    # universal — no target is resolved and `versions:` is ignored.
    #
    # `versions:` is either one requirement covering every declared target, or a
    # map keyed by gem name constraining each independently; targets absent from
    # the map are unconstrained.
    #
    # The walk returns the Phase-1 survivor set: within a single source gem,
    # same-name variants collapse to the highest spec_version (path as
    # tiebreak). Collapsing ACROSS sources is the installer's job (Phase 2).
    module BundlerArtifactDiscovery
      Artifact = Struct.new(
        :name, :description, :target_gem, :versions, :artifact_type,
        :source_gem, :path, :body, :spec_version,
        keyword_init: true
      ) do
        def skill?
          artifact_type == :skill
        end

        def guideline?
          artifact_type == :guideline
        end

        def to_h
          {
            name: name, description: description, target_gem: target_gem,
            versions: versions, artifact_type: artifact_type,
            source_gem: source_gem, path: path, spec_version: spec_version
          }
        end
      end

      module_function

      # Returns the Phase-1 survivor list of Artifacts. Non-fatal problems
      # (missing target, version mismatch, malformed frontmatter, missing
      # field) are appended to `warnings` rather than raised.
      def discover(specs: nil, warnings: [])
        specs ||= safe_bundler_specs
        resolved = specs.each_with_object({}) { |s, h| h[s.name.to_s] = s.version }

        candidates = []
        specs.each do |spec|
          each_artifact_path(spec) do |path, type|
            artifact = parse(path, source_spec: spec, type: type, resolved: resolved, warnings: warnings)
            candidates << artifact if artifact
          end
        end

        # Phase 1: collapse same-name variants WITHIN one source gem; highest
        # spec_version wins, path as deterministic tiebreak. Never collapse
        # across sources — composite identity is (name, source_gem).
        candidates.group_by { |a| [a.name, a.source_gem, a.artifact_type] }.map do |_key, group|
          group.max_by { |a| [Gem::Version.new(a.spec_version), a.path] }
        end
      end

      # Yields [path, type] for every candidate artifact file shipped by `spec`.
      def each_artifact_path(spec)
        skill_paths(spec).each { |p| yield p, :skill }
        guideline_paths(spec).each { |p| yield p, :guideline }
      end

      def skill_paths(spec)
        roots = [File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive", "skills")]
        if (override = skills_dir_override(spec))
          roots << File.join(spec.full_gem_path, override)
        end
        roots.flat_map { |root| Dir.glob(File.join(root, "**", "SKILL.md")) }.uniq
      end

      def guideline_paths(spec)
        root = File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive", "guidelines")
        Dir.glob(File.join(root, "*.md"))
      end

      # `rails_hyperdrive_skills_dir` relocates skill discovery (skills only).
      # ".." segments are rejected to prevent escaping the gem root.
      def skills_dir_override(spec)
        return nil unless spec.respond_to?(:metadata)
        raw = spec.metadata && spec.metadata["rails_hyperdrive_skills_dir"]
        return nil if raw.nil? || raw.to_s.strip.empty?
        return nil if raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end

      def parse(path, source_spec:, type:, resolved:, warnings:)
        body = File.read(path)
        frontmatter, _rest = split_frontmatter(body)
        unless frontmatter
          warnings << "skip #{path}: missing or malformed frontmatter"
          return nil
        end

        meta        = YAML.safe_load(frontmatter, permitted_classes: [Symbol]) || {}
        name        = meta["name"]
        description = meta["description"]
        versions    = meta["versions"]

        unless name && description && meta["gem"] && versions
          warnings << "skip #{path}: missing a required field (name, description, gem, versions)"
          return nil
        end

        targets = parse_targets(meta["gem"])
        if targets.nil? || targets.empty?
          warnings << "skip #{name} (from #{source_spec.name}): gem: must name a gem, a comma-separated list, or a YAML list"
          return nil
        end

        matched = match_targets(targets, versions, resolved)
        if matched.empty?
          warnings << "skip #{name} (from #{source_spec.name}): #{no_match_reason(targets, versions, resolved)}"
          return nil
        end

        Artifact.new(
          name: name.to_s,
          description: description.to_s,
          target_gem: matched,
          versions: versions,
          artifact_type: type,
          source_gem: source_spec.name.to_s,
          path: path,
          body: body,
          spec_version: source_spec.version.to_s
        )
      rescue Psych::SyntaxError
        warnings << "skip #{path}: malformed YAML frontmatter"
        nil
      end

      # The body as it should be written to disk, before audit-header injection:
      # skills keep their frontmatter; guidelines are stripped to body-only.
      def install_ready_body(artifact)
        return artifact.body if artifact.skill?

        _frontmatter, rest = split_frontmatter(artifact.body)
        (rest || artifact.body).sub(/\A\n+/, "")
      end

      def split_frontmatter(body)
        lines = body.lines
        return [nil, body] unless lines.first&.strip == "---"

        closing_index = lines[1..].index { |l| l.strip == "---" }
        return [nil, body] unless closing_index

        absolute_closing = closing_index + 1
        [lines[1...absolute_closing].join, lines[(absolute_closing + 1)..].join]
      end

      # Returns the declared target names, or nil when an entry is not a scalar.
      def parse_targets(raw)
        entries = raw.is_a?(Array) ? raw : [raw]
        return nil if entries.any? { |e| e.nil? || e.is_a?(Array) || e.is_a?(Hash) }
        entries.flat_map { |e| e.to_s.split(",") }.map(&:strip).reject(&:empty?)
      end

      # Every declared target present in the bundle at a satisfying version, in
      # declaration order. `"*"` short-circuits: universal, no target resolved.
      def match_targets(targets, versions, resolved)
        return ["*"] if targets.include?("*")

        targets.select do |t|
          version = resolved[t]
          version && version_satisfied?(versions, t, version)
        end
      end

      def version_satisfied?(versions, target, version)
        requirement = versions.is_a?(Hash) ? versions[target] : versions
        requirement.nil? || version_matches?(requirement, version)
      end

      def no_match_reason(targets, versions, resolved)
        present = targets.select { |t| resolved.key?(t) }
        if present.empty?
          label = targets.size == 1 ? "target gem" : "target gems"
          "#{label} '#{targets.join(", ")}' not in bundle"
        else
          present.map { |t| "#{t} #{resolved[t]} does not satisfy '#{versions.is_a?(Hash) ? versions[t] : versions}'" }
                 .join("; ")
        end
      end

      # Accepts both YAML list form (versions: [">= 6.0", "< 9.0"]) and the
      # documented single-string comma form (versions: ">= 6.0, < 9.0").
      # Gem::Requirement.new does not parse a single comma-separated string,
      # so split such strings into separate constraints before instantiation.
      def version_matches?(requirement_str, version)
        parts = Array(requirement_str).flat_map { |s| s.is_a?(String) ? s.split(",").map(&:strip) : s }
        Gem::Requirement.new(*parts).satisfied_by?(Gem::Version.new(version.to_s))
      rescue ArgumentError
        false
      end

      def safe_bundler_specs
        ::Bundler.load.specs.to_a
      rescue ::Bundler::BundlerError
        []
      end
    end
  end
end
