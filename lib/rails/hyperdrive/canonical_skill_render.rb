require "fileutils"
require "yaml"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/gem_manifest"
require "rails/hyperdrive/gemspec_locator"
require "rails/hyperdrive/skill_template"

module Rails
  module Hyperdrive
    # Renders each SKILL.md.erb template in a companion gem repo to the static
    # SKILL.md it pairs with, using the canonical fail-open binding.
    # Companion-repo dev tooling: problems raise.
    module CanonicalSkillRender
      Error = GemspecLocator::Error

      PUBLIC_SKILLS_DIR = "skills".freeze

      Rendered = Struct.new(:template, :dest, :body, keyword_init: true)

      # `public_skills_root` is where generic skills.sh consumers read whether
      # or not the gem declares a content root; `skills_root` is where this
      # gem's rendered faces belong.
      Roots = Struct.new(:skills_root, :templates_root, :public_skills_root, keyword_init: true)

      module_function

      # Resolved once per task so a check does not load the gemspec twice.
      def resolve_roots(gemspec: nil, dir: Dir.pwd)
        spec, gem_root = GemspecLocator.load_spec(gemspec, dir)
        path = File.join(gem_root, GemManifest.manifest_relpath(spec))
        # Rendering with default roots over a manifest the installer cannot
        # read would mask the bug this surface exists to catch.
        manifest, failure = GemManifest.read_root(path)
        raise Error, "#{path}: #{failure}" if failure

        Roots.new(
          skills_root: File.join(gem_root, manifest_dir(manifest, "skills_dir", path) || PUBLIC_SKILLS_DIR),
          templates_root: File.join(gem_root, manifest_dir(manifest, "skill_templates_dir", path) ||
            File.join("lib", spec.name, "hyperdrive", "skills")),
          public_skills_root: File.join(gem_root, PUBLIC_SKILLS_DIR)
        )
      end

      def manifest_dir(manifest, key, path)
        value, failure = GemManifest.read_dir(manifest, key)
        raise Error, "#{path}: #{failure}" if failure
        value
      end

      def write(gemspec: nil, dir: Dir.pwd, roots: nil)
        render_all(gemspec: gemspec, dir: dir, roots: roots).each do |r|
          FileUtils.mkdir_p(File.dirname(r.dest))
          File.write(r.dest, r.body)
        end
      end

      def stale(gemspec: nil, dir: Dir.pwd, roots: nil)
        render_all(gemspec: gemspec, dir: dir, roots: roots).reject do |r|
          File.file?(r.dest) && File.read(r.dest) == r.body
        end
      end

      def render_all(gemspec: nil, dir: Dir.pwd, roots: nil)
        roots ||= resolve_roots(gemspec: gemspec, dir: dir)
        templates_root = roots.templates_root

        Dir.glob(File.join(templates_root, "**", "SKILL.md.erb")).sort.flat_map do |template|
          rel = File.dirname(template).delete_prefix(templates_root).delete_prefix("/")
          dest_dir = File.join(roots.skills_root, rel)
          # A SKILL.md written beside the SKILL.md.erb would take precedence
          # over it at discovery time, silently demoting the skill to its
          # static face.
          if File.expand_path(dest_dir) == File.expand_path(File.dirname(template))
            raise Error, "#{template}: content dir equals template dir; set " \
                         "skills_dir: in hyperdrive.yml to a separate root"
          end

          body = render_template(template)
          validate_output!(body, template)
          [Rendered.new(template: template, dest: File.join(dest_dir, "SKILL.md"), body: body)] +
            support_renders(File.dirname(template), dest_dir)
        end
      end

      # Supporting files carry no frontmatter contract, so their faces are
      # written unvalidated.
      def support_renders(template_dir, dest_dir)
        Dir.glob(File.join(template_dir, "**", "*.md.erb")).sort.filter_map do |template|
          rel = template.delete_prefix("#{template_dir}/")
          next if File.basename(rel) == "SKILL.md.erb"
          Rendered.new(
            template: template,
            dest: File.join(dest_dir, rel.delete_suffix(".erb")),
            body: render_template(template)
          )
        end
      end

      # A *.md.erb reachable through a public skills root is copied verbatim by
      # generic skills.sh consumers.
      def public_erb_templates(gemspec: nil, dir: Dir.pwd, roots: nil)
        roots ||= resolve_roots(gemspec: gemspec, dir: dir)
        templates_root = File.expand_path(roots.templates_root)

        [roots.public_skills_root, roots.skills_root]
          .uniq { |r| File.expand_path(r) }
          .flat_map { |root| Dir.glob(File.join(root, "**", "*.md.erb")) }
          .reject { |path| File.expand_path(path).start_with?("#{templates_root}/") }
          .uniq.sort
      end

      def render_template(template)
        SkillTemplate.render_canonical(File.read(template))
      rescue SyntaxError, StandardError => e
        raise Error, "#{template}: canonical render failed (#{e.message})"
      end

      # A static face with unusable frontmatter would ship a broken skill to
      # consumers that read it directly.
      def validate_output!(body, template)
        frontmatter, = BundlerArtifactDiscovery.split_frontmatter(body)
        raise Error, "#{template}: rendered output has no YAML frontmatter" unless frontmatter

        meta = YAML.safe_load(frontmatter, permitted_classes: [Symbol]) || {}
        return if meta["name"] && meta["description"]
        raise Error, "#{template}: rendered frontmatter lacks name: or description:"
      rescue Psych::SyntaxError
        raise Error, "#{template}: rendered frontmatter is not parseable YAML"
      end

      private_class_method :manifest_dir, :support_renders, :render_template, :validate_output!
    end
  end
end
