module Rails
  module Hyperdrive
    # The registry every artifact kind declares itself in, and the one place
    # install paths and artifact names are built and parsed.
    # Must stay require-free: the MCP server loads it and must not drag in the
    # install machinery.
    module InstallLayout
      SKILLS_DIR = ".claude/skills".freeze
      HYPERDRIVE_DIR = ".claude/hyperdrive".freeze
      AGENTS_DIR = ".claude/agents".freeze
      COMMANDS_DIR = ".claude/commands".freeze
      INDEX_PATH = "#{HYPERDRIVE_DIR}/index.md".freeze
      LOCK_PATH = ".hyperdrive/lock.yml".freeze

      DEFAULT_TARGET = :claude

      # `root` is the directory a target tool reads the kind from; `path` builds
      # one artifact's destination under it.
      Dest = Struct.new(:root, :path, keyword_init: true)

      # One kind's whole contract: how a companion ships it, how it is
      # identified and validated, and where each target tool installs it.
      Kind = Struct.new(
        :type, :shape, :section, :key_label, :shipped_label, :dir_key, :prefix_key,
        :convention_roots, :identity, :frontmatter, :install_body,
        :collision_rewrites_name, :eager, :name_from_dest, :dests,
        keyword_init: true
      ) do
        def lock_kind
          type.to_s
        end

        # Only a directory-shaped kind ships supporting files, so it is the only
        # one a manifest entry may gate per file.
        def dir_shaped?
          shape == :dir
        end

        def dest_for(final_name, target: DEFAULT_TARGET)
          dests[target]&.path&.call(final_name)
        end

        def installed_name(dest)
          name_from_dest.call(dest)
        end

        # Relative to the gem root; searched in the order given.
        def roots_for(gem_name)
          convention_roots ? convention_roots.call(gem_name) : []
        end
      end

      KINDS = {
        skill: Kind.new(
          type: :skill,
          shape: :dir,
          section: "skills",
          key_label: "skill relpath",
          shipped_label: "skill directory",
          dir_key: "skills_dir",
          prefix_key: nil,
          convention_roots: ->(gem_name) { [File.join("lib", gem_name, "hyperdrive", "skills"), "skills"] },
          identity: :frontmatter,
          frontmatter: :required,
          install_body: :verbatim,
          collision_rewrites_name: true,
          eager: false,
          name_from_dest: ->(dest) { File.basename(File.dirname(dest)) },
          dests: { claude: Dest.new(root: SKILLS_DIR, path: ->(name) { "#{SKILLS_DIR}/#{name}/SKILL.md" }) }
        ),
        skill_support: Kind.new(
          type: :skill_support,
          shape: nil,
          install_body: :verbatim,
          collision_rewrites_name: false,
          eager: false,
          name_from_dest: ->(dest) { dest.split("/")[2] }, # .claude/skills/<name>/<relpath>
          dests: {}
        ),
        guideline: Kind.new(
          type: :guideline,
          shape: :flat,
          section: "guidelines",
          key_label: "guideline filename",
          shipped_label: "guideline",
          dir_key: nil,
          prefix_key: nil,
          convention_roots: ->(gem_name) { [File.join("lib", gem_name, "hyperdrive", "guidelines")] },
          identity: :frontmatter,
          frontmatter: :required,
          install_body: :strip_frontmatter,
          collision_rewrites_name: false,
          eager: true,
          name_from_dest: ->(dest) { File.basename(dest, ".md") },
          dests: {
            claude: Dest.new(
              root: HYPERDRIVE_DIR,
              path: ->(name) { "#{HYPERDRIVE_DIR}/guidelines/#{name}.md" }
            )
          }
        ),
        agent: Kind.new(
          type: :agent,
          shape: :flat,
          section: "agents",
          key_label: "agent filename",
          shipped_label: "agent",
          dir_key: "agents_dir",
          prefix_key: nil,
          convention_roots: ->(_gem_name) { ["agents"] },
          identity: :frontmatter,
          frontmatter: :required,
          install_body: :verbatim,
          collision_rewrites_name: true,
          eager: false,
          name_from_dest: ->(dest) { File.basename(dest, ".md") },
          dests: { claude: Dest.new(root: AGENTS_DIR, path: ->(name) { "#{AGENTS_DIR}/#{name}.md" }) }
        ),
        command: Kind.new(
          type: :command,
          shape: :flat,
          section: "commands",
          key_label: "command filename",
          shipped_label: "command",
          dir_key: "commands_dir",
          prefix_key: "command_prefix",
          convention_roots: ->(_gem_name) { ["commands"] },
          identity: :filename_stem,
          frontmatter: :optional,
          install_body: :verbatim,
          collision_rewrites_name: false,
          eager: false,
          name_from_dest: ->(dest) { File.basename(dest, ".md") },
          dests: { claude: Dest.new(root: COMMANDS_DIR, path: ->(name) { "#{COMMANDS_DIR}/#{name}.md" }) }
        )
      }.freeze

      ARTIFACT_TYPES = KINDS.each_with_object({}) { |(type, kind), h| h[kind.lock_kind] = type }.freeze

      module_function

      def kind(type)
        KINDS[type]
      end

      # The kinds a companion gem ships, in install order.
      def content_kinds
        KINDS.values.select(&:section)
      end

      def dir_keys
        content_kinds.filter_map(&:dir_key)
      end

      def dest_roots(target: DEFAULT_TARGET)
        content_kinds.filter_map { |kind| kind.dests[target]&.root }.uniq
      end

      def dest_for(type, final_name, target: DEFAULT_TARGET)
        KINDS[type]&.dest_for(final_name, target: target)
      end

      def sidecar_path(dest)
        "#{dest}.new"
      end

      def installed_name(type, dest)
        KINDS[type]&.installed_name(dest)
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
