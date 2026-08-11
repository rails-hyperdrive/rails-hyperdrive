require "fileutils"
require "yaml"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/skill_template"

module Rails
  module Hyperdrive
    # Renders each SKILL.md.erb template in a companion gem repo to the static
    # SKILL.md it pairs with, using the canonical fail-open binding. The output
    # keeps the gem:/versions:/conditional: frontmatter keys, so the static file
    # remains a self-contained installable skill for consumers that read it
    # directly. Companion-repo dev tooling: problems raise.
    module CanonicalSkillRender
      Error = Class.new(StandardError)

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
        spec_path = resolve_gemspec_path(gemspec, dir)
        spec = Gem::Specification.load(spec_path)
        raise Error, "could not load gemspec #{spec_path}" unless spec

        gem_root = File.dirname(File.expand_path(spec_path))
        skills_root = File.join(gem_root, metadata_dir(spec, "rails_hyperdrive_skills_dir"))
        templates_root = File.join(gem_root, metadata_dir(spec, "rails_hyperdrive_skill_templates_dir"))

        Dir.glob(File.join(templates_root, "**", "SKILL.md.erb")).sort.map do |template|
          rel = File.dirname(template).delete_prefix(templates_root).delete_prefix("/")
          dest_dir = File.join(skills_root, rel)
          # A SKILL.md written beside the SKILL.md.erb would take precedence
          # over it at discovery time, silently demoting the skill to its
          # static face.
          if File.expand_path(dest_dir) == File.expand_path(File.dirname(template))
            raise Error, "#{template}: content dir equals template dir; set " \
                         "spec.metadata[\"rails_hyperdrive_skills_dir\"] to a separate root"
          end

          body = render_template(template)
          validate_output!(body, template)
          Rendered.new(template: template, dest: File.join(dest_dir, "SKILL.md"), body: body)
        end
      end

      def resolve_gemspec_path(explicit, dir)
        if explicit && !explicit.to_s.strip.empty?
          path = File.expand_path(explicit.to_s, dir)
          raise Error, "gemspec not found: #{path}" unless File.file?(path)
          return path
        end

        found = Dir.glob(File.join(dir, "*.gemspec"))
        case found.size
        when 1 then File.expand_path(found.first)
        when 0 then raise Error, "no .gemspec found in #{dir}; pass an explicit path, " \
                                 "e.g. rake \"hyperdrive:skills:render[path/to/name.gemspec]\""
        else raise Error, "multiple gemspecs found in #{dir} " \
                          "(#{found.map { |f| File.basename(f) }.join(", ")}); pass an explicit path"
        end
      end

      def metadata_dir(spec, key)
        default = File.join("lib", spec.name, "hyperdrive", "skills")
        raw = spec.metadata && spec.metadata[key]
        return default if raw.nil? || raw.to_s.strip.empty?
        raise Error, "gemspec metadata #{key} must not contain '..' segments" if
          raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
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

      private_class_method :resolve_gemspec_path, :metadata_dir, :render_template, :validate_output!
    end
  end
end
