module Rails
  module Hyperdrive
    # The one place install paths and artifact names are built and parsed.
    # Must stay require-free: the MCP server loads it and must not drag in the
    # install machinery.
    module InstallLayout
      SKILLS_DIR = ".claude/skills".freeze
      HYPERDRIVE_DIR = ".claude/hyperdrive".freeze
      INDEX_PATH = "#{HYPERDRIVE_DIR}/index.md".freeze
      LOCK_PATH = ".hyperdrive/lock.yml".freeze

      ARTIFACT_TYPES = { "skill" => :skill, "skill_support" => :skill_support, "guideline" => :guideline }.freeze

      module_function

      def dest_for(type, final_name)
        case type
        when :skill     then "#{SKILLS_DIR}/#{final_name}/SKILL.md"
        when :guideline then "#{HYPERDRIVE_DIR}/guidelines/#{final_name}.md"
        end
      end

      def sidecar_path(dest)
        "#{dest}.new"
      end

      def installed_name(type, dest)
        case type
        when :skill         then File.basename(File.dirname(dest))
        when :skill_support then dest.split("/")[2] # .claude/skills/<name>/<relpath>
        when :guideline     then File.basename(dest, ".md")
        end
      end

      def skill_dir_of(dest)
        segments = dest.split("/")
        File.join(*segments[0, 3]) # .claude/skills/<name>
      end

      def postfixed_name(name, source_gem)
        "#{name}--#{source_gem}"
      end

      def base_name(name)
        name.split("--").first.to_s
      end
    end
  end
end
