require "yaml"
require "bundler"
require "rails/hyperdrive/skill_template"

module Rails
  module Hyperdrive
    module BundlerArtifactDiscovery
      SKILL_FILE_NAMES = ["SKILL.md", "SKILL.md.erb"].freeze
      INSTALLER_KEY = /\A(?:gem|versions|conditional):/.freeze

      Artifact = Struct.new(
        :name, :description, :target_gem, :versions, :artifact_type,
        :source_gem, :path, :body, :spec_version, :support_files,
        :source_root, :support_root,
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
      # dropped; discovery never raises. A gem that has not opted in as a
      # companion is never scanned — its skills.sh content is only reported
      # through `notices`.
      def discover(specs: nil, warnings: [], enabled_gems: [], notices: [])
        specs ||= safe_bundler_specs
        enabled = Array(enabled_gems).map(&:to_s)
        resolved = specs.each_with_object({}) { |s, h| h[s.name.to_s] = s.version }

        candidates = []
        specs.each do |spec|
          unless opted_in?(spec, enabled_gems: enabled)
            notice_skills_sh_content(spec, notices: notices)
            next
          end
          each_artifact_path(spec, warnings: warnings) do |path, type, support_root|
            artifact = parse(path, source_spec: spec, type: type, resolved: resolved,
              warnings: warnings, support_root: support_root)
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
        skill_paths(spec, warnings: warnings).each { |path, support_root| yield path, :skill, support_root }
        guideline_paths(spec).each { |p| yield p, :guideline, nil }
      end

      def skill_paths(spec, warnings: [])
        roots = [
          File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive", "skills"),
          File.join(spec.full_gem_path, "skills")
        ]
        if (override = skills_dir_override(spec))
          roots << File.join(spec.full_gem_path, override)
        end

        candidates = []
        seen = {}
        roots.each do |root|
          Dir.glob(File.join(root, "**", "{SKILL.md,SKILL.md.erb}"))
             .group_by { |p| File.dirname(p) }.each do |dir, group|
            next if seen[File.expand_path(dir)]
            seen[File.expand_path(dir)] = true
            candidates << {
              dir: dir,
              rel: dir.delete_prefix(root).delete_prefix("/"),
              path: resolve_same_dir_tie(dir, group, warnings)
            }
          end
        end

        pair_with_templates(candidates, spec, warnings: warnings)
      end

      def resolve_same_dir_tie(dir, group, warnings)
        return group.first unless group.size > 1
        warnings << "skip #{File.join(dir, "SKILL.md.erb")}: SKILL.md in the same directory takes precedence"
        group.find { |p| File.basename(p) == "SKILL.md" }
      end

      # A dir holding a static SKILL.md pairs with <templates root>/<same
      # relative path>/SKILL.md.erb in a distinct dir: the rendered template is
      # the definition, the static dir the support root. The static SKILL.md is
      # never parsed — falling back to it when the template fails to render
      # would silently un-condition the skill.
      def pair_with_templates(candidates, spec, warnings:)
        templates_root = File.join(spec.full_gem_path, skill_templates_dir(spec))

        pairs = {}
        candidates.each do |cand|
          next unless File.basename(cand[:path]) == "SKILL.md"
          template_dir = File.expand_path(File.join(templates_root, cand[:rel]))
          next if template_dir == File.expand_path(cand[:dir])
          template = File.join(template_dir, "SKILL.md.erb")
          next unless File.file?(template)
          warn_template_extras(template_dir, warnings)
          pairs[cand[:dir]] = { template: template, template_dir: template_dir }
        end

        consumed = pairs.values.map { |p| p[:template_dir] }
        candidates.filter_map do |cand|
          if (pair = pairs[cand[:dir]])
            [pair[:template], cand[:dir]]
          elsif consumed.include?(File.expand_path(cand[:dir]))
            nil
          else
            [cand[:path], File.dirname(cand[:path])]
          end
        end
      end

      # The content dir is the single source of truth for supporting files.
      def warn_template_extras(template_dir, warnings)
        extras = Dir.glob(File.join(template_dir, "**", "*"))
                    .select { |f| File.file?(f) && f != File.join(template_dir, "SKILL.md.erb") }
        return if extras.empty?
        warnings << "#{template_dir}: ignoring #{extras.size} file(s) besides SKILL.md.erb; " \
                    "supporting files ship in the paired content directory"
      end

      def guideline_paths(spec)
        root = File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive", "guidelines")
        Dir.glob(File.join(root, "*.md"))
      end

      # Many gemspecs package files via `git ls-files`, so a contributor-facing
      # skills/ dir ships by accident — package contents don't signal consumer
      # intent. Only an explicit signal makes a gem's content installable.
      def opted_in?(spec, enabled_gems:)
        return true if enabled_gems.include?(spec.name.to_s)
        return true if metadata_present?(spec, "rails_hyperdrive_skills_dir")
        return true if metadata_present?(spec, "rails_hyperdrive_skill_templates_dir")
        return true if metadata_present?(spec, "rails_hyperdrive_targets")

        convention_root = File.join(spec.full_gem_path, "lib", spec.name, "hyperdrive")
        Dir.glob(File.join(convention_root, "skills", "**", "{SKILL.md,SKILL.md.erb}")).any? ||
          Dir.glob(File.join(convention_root, "guidelines", "*.md")).any?
      end

      def metadata_present?(spec, key)
        return false unless spec.respond_to?(:metadata)
        raw = spec.metadata && spec.metadata[key]
        !raw.to_s.strip.empty?
      end

      # Report-only, glob-only (no file reads): SKILL.md presence is the
      # signal, and SKILL.md.erb is excluded — raw ERB is not skills.sh
      # content. Parse problems surface as warnings once the gem is enabled.
      def notice_skills_sh_content(spec, notices:)
        found = Dir.glob(File.join(spec.full_gem_path, "skills", "**", "SKILL.md"))
        return if found.empty?

        count = found.map { |p| File.dirname(p) }.uniq.size
        notices << "gem '#{spec.name}' ships #{count} skills.sh skill(s); add \"#{spec.name}\" to enabled: " \
                   "in .hyperdrive/lock.yml and re-run bin/rails hyperdrive:sync to install them"
      end

      # ".." segments are rejected to prevent escaping the gem root.
      def skills_dir_override(spec)
        return nil unless spec.respond_to?(:metadata)
        raw = spec.metadata && spec.metadata["rails_hyperdrive_skills_dir"]
        return nil if raw.nil? || raw.to_s.strip.empty?
        return nil if raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end

      def skill_templates_dir(spec)
        default = File.join("lib", spec.name, "hyperdrive", "skills")
        return default unless spec.respond_to?(:metadata)
        raw = spec.metadata && spec.metadata["rails_hyperdrive_skill_templates_dir"]
        return default if raw.nil? || raw.to_s.strip.empty?
        return default if raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end

      def parse(path, source_spec:, type:, resolved:, warnings:, support_root: nil)
        support_root ||= File.dirname(path)
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

        unless name && description
          warnings << "skip #{path}: missing a required field (name, description)"
          return nil
        end

        # gem:/versions: are narrowing declarations; absence means no
        # constraint. Only a *present* key with an unusable value warns.
        targets = meta.key?("gem") ? parse_targets(meta["gem"]) : ["*"]
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
          source_root: source_spec.full_gem_path.to_s,
          support_root: support_root,
          support_files:
            if type == :skill
              conditioned_support_files(
                support_root, meta["conditional"],
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
        return strip_installer_keys(artifact.body) if artifact.skill?

        _frontmatter, rest = split_frontmatter(artifact.body)
        (rest || artifact.body).sub(/\A\n+/, "")
      end

      # gem:/versions:/conditional: are install-time inputs with no reader
      # after install, and conditional: keys name *shipped* paths that gating
      # and ERB retargeting can leave pointing at files absent from disk — so
      # the installed frontmatter carries neither.
      def strip_installer_keys(body)
        frontmatter, rest = split_frontmatter(body)
        return body unless frontmatter

        kept = []
        skipping = false
        frontmatter.lines.each do |line|
          if line =~ INSTALLER_KEY
            skipping = true
          elsif skipping && (line.start_with?(" ", "\t") || line.strip.empty?)
            # continuation of a stripped key's block
          else
            skipping = false
            kept << line
          end
        end
        "---\n#{kept.join}---\n#{rest}"
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
                           :resolve_same_dir_tie, :pair_with_templates, :warn_template_extras,
                           :opted_in?, :metadata_present?, :notice_skills_sh_content,
                           :skills_dir_override, :skill_templates_dir, :parse, :support_files_for,
                           :conditioned_support_files, :apply_conditional_filter,
                           :conditional_satisfied?, :malformed_requirements?,
                           :render_support_templates, :erb_template?,
                           :strip_installer_keys,
                           :parse_targets, :match_targets,
                           :version_satisfied?, :no_match_reason, :safe_bundler_specs
    end
  end
end
