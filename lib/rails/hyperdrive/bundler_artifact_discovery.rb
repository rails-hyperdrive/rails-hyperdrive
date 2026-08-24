require "yaml"
require "bundler"
require "rails/hyperdrive/gem_manifest"
require "rails/hyperdrive/skill_template"
require "rails/hyperdrive/version"

module Rails
  module Hyperdrive
    module BundlerArtifactDiscovery
      SKILL_FILE_NAMES = ["SKILL.md", "SKILL.md.erb"].freeze

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

      # Everything one discovery walk collects, passed in so a caller reads
      # back only what it needs. `skips` is the subset of `warnings` that
      # dropped shipped content; everything else is advisory and installed.
      # `bundled_gems` and `skipped_gems` report the walk itself: every gem
      # seen, and every gem that lost at least one artifact to a hard skip.
      Report = Struct.new(:warnings, :skips, :notices, :fence_warnings, :bundled_gems, :skipped_gems,
        keyword_init: true) do
        def initialize(**kw)
          super(**{ warnings: [], skips: [], notices: [], fence_warnings: [],
                    bundled_gems: [], skipped_gems: [] }.merge(kw))
        end

        def warn(message)
          warnings << message
        end

        def skip(message)
          warnings << message
          skips << message
        end

        # Version-fence skips are also carried on their own, for surfaces that
        # print nothing else about discovery.
        def fence(message)
          skip(message)
          fence_warnings << message
        end

        def advisories
          warnings - skips
        end

        def mark_skipped_gem(name)
          skipped_gems << name unless skipped_gems.include?(name)
        end
      end

      module_function

      # Non-fatal problems are reported and the artifact is dropped; discovery
      # never raises. A gem that has not opted in as a companion is never
      # scanned — its skills.sh content is only reported through `notices`.
      def discover(specs: nil, enabled_gems: [], report: Report.new)
        specs ||= safe_bundler_specs
        enabled = Array(enabled_gems).map(&:to_s)
        resolved = specs.each_with_object({}) { |s, h| h[s.name.to_s] = s.version }

        candidates = []
        specs.each do |spec|
          report.bundled_gems << spec.name.to_s
          unless opted_in?(spec, enabled_gems: enabled)
            notice_skills_sh_content(spec, report: report)
            next
          end
          manifest = GemManifest.load(spec, warnings: report.warnings)
          seen = { skill: [], guideline: [] }
          each_artifact_path(spec, report: report) do |path, type, support_root, key|
            seen[type] << key
            gate = type == :skill ? manifest.skill_gate(key) : manifest.guideline_gate(key)
            artifact = parse(path, source_spec: spec, type: type, resolved: resolved,
              report: report, support_root: support_root, gate: gate, key: key)
            if artifact.is_a?(Artifact)
              candidates << artifact
            elsif artifact != :gate_miss
              report.mark_skipped_gem(spec.name.to_s)
            end
          end
          warn_unknown_manifest_keys(manifest, spec, seen, report)
        end

        # Collapse same-name variants within one source gem (highest
        # spec_version, path as tiebreak); never across sources — composite
        # identity is (name, source_gem).
        candidates.group_by { |a| [a.name, a.source_gem, a.artifact_type] }.map do |_key, group|
          group.max_by { |a| [Gem::Version.new(a.spec_version), a.path] }
        end
      end

      # Yields each candidate with its manifest join key: a skill's relpath
      # from its skills root, a guideline's filename. Keys are collected before
      # parsing, so a candidate later dropped (e.g. an ERB render failure)
      # still counts as known to the manifest.
      def each_artifact_path(spec, report:)
        skill_paths(spec, report: report).each { |path, support_root, rel| yield path, :skill, support_root, rel }
        guideline_paths(spec).each { |p| yield p, :guideline, nil, File.basename(p) }
      end

      # The staleness signal for gating detached from content: an entry
      # matching nothing means a renamed or removed skill dir/guideline.
      def warn_unknown_manifest_keys(manifest, spec, seen, report)
        (manifest.skill_keys - seen[:skill]).each do |key|
          report.warn "#{spec.name}: manifest skills entry '#{key}' names no shipped skill directory"
        end
        (manifest.guideline_keys - seen[:guideline]).each do |key|
          report.warn "#{spec.name}: manifest guidelines entry '#{key}' names no shipped guideline"
        end
      end

      def skill_paths(spec, report: Report.new)
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
              path: resolve_same_dir_tie(dir, group, report)
            }
          end
        end

        pair_with_templates(candidates, spec, report: report)
      end

      def resolve_same_dir_tie(dir, group, report)
        return group.first unless group.size > 1
        report.skip "skip #{File.join(dir, "SKILL.md.erb")}: SKILL.md in the same directory takes precedence"
        group.find { |p| File.basename(p) == "SKILL.md" }
      end

      # A dir holding a static SKILL.md pairs with <templates root>/<same
      # relative path>/SKILL.md.erb in a distinct dir: the rendered template is
      # the definition, the static dir the support root. The static SKILL.md is
      # never parsed — falling back to it when the template fails to render
      # would silently un-condition the skill.
      def pair_with_templates(candidates, spec, report:)
        templates_root = File.join(spec.full_gem_path, skill_templates_dir(spec))

        pairs = {}
        candidates.each do |cand|
          next unless File.basename(cand[:path]) == "SKILL.md"
          template_dir = File.expand_path(File.join(templates_root, cand[:rel]))
          next if template_dir == File.expand_path(cand[:dir])
          template = File.join(template_dir, "SKILL.md.erb")
          next unless File.file?(template)
          warn_template_extras(template_dir, report)
          pairs[cand[:dir]] = { template: template, template_dir: template_dir }
        end

        consumed = pairs.values.map { |p| p[:template_dir] }
        candidates.filter_map do |cand|
          if (pair = pairs[cand[:dir]])
            [pair[:template], cand[:dir], cand[:rel]]
          elsif consumed.include?(File.expand_path(cand[:dir]))
            nil
          else
            [cand[:path], File.dirname(cand[:path]), cand[:rel]]
          end
        end
      end

      # The template dir holds only templates; static content is the paired
      # content dir's to ship.
      def warn_template_extras(template_dir, report)
        extras = Dir.glob(File.join(template_dir, "**", "*"))
                    .select { |f| File.file?(f) && !erb_template?(f) }
        return if extras.empty?
        report.warn "#{template_dir}: ignoring #{extras.size} file(s) besides SKILL.md.erb and " \
          "supporting *.md.erb templates; static supporting files ship in the paired content directory"
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
        return true if metadata_present?(spec, "hyperdrive_skills_dir")
        return true if metadata_present?(spec, "hyperdrive_skill_templates_dir")
        return true if metadata_present?(spec, "hyperdrive_targets")
        return true if GemManifest.opt_in?(spec)

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
      def notice_skills_sh_content(spec, report:)
        found = Dir.glob(File.join(spec.full_gem_path, "skills", "**", "SKILL.md"))
        return if found.empty?

        count = found.map { |p| File.dirname(p) }.uniq.size
        report.notices << "gem '#{spec.name}' ships #{count} skills.sh skill(s); add \"#{spec.name}\" to enabled: " \
                          "in .hyperdrive/lock.yml and re-run bin/rails hyperdrive:sync to install them"
      end

      # ".." segments are rejected to prevent escaping the gem root.
      def skills_dir_override(spec)
        return nil unless spec.respond_to?(:metadata)
        raw = spec.metadata && spec.metadata["hyperdrive_skills_dir"]
        return nil if raw.nil? || raw.to_s.strip.empty?
        return nil if raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end

      def skill_templates_dir(spec)
        default = File.join("lib", spec.name, "hyperdrive", "skills")
        return default unless spec.respond_to?(:metadata)
        raw = spec.metadata && spec.metadata["hyperdrive_skill_templates_dir"]
        return default if raw.nil? || raw.to_s.strip.empty?
        return default if raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end

      # Frontmatter's schema is exactly name and description; any other key is
      # unknown to the parser and rides untouched in the installed body.
      # Returns the Artifact, :gate_miss when a well-formed gate simply does
      # not match the bundle, or nil for a hard skip.
      def parse(path, source_spec:, type:, resolved:, report:, gate:, key:, support_root: nil)
        support_root ||= File.dirname(path)
        body = File.read(path)
        if erb_template?(path)
          begin
            body = SkillTemplate.render(body, resolved: resolved)
          rescue SyntaxError, StandardError => e
            # A template reaching for a helper this installer lacks raises
            # here, and the fence is the only thing the user can act on.
            if (required = unmet_fence(gate))
              report.fence fence_message(type, key, source_spec, required)
            else
              report.skip "skip #{path}: ERB render failed (#{e.message})"
            end
            return nil
          end
        end
        frontmatter, _rest = split_frontmatter(body)
        unless frontmatter
          report.skip "skip #{path}: missing or malformed frontmatter"
          return nil
        end

        # Date is permitted because unknown frontmatter keys are user content;
        # a bare date value must not fail the parse.
        meta        = YAML.safe_load(frontmatter, permitted_classes: [Symbol, Date]) || {}
        name        = meta["name"]
        description = meta["description"]

        unless name && description
          report.skip "skip #{path}: missing a required field (name, description)"
          return nil
        end

        # The fence is decided before the bundle gate so a fenced-out artifact
        # reports the one thing the user can act on.
        if (required = unmet_fence(gate))
          report.fence fence_message(type, name, source_spec, required)
          return nil
        end

        matched = match_targets(gate.targets, gate.versions, resolved, mode: gate.match_mode)
        if matched.empty?
          reason = no_match_reason(gate.targets, gate.versions, resolved, mode: gate.match_mode)
          report.skip "skip #{name} (from #{source_spec.name}): #{reason}"
          return :gate_miss
        end

        Artifact.new(
          name: name.to_s,
          description: description.to_s,
          target_gem: matched,
          versions: gate.versions,
          artifact_type: type,
          source_gem: source_spec.name.to_s,
          path: path,
          body: body,
          spec_version: source_spec.version.to_s,
          source_root: source_spec.full_gem_path.to_s,
          support_root: support_root,
          support_files:
            if type == :skill
              skill_support_files(
                path, support_root, gate.conditional,
                source_spec: source_spec, resolved: resolved, report: report,
                label: "#{name} (from #{source_spec.name})"
              )
            else
              []
            end
        )
      rescue Psych::Exception
        report.skip "skip #{path}: malformed YAML frontmatter"
        nil
      end

      def fence_message(type, label, source_spec, required)
        "#{type} '#{label}' (from #{source_spec.name}) requires rails-hyperdrive #{required} " \
          "(this is #{Rails::Hyperdrive::VERSION}); upgrade rails-hyperdrive to install it"
      end

      # Dir-relative paths of everything under `root` besides SKILL.md(.erb).
      # ".." segments are rejected to keep the tree inside that directory.
      def support_relpaths(root, glob: "**/*")
        return [] if root.nil?

        Dir.glob(File.join(root, glob)).filter_map do |file|
          next unless File.file?(file)
          rel = file.delete_prefix("#{root}/")
          next if SKILL_FILE_NAMES.include?(File.basename(rel))
          next if rel.split(%r{[/\\]}).include?("..")
          rel
        end
      end

      # nil when the definition file sits in the support root, i.e. the skill
      # is not template-paired.
      def template_dir_for(path, support_root)
        dir = File.dirname(path)
        dir unless File.expand_path(dir) == File.expand_path(support_root)
      end

      # Supporting files ship as raw bytes, with no frontmatter contract.
      def support_files_for(skill_dir)
        support_relpaths(skill_dir).map do |rel|
          { path: rel, body: File.binread(File.join(skill_dir, rel)), root: skill_dir }
        end
      end

      def template_support_files(template_dir)
        support_relpaths(template_dir, glob: "**/*.md.erb").map do |rel|
          { path: rel, body: File.binread(File.join(template_dir, rel)), root: template_dir, template: true }
        end
      end

      def skill_support_files(path, support_root, conditional, source_spec:, resolved:, report:, label:)
        conditioned_support_files(
          support_root, conditional,
          resolved: resolved, report: report, label: label,
          template_dir: template_dir_for(path, support_root), source_root: source_spec.full_gem_path,
          public_root: public_support_root?(source_spec, support_root)
        )
      end

      def conditioned_support_files(skill_dir, conditional, resolved:, report:, label:,
                                    template_dir:, source_root:, public_root:)
        content = support_files_for(skill_dir)
        templates = template_support_files(template_dir)
        warn_public_support_templates(content, skill_dir, report) if public_root

        # A template-side file owns its target path whatever its own outcome:
        # installing the content-side face when the template is gated out or
        # fails to render would silently un-condition the file.
        claimed = templates.map { |f| target_path(f[:path]) }
        files = apply_conditional_filter(content + templates, conditional,
          resolved: resolved, report: report, label: label)
        files = files.reject { |f| !f[:template] && claimed.include?(target_path(f[:path])) }

        render_support_templates(files, resolved: resolved, report: report, source_root: source_root)
      end

      # Everything under a public skills root is copied verbatim by generic
      # skills.sh consumers, so a template there hands them raw ERB.
      def warn_public_support_templates(files, skill_dir, report)
        return if files.none? { |f| erb_template?(f[:path]) }
        report.warn "#{skill_dir}: supporting *.md.erb template(s) sit under a public skills root; " \
          "move them to the paired template directory and commit their rendered faces here"
      end

      def public_support_root?(spec, support_root)
        dir = "#{File.expand_path(support_root)}/"
        templates_root = File.join(spec.full_gem_path, skill_templates_dir(spec))
        return false if dir.start_with?("#{File.expand_path(templates_root)}/")

        roots = [File.join(spec.full_gem_path, "skills")]
        if (override = skills_dir_override(spec))
          roots << File.join(spec.full_gem_path, override)
        end
        roots.any? { |root| dir.start_with?("#{File.expand_path(root)}/") }
      end

      # Fail-open: a malformed condition warns and installs its file
      # unconditionally — a surplus supporting file is harmless, while a
      # missing one breaks links from SKILL.md.
      def apply_conditional_filter(files, conditional, resolved:, report:, label:)
        return files if conditional.nil?
        unless conditional.is_a?(Hash)
          report.warn "#{label}: conditional: must be a map of supporting-file path to a gating map; installing all supporting files"
          return files
        end

        conditions = conditional.transform_keys(&:to_s)
        shipped = files.flat_map { |f| [f[:path], target_path(f[:path])] }
        conditions.each_key do |key|
          if SKILL_FILE_NAMES.include?(key)
            report.warn "#{label}: conditional key '#{key}' ignored; the entry's own gem: gates the whole skill"
          elsif !shipped.include?(key)
            report.warn "#{label}: conditional key '#{key}' names no shipped supporting file"
          end
        end

        files.select do |file|
          key = condition_key_for(file[:path], conditions, report: report, label: label)
          next true unless key
          conditional_satisfied?(key, conditions[key], resolved, report: report, label: label)
        end
      end

      # A template-backed file may be keyed by its shipped *.md.erb name or by
      # the rendered face it installs as; the exact spelling wins when a
      # manifest carries both.
      def condition_key_for(path, conditions, report:, label:)
        face = target_path(path)
        return conditions.key?(path) ? path : nil if face == path

        if conditions.key?(path)
          if conditions.key?(face)
            report.warn "#{label}: conditional keys '#{path}' and '#{face}' both gate '#{face}'; using '#{path}'"
          end
          return path
        end
        face if conditions.key?(face)
      end

      def conditional_satisfied?(key, entry, resolved, report:, label:)
        unless entry.is_a?(Hash)
          report.warn "#{label}: conditional entry for '#{key}' must be a map with gem:; installing the file"
          return true
        end

        entry = entry.transform_keys(&:to_s)
        gem_key = GemManifest.gem_key(entry)
        report.warn "#{label}: conditional entry for '#{key}': #{gem_key.warning}" if gem_key.warning

        parsed = gem_key.present ? GemManifest.parse_targets(gem_key.value) : nil
        if parsed.nil? || parsed.targets.empty?
          report.warn "#{label}: conditional entry for '#{key}' needs gem: naming #{GemManifest::GEM_FORMS}; installing the file"
          return true
        end
        report.warn "#{label}: conditional entry for '#{key}': #{GemManifest::VERSIONS_REMOVED}" if entry.key?("versions")
        report.warn "#{label}: conditional entry for '#{key}' gem: #{parsed.warning}" if parsed.warning

        match_targets(parsed.targets, parsed.versions, resolved, mode: parsed.match_mode).any?
      end

      def render_support_templates(files, resolved:, report:, source_root: nil)
        plain_paths = files.map { |f| f[:path] }
        files.filter_map do |file|
          next { path: file[:path], body: file[:body] } unless erb_template?(file[:path])

          target = target_path(file[:path])
          if plain_paths.include?(target)
            report.skip "skip #{File.join(file[:root], file[:path])}: #{target} in the same directory takes precedence"
            next nil
          end

          begin
            rendered = { path: target, body: SkillTemplate.render(file[:body], resolved: resolved) }
          rescue SyntaxError, StandardError => e
            report.skip "skip #{File.join(file[:root], file[:path])}: ERB render failed (#{e.message})"
            next nil
          end
          file[:template] ? rendered.merge(source_relpath: template_relpath(file, source_root)) : rendered
        end
      end

      # The relpath a later merge reconstructs the ancestor from: template-side,
      # and .erb-stripped so AncestorLocator's twin fallback resolves it.
      def template_relpath(file, source_root)
        return nil if source_root.nil? || source_root.to_s.empty?

        prefix = "#{File.expand_path(source_root.to_s)}/"
        dir = File.expand_path(file[:root].to_s)
        return nil unless dir.start_with?(prefix)
        target_path(File.join(dir.delete_prefix(prefix), file[:path]))
      end

      def erb_template?(path)
        path.end_with?(".md.erb")
      end

      def target_path(path)
        erb_template?(path) ? path.delete_suffix(".erb") : path
      end

      # Guideline frontmatter is stripped because the installed file is
      # @-included eagerly into agent context, where it would be inert noise.
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

      # Compares against the running installer's own version rather than the
      # bundle, so content depending on an installer feature stays out of apps
      # whose rails-hyperdrive cannot honor it. Returns the unmet requirement
      # for the warning, or nil when the fence is absent or satisfied.
      def unmet_fence(gate)
        return nil if gate.hyperdrive_version.nil?

        parts = GemManifest.requirement_parts(gate.hyperdrive_version)
        return nil if Gem::Requirement.new(*parts).satisfied_by?(Gem::Version.new(Rails::Hyperdrive::VERSION))
        parts.join(", ")
      end

      def match_targets(targets, versions, resolved, mode: :any)
        return ["*"] if targets.include?("*")

        matched = targets.select do |t|
          version = resolved[t]
          version && version_satisfied?(versions, t, version)
        end
        return matched unless mode == :all
        matched.size == targets.size ? matched : []
      end

      def version_satisfied?(versions, target, version)
        requirement = requirement_for(versions, target)
        requirement.nil? || SkillTemplate.version_matches?(requirement, version)
      end

      def requirement_for(versions, target)
        versions.is_a?(Hash) ? versions[target] : versions
      end

      def no_match_reason(targets, versions, resolved, mode: :any)
        return all_no_match_reason(targets, versions, resolved) if mode == :all

        present = targets.select { |t| resolved.key?(t) }
        if present.empty?
          label = targets.size == 1 ? "target gem" : "target gems"
          "#{label} '#{targets.join(", ")}' not in bundle"
        else
          present.map { |t| unsatisfied_reason(t, versions, resolved) }.join("; ")
        end
      end

      def all_no_match_reason(targets, versions, resolved)
        present, missing = targets.partition { |t| resolved.key?(t) }
        reasons = []
        unless missing.empty?
          label = missing.size == 1 ? "required target gem" : "required target gems"
          reasons << "#{label} '#{missing.join(", ")}' not in bundle"
        end
        present.each do |t|
          next if version_satisfied?(versions, t, resolved[t])
          reasons << unsatisfied_reason(t, versions, resolved)
        end
        reasons.join("; ")
      end

      def unsatisfied_reason(target, versions, resolved)
        "#{target} #{resolved[target]} does not satisfy '#{requirement_for(versions, target)}'"
      end

      def safe_bundler_specs
        ::Bundler.load.specs.to_a
      rescue ::Bundler::BundlerError
        []
      end

      private_class_method :each_artifact_path, :warn_unknown_manifest_keys,
                           :resolve_same_dir_tie, :pair_with_templates, :warn_template_extras,
                           :opted_in?, :metadata_present?, :notice_skills_sh_content,
                           :skills_dir_override, :skill_templates_dir, :parse, :fence_message,
                           :erb_template?, :support_files_for,
                           :template_support_files, :skill_support_files,
                           :conditioned_support_files, :warn_public_support_templates,
                           :public_support_root?, :apply_conditional_filter,
                           :condition_key_for, :conditional_satisfied?,
                           :render_support_templates, :template_relpath,
                           :unmet_fence, :match_targets,
                           :version_satisfied?, :requirement_for, :no_match_reason,
                           :all_no_match_reason, :unsatisfied_reason, :safe_bundler_specs
    end
  end
end
