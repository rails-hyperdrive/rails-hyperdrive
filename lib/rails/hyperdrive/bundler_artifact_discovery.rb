require "yaml"
require "bundler"
require "rails/hyperdrive/skill_template"

module Rails
  module Hyperdrive
    module BundlerArtifactDiscovery
      SKILL_FILE_NAMES = ["SKILL.md", "SKILL.md.erb"].freeze

      Artifact = Struct.new(
        :name, :description, :target_gem, :versions, :artifact_type,
        :source_gem, :path, :body, :spec_version, :support_files,
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

      # Non-fatal problems are appended to `warnings` and the artifact is
      # dropped; discovery never raises.
      def discover(specs: nil, warnings: [])
        specs ||= safe_bundler_specs
        resolved = specs.each_with_object({}) { |s, h| h[s.name.to_s] = s.version }

        candidates = []
        specs.each do |spec|
          each_artifact_path(spec, warnings: warnings) do |path, type|
            artifact = parse(path, source_spec: spec, type: type, resolved: resolved, warnings: warnings)
            candidates << artifact if artifact
          end
        end

        # Collapse same-name variants within one source gem (highest
        # spec_version, path as tiebreak); never across sources — composite
        # identity is (name, source_gem).
        candidates.group_by { |a| [a.name, a.source_gem, a.artifact_type] }.map do |_key, group|
          group.max_by { |a| [Gem::Version.new(a.spec_version), a.path] }
        end
      end

      def each_artifact_path(spec, warnings: [])
        skill_paths(spec, warnings: warnings).each { |p| yield p, :skill }
        guideline_paths(spec).each { |p| yield p, :guideline }
      end

      def skill_paths(spec, warnings: [])
        roots = [File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive", "skills")]
        if (override = skills_dir_override(spec))
          roots << File.join(spec.full_gem_path, override)
        end
        found = roots.flat_map { |root| Dir.glob(File.join(root, "**", "{SKILL.md,SKILL.md.erb}")) }.uniq
        found.group_by { |p| File.dirname(p) }.flat_map do |dir, group|
          next group unless group.size > 1
          warnings << "skip #{File.join(dir, "SKILL.md.erb")}: SKILL.md in the same directory takes precedence"
          group.select { |p| File.basename(p) == "SKILL.md" }
        end
      end

      def guideline_paths(spec)
        root = File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive", "guidelines")
        Dir.glob(File.join(root, "*.md"))
      end

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
        if erb_template?(path)
          begin
            body = SkillTemplate.render(body, resolved: resolved)
          rescue SyntaxError, StandardError => e
            warnings << "skip #{path}: ERB render failed (#{e.message})"
            return nil
          end
        end
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
          spec_version: source_spec.version.to_s,
          support_files:
            if type == :skill
              conditioned_support_files(
                File.dirname(path), meta["conditional"],
                resolved: resolved, warnings: warnings,
                label: "#{name} (from #{source_spec.name})"
              )
            else
              []
            end
        )
      rescue Psych::SyntaxError
        warnings << "skip #{path}: malformed YAML frontmatter"
        nil
      end

      # Everything in a skill's directory besides SKILL.md(.erb) ships as raw
      # bytes, with no frontmatter contract. ".." segments are rejected to keep
      # the tree inside the skill directory.
      def support_files_for(skill_dir)
        Dir.glob(File.join(skill_dir, "**", "*")).filter_map do |file|
          next unless File.file?(file)
          rel = file.delete_prefix("#{skill_dir}/")
          next if SKILL_FILE_NAMES.include?(File.basename(rel))
          next if rel.split(%r{[/\\]}).include?("..")
          { path: rel, body: File.binread(file) }
        end
      end

      def conditioned_support_files(skill_dir, conditional, resolved:, warnings:, label:)
        files = support_files_for(skill_dir)
        files = apply_conditional_filter(files, conditional, resolved: resolved, warnings: warnings, label: label)
        render_support_templates(files, skill_dir, resolved: resolved, warnings: warnings)
      end

      # Fail-open: a malformed condition warns and installs its file
      # unconditionally — a surplus supporting file is harmless, while a
      # missing one breaks links from SKILL.md.
      def apply_conditional_filter(files, conditional, resolved:, warnings:, label:)
        return files if conditional.nil?
        unless conditional.is_a?(Hash)
          warnings << "#{label}: conditional: must be a map of supporting-file path to {gem:, versions:}; installing all supporting files"
          return files
        end

        conditions = conditional.transform_keys(&:to_s)
        shipped = files.map { |f| f[:path] }
        conditions.each_key do |key|
          if SKILL_FILE_NAMES.include?(key)
            warnings << "#{label}: conditional key '#{key}' ignored; the skill's own gem:/versions: gate the whole skill"
          elsif !shipped.include?(key)
            warnings << "#{label}: conditional key '#{key}' names no shipped supporting file"
          end
        end

        files.select do |file|
          next true unless conditions.key?(file[:path])
          conditional_satisfied?(file[:path], conditions[file[:path]], resolved, warnings: warnings, label: label)
        end
      end

      def conditional_satisfied?(key, entry, resolved, warnings:, label:)
        unless entry.is_a?(Hash)
          warnings << "#{label}: conditional entry for '#{key}' must be a map with gem: (and optional versions:); installing the file"
          return true
        end

        targets = entry["gem"] && parse_targets(entry["gem"])
        if targets.nil? || targets.empty?
          warnings << "#{label}: conditional entry for '#{key}' needs gem: naming a gem, a comma-separated list, or a YAML list; installing the file"
          return true
        end

        versions = entry["versions"]
        if malformed_requirements?(versions)
          warnings << "#{label}: conditional entry for '#{key}' has an unparsable versions: requirement; installing the file"
          return true
        end

        match_targets(targets, versions, resolved).any?
      end

      # versions: is optional in a conditional entry; nil means unconstrained.
      def malformed_requirements?(versions)
        requirements = versions.is_a?(Hash) ? versions.values : [versions]
        requirements.compact.any? do |req|
          parts = Array(req).flat_map { |s| s.is_a?(String) ? s.split(",").map(&:strip) : s }
          begin
            Gem::Requirement.new(*parts)
            false
          rescue ArgumentError
            true
          end
        end
      end

      def render_support_templates(files, skill_dir, resolved:, warnings:)
        plain_paths = files.map { |f| f[:path] }
        files.filter_map do |file|
          next file unless erb_template?(file[:path])

          target = file[:path].delete_suffix(".erb")
          if plain_paths.include?(target)
            warnings << "skip #{File.join(skill_dir, file[:path])}: #{target} in the same directory takes precedence"
            next nil
          end

          begin
            { path: target, body: SkillTemplate.render(file[:body], resolved: resolved) }
          rescue SyntaxError, StandardError => e
            warnings << "skip #{File.join(skill_dir, file[:path])}: ERB render failed (#{e.message})"
            nil
          end
        end
      end

      def erb_template?(path)
        path.end_with?(".md.erb")
      end

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

      def parse_targets(raw)
        entries = raw.is_a?(Array) ? raw : [raw]
        return nil if entries.any? { |e| e.nil? || e.is_a?(Array) || e.is_a?(Hash) }
        entries.flat_map { |e| e.to_s.split(",") }.map(&:strip).reject(&:empty?)
      end

      def match_targets(targets, versions, resolved)
        return ["*"] if targets.include?("*")

        targets.select do |t|
          version = resolved[t]
          version && version_satisfied?(versions, t, version)
        end
      end

      def version_satisfied?(versions, target, version)
        requirement = versions.is_a?(Hash) ? versions[target] : versions
        requirement.nil? || SkillTemplate.version_matches?(requirement, version)
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

      def safe_bundler_specs
        ::Bundler.load.specs.to_a
      rescue ::Bundler::BundlerError
        []
      end

      private_class_method :each_artifact_path, :skill_paths, :guideline_paths,
                           :skills_dir_override, :parse, :support_files_for,
                           :conditioned_support_files, :apply_conditional_filter,
                           :conditional_satisfied?, :malformed_requirements?,
                           :render_support_templates, :erb_template?,
                           :split_frontmatter, :parse_targets, :match_targets,
                           :version_satisfied?, :no_match_reason, :safe_bundler_specs
    end
  end
end
