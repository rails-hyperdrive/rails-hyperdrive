require "fileutils"
require "yaml"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/gemspec_locator"
require "rails/hyperdrive/skill_template"

module Rails
  module Hyperdrive
    # Renders each SKILL.md.erb template in a companion gem repo to the static
    # SKILL.md it pairs with, using the canonical fail-open binding.
    # Companion-repo dev tooling: problems raise.
    module CanonicalSkillRender
      Error = GemspecLocator::Error

      Rendered = Struct.new(:template, :dest, :body, keyword_init: true)

      module_function

      def write(gemspec: nil, dir: Dir.pwd)
        render_all(gemspec: gemspec, dir: dir).each do |r|
          FileUtils.mkdir_p(File.dirname(r.dest))
          File.write(r.dest, r.body)
        end
      end

      def stale(gemspec: nil, dir: Dir.pwd)
        render_all(gemspec: gemspec, dir: dir).reject do |r|
          File.file?(r.dest) && File.read(r.dest) == r.body
        end
      end

      def render_all(gemspec: nil, dir: Dir.pwd)
        spec, gem_root = GemspecLocator.load_spec(gemspec, dir)
        skills_root = File.join(gem_root, GemspecLocator.metadata_dir(spec, "hyperdrive_skills_dir"))
        templates_root =
          File.join(gem_root, GemspecLocator.metadata_dir(spec, "hyperdrive_skill_templates_dir"))

        Dir.glob(File.join(templates_root, "**", "SKILL.md.erb")).sort.flat_map do |template|
          rel = File.dirname(template).delete_prefix(templates_root).delete_prefix("/")
          dest_dir = File.join(skills_root, rel)
          # A SKILL.md written beside the SKILL.md.erb would take precedence
          # over it at discovery time, silently demoting the skill to its
          # static face.
          if File.expand_path(dest_dir) == File.expand_path(File.dirname(template))
            raise Error, "#{template}: content dir equals template dir; set " \
                         "spec.metadata[\"hyperdrive_skills_dir\"] to a separate root"
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
      def public_erb_templates(gemspec: nil, dir: Dir.pwd)
        spec, gem_root = GemspecLocator.load_spec(gemspec, dir)
        templates_dir = GemspecLocator.metadata_dir(spec, "hyperdrive_skill_templates_dir")
        templates_root = File.expand_path(File.join(gem_root, templates_dir))
        roots = [File.join(gem_root, "skills")]
        if (declared = GemspecLocator.declared_dir(spec, "hyperdrive_skills_dir"))
          roots << File.join(gem_root, declared)
        end

        roots.uniq { |r| File.expand_path(r) }
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

      private_class_method :support_renders, :render_template, :validate_output!
    end
  end
end
