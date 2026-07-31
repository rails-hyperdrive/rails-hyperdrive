require "digest"
require "time"
require "rails/hyperdrive/version"
require "rails/hyperdrive/audit_header"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/install_plan"
require "rails/hyperdrive/lock_file"
require "rails/hyperdrive/stack_document"

module Rails
  module Hyperdrive
    # The application root is explicit and no Rails constant is touched, so any
    # process that can see the bundle can run this.
    class InstallPipeline
      CLAUDE_MD = "CLAUDE.md".freeze
      INDEX_LINE = "@.claude/hyperdrive/index.md".freeze
      HYPERDRIVE_DIR = ".claude/hyperdrive".freeze
      SKILLS_DIR = ".claude/skills".freeze
      INDEX_PATH = ".claude/hyperdrive/index.md".freeze
      STACK_PATH = ".claude/hyperdrive/stack.md".freeze
      LOCK_PATH = ".hyperdrive/lock.yml".freeze

      ARTIFACT_DESTINATIONS = [SKILLS_DIR, HYPERDRIVE_DIR, LOCK_PATH].freeze

      ARTIFACT_TYPES = { "skill" => :skill, "skill_support" => :skill_support, "guideline" => :guideline }.freeze

      WARN_LINES = 150
      WARN_TOKENS = 1_500

      # Soft cap on the assembled eager set — roughly six at-the-limit
      # guidelines, or ~5% of a 200k context window.
      TOTAL_WARN_TOKENS = 10_000

      MODES = %i[preserve overwrite additive].freeze

      Result = Struct.new(:installed, :updated, :unchanged, :skipped, :orphaned, :removed, keyword_init: true)

      def initialize(root:, shell:, artifacts:, stack:, mode: :preserve, warnings: [])
        raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

        @root = File.expand_path(root.to_s)
        @shell = shell
        @artifacts = artifacts
        @stack = stack
        @mode = mode
        @warnings = warnings
        @result = Result.new(installed: [], updated: [], unchanged: [], skipped: [], orphaned: [], removed: [])
      end

      def call
        @new_lock = LockFile.new(abs(LOCK_PATH)).carry_settings(old_lock)
        @plan = plan

        report_collisions
        report_disabled
        install_skills
        install_guidelines
        install_stack
        remove_disabled
        remove_stale_support_files
        carry_orphans
        write_index_md
        inject_claude_md
        write_lock
        print_warnings
        print_footprint
        warn_if_destinations_gitignored
        @result
      end

      def plan
        @plan ||= InstallPlan.build(@artifacts, lock: old_lock)
      end

      def lock
        @new_lock
      end

      private

      def old_lock
        @old_lock ||= LockFile.load(abs(LOCK_PATH))
      end

      def additive?
        @mode == :additive
      end

      def overwrite_mode?
        @mode == :overwrite
      end

      def abs(path)
        File.join(@root, path)
      end

      def report_collisions
        @plan.group_by { |e| [e.type, e.artifact.name] }.each do |(type, name), group|
          next unless group.first.collision
          @shell.say_status :conflict,
            "#{type} '#{name}' shipped by #{group.map { |e| e.artifact.source_gem }.join(", ")}; installing all (postfixed)",
            :yellow
        end
      end

      def report_disabled
        planned = @plan.map(&:dest)
        InstallPlan.build(@artifacts).reject { |e| planned.include?(e.dest) }.each do |entry|
          @shell.say_status :disabled, "#{entry.type} '#{entry.final_name}' (listed in #{LOCK_PATH})", :blue
        end
      end

      def install_skills
        @plan.select { |e| e.type == :skill }.each do |entry|
          install_file(entry: entry, type: :skill, install_ready_body: entry.install_ready_body)
          entry.support_files.each do |file|
            install_file(
              dest: file[:dest],
              type: :skill_support,
              install_ready_body: file[:body],
              source_gem: entry.source_gem,
              version: entry.version,
              artifact_kind: "skill_support"
            )
          end
        end
      end

      def install_guidelines
        @installed_guidelines = []
        @plan.select { |e| e.type == :guideline }.each do |entry|
          body = entry.install_ready_body
          warn_if_oversize(entry.dest, body)
          install_file(entry: entry, type: :guideline, install_ready_body: body)
          @installed_guidelines << { base: "#{entry.final_name}.md", dest: entry.dest, body: body }
        end
      end

      def install_stack
        body = StackDocument.render(@stack)
        @stack_body = body
        warn_if_oversize(STACK_PATH, body)
        install_file(
          dest: STACK_PATH,
          type: :stack,
          install_ready_body: body,
          source_gem: "internal",
          version: VERSION,
          artifact_kind: "stack"
        )
      end

      # A file counts as unedited when its stripped body still hashes to what
      # the lock recorded at install time, not to what the gem ships now.
      def install_file(dest: nil, type:, install_ready_body:, entry: nil, source_gem: nil, version: nil, artifact_kind: nil)
        write = {
          dest: dest || entry.dest,
          type: type,
          body: install_ready_body,
          source_gem: source_gem || entry.source_gem,
          version: version || entry.version,
          gem_sha: sha(install_ready_body),
          artifact_kind: artifact_kind || entry.artifact_kind
        }
        old = old_lock.entry(write[:dest])

        return additive_install(write, old) if additive?

        file = abs(write[:dest])
        unless File.exist?(file)
          @shell.say_status(:reinstall, "#{write[:dest]} (was missing)", :yellow) if old
          write_artifact(**write)
          return
        end

        disk_sha = sha(stripped_disk_body(file, type))
        unedited = old && disk_sha == old[:source_sha]

        if unedited && old[:source_sha] == write[:gem_sha]
          @new_lock.carry(old)
          @result.unchanged << write[:dest]
          @shell.say_status :unchanged, write[:dest], :blue
        elsif unedited || overwrite_mode?
          write_artifact(**write)
        else
          @result.skipped << write[:dest]
          @shell.say_status :skip, "#{write[:dest]} (locally modified; run hyperdrive:sync --overwrite to overwrite)", :yellow
          @new_lock.carry(old) if old
        end
      end

      # Additive installs can create a file and never overwrite one, so an
      # artifact the user edited — or deleted on purpose — survives.
      def additive_install(write, old)
        if old
          @new_lock.carry(old)
          (old[:source_sha] == write[:gem_sha] ? @result.unchanged : @result.skipped) << write[:dest]
        elsif File.exist?(abs(write[:dest]))
          @result.skipped << write[:dest]
        else
          write_artifact(**write)
        end
      end

      # Supporting files land byte-identical to what the gem ships — no audit
      # header, since they may be non-markdown or binary; provenance and sha
      # live in the lock alone.
      def write_artifact(dest:, type:, body:, source_gem:, version:, gem_sha:, artifact_kind:)
        installed_at = Time.now.utc
        header_args = { source_gem: source_gem, version: version, body: body, installed_at: installed_at }
        on_disk =
          case type
          when :skill
            AuditHeader.inject_into_frontmatter(body, AuditHeader.build(**header_args))
          when :skill_support
            body
          else
            AuditHeader.prepend_html(body, AuditHeader.build_html(**header_args))
          end

        existed = old_lock.entry(dest)
        @shell.create_file dest, on_disk
        (existed ? @result.updated : @result.installed) << dest
        @new_lock.upsert(
          path: dest,
          artifact: artifact_kind,
          source: "#{source_gem}@#{version}",
          source_sha: gem_sha,
          installed_at: installed_at.iso8601
        )
      end

      # The pipeline's only delete path, so it is gated on the file still
      # matching the content the lock recorded: hand-edited work is reported and
      # left for its owner to remove. Runs before orphans are carried, or a
      # removed file would read as one.
      def remove_disabled
        return if additive?

        old_lock.each_entry do |entry|
          type = ARTIFACT_TYPES[entry[:artifact]]
          next unless type
          next if @new_lock.entry(entry[:path])

          next unless InstallPlan.disabled_dest?(old_lock, type, entry[:path])

          file = abs(entry[:path])
          next unless File.exist?(file)

          if sha(stripped_disk_body(file, type)) == entry[:source_sha]
            @shell.remove_file entry[:path]
            @result.removed << entry[:path]
            prune_empty_dirs(entry[:path])
          else
            @result.skipped << entry[:path]
            @shell.say_status :skip,
              "#{entry[:path]} (disabled but locally modified; delete it by hand)", :yellow
            @new_lock.carry(entry)
          end
        end
      end

      # A supporting file the bundle no longer ships, while its owning skill
      # still installs, is removed only when its raw bytes still hash to the
      # recorded sha; an edited copy is reported and its lock entry carried.
      def remove_stale_support_files
        return if additive?

        planned_skill_dirs = @plan.select { |e| e.type == :skill }.map { |e| File.dirname(e.dest) }

        old_lock.each_entry do |entry|
          next unless entry[:artifact] == "skill_support"
          next if @new_lock.entry(entry[:path])
          next unless planned_skill_dirs.include?(skill_dir_of(entry[:path]))

          file = abs(entry[:path])
          next unless File.exist?(file)

          if sha(File.binread(file)) == entry[:source_sha]
            @shell.remove_file entry[:path]
            @result.removed << entry[:path]
            prune_empty_dirs(entry[:path])
          else
            @result.skipped << entry[:path]
            @shell.say_status :skip,
              "#{entry[:path]} (no longer shipped by #{entry[:source]} but locally modified; delete it by hand)",
              :yellow
            @new_lock.carry(entry)
          end
        end
      end

      def skill_dir_of(dest)
        segments = dest.split("/")
        File.join(*segments[0, 3]) # .claude/skills/<name>
      end

      # Supporting files never carry an audit header, and strip's line matching
      # can raise on binary content, so they compare as raw bytes.
      def stripped_disk_body(file, type)
        return File.binread(file) if type == :skill_support
        AuditHeader.strip(File.read(file))
      end

      # Skill directories go only once empty; any user file keeps the whole
      # chain alive. The just-removed entry is subtracted because a dry run
      # deletes nothing from disk.
      def prune_empty_dirs(removed_dest)
        removed = abs(removed_dest)
        dir = File.dirname(removed_dest)
        while dir.start_with?("#{SKILLS_DIR}/")
          children = Dir.exist?(abs(dir)) ? Dir.children(abs(dir)).map { |c| File.join(abs(dir), c) } : []
          children -= [removed]
          break unless children.empty?

          @shell.remove_file dir
          removed = abs(dir)
          dir = File.dirname(dir)
        end
      end

      def carry_orphans
        planned = @plan.map(&:dest) + [STACK_PATH]
        old_lock.each_entry do |entry|
          next if planned.include?(entry[:path])
          next if @new_lock.entry(entry[:path])
          next unless File.exist?(abs(entry[:path]))

          @result.orphaned << entry[:path]
          @shell.say_status :orphan,
            "#{entry[:path]} (source #{entry[:source]} no longer in bundle; left in place)", :yellow
          @new_lock.carry(entry)
        end
      end

      # A guideline whose line the user deleted from an existing index.md is
      # not re-added.
      def write_index_md
        return additive_index_md if additive?

        index_abs = abs(INDEX_PATH)
        existing = File.exist?(index_abs) ? File.read(index_abs) : nil
        old_known = old_lock.guideline_paths.map { |p| File.basename(p) }

        included = @installed_guidelines.select do |g|
          if existing.nil?
            true
          elsif old_known.include?(g[:base])
            existing.include?("@guidelines/#{g[:base]}")
          else
            true
          end
        end

        lines = ["@stack.md"]
        included.map { |g| "@guidelines/#{g[:base]}" }.sort.each { |l| lines << l }
        content = lines.join("\n") + "\n"

        # Only guidelines referenced by index.md load into context, so they
        # alone make up the eager footprint.
        @index_guideline_count = included.size
        @eager_entries = included.map { |g| { name: g[:base], body: g[:body] } }

        if existing == content
          @shell.say_status :unchanged, INDEX_PATH, :blue
        else
          @shell.create_file INDEX_PATH, content
        end
      end

      # Existing lines carry over untouched, so an orphan keeps its inclusion.
      def additive_index_md
        index_abs = abs(INDEX_PATH)
        return unless File.exist?(index_abs)

        added = @installed_guidelines
          .select { |g| @result.installed.include?(g[:dest]) }
          .map { |g| "@guidelines/#{g[:base]}" }
        return if added.empty?

        existing = File.read(index_abs).split("\n").map(&:strip).reject(&:empty?)
        return if (added - existing).empty?

        guidelines = (existing.reject { |l| l == "@stack.md" } + added).uniq.sort
        lines = existing.include?("@stack.md") ? ["@stack.md"] : []
        @shell.create_file INDEX_PATH, (lines + guidelines).join("\n") + "\n"
      end

      def inject_claude_md
        state = old_lock.claude_md_state

        # CLAUDE.md is the user's own file; only a generator they ran edits it.
        if additive?
          @new_lock.claude_md_state = state
          return
        end

        file = abs(CLAUDE_MD)
        present_on_disk = File.exist?(file) && File.read(file).include?(INDEX_LINE)

        new_state =
          if state.nil?
            if !File.exist?(file)
              @shell.create_file CLAUDE_MD,
                "<!-- AI instructions for this project. Managed content lives in #{HYPERDRIVE_DIR}/. -->\n\n#{INDEX_LINE}\n"
              LockFile::STATE_PRESENT
            elsif present_on_disk
              LockFile::STATE_PRESENT
            else
              @shell.append_to_file CLAUDE_MD, "\n#{INDEX_LINE}\n"
              LockFile::STATE_PRESENT
            end
          elsif state == LockFile::STATE_PRESENT && !present_on_disk
            @shell.say_status :warn,
              "you removed #{INDEX_LINE} from CLAUDE.md; leaving it out (won't re-add)", :yellow
            LockFile::STATE_REMOVED
          elsif state == LockFile::STATE_REMOVED && present_on_disk
            LockFile::STATE_PRESENT
          else
            state
          end

        @new_lock.claude_md_state = new_state
      end

      def write_lock
        @shell.create_file LOCK_PATH, @new_lock.to_yaml
      end

      def print_warnings
        return if Array(@warnings).empty?
        @shell.say ""
        @shell.say_status :warn, "discovery skipped #{@warnings.size} artifact(s):", :yellow
        @warnings.each { |w| @shell.say "    - #{w}" }
      end

      def print_footprint
        return if additive?
        entries = Array(@eager_entries).dup
        entries << { name: File.basename(STACK_PATH), body: @stack_body } if @stack_body
        tokens = entries.sum { |e| approx_tokens(e[:body]) }
        @shell.say_status :eager,
          "#{@index_guideline_count.to_i} guideline(s) + stack.md, ~#{tokens} tokens always in context", :cyan
        warn_if_over_budget(entries, tokens)
      end

      def warn_if_over_budget(entries, tokens)
        return unless tokens > TOTAL_WARN_TOKENS
        top = entries.sort_by { |e| -approx_tokens(e[:body]) }.first(2)
          .map { |e| "#{e[:name]} ~#{approx_tokens(e[:body])}" }
        @shell.say_status :warn,
          "eager context is over the ~#{TOTAL_WARN_TOKENS} token budget (largest: #{top.join(", ")}); trim them, or drop a line from #{INDEX_PATH} to opt one out",
          :yellow
      end

      def warn_if_destinations_gitignored
        # An additive run has no terminal to warn at; it reports through its result.
        return if additive?
        ignored = gitignored_destinations
        return if ignored.empty?

        @shell.say_status :warn,
          "#{ignored.join(", ")} #{ignored.one? ? "is" : "are"} gitignored; installed artifacts stay out of " \
          "git status and pull-request diffs, so companion-shipped content reaches the agent unreviewed",
          :yellow
      end

      # Patterns, negations, and per-repository excludes all decide ignore
      # status, so git is the only correct oracle. Fail-open: no match, no
      # repository, and no git alike exit non-zero and read as "not ignored".
      def gitignored_destinations
        output = IO.popen(
          ["git", "check-ignore", "--", *ARTIFACT_DESTINATIONS],
          chdir: @root, err: File::NULL, &:read
        )
        return [] unless $?&.success?
        output.to_s.split("\n").map(&:strip).reject(&:empty?)
      rescue SystemCallError
        []
      end

      def warn_if_oversize(dest, body)
        lines = body.lines.size
        tokens = approx_tokens(body)
        return unless lines > WARN_LINES || tokens > WARN_TOKENS
        @shell.say_status :warn,
          "#{dest} is large (#{lines} lines, ~#{tokens} tokens); guidelines are eager — move tutorial content to a skill",
          :yellow
      end

      def approx_tokens(body)
        (body.to_s.length / 4.0).ceil
      end

      def sha(content)
        Digest::SHA256.hexdigest(content.to_s)
      end
    end
  end
end
