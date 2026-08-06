require "time"
require "rails/hyperdrive/ancestor_locator"
require "rails/hyperdrive/audit_header"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/claude_md_import"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/three_way_merge"
require "rails/hyperdrive/eager_footprint"
require "rails/hyperdrive/index_document"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/install_plan"
require "rails/hyperdrive/lock_file"

module Rails
  module Hyperdrive
    # The application root is explicit and no Rails constant is touched, so any
    # process that can see the bundle can run this.
    class InstallPipeline
      ARTIFACT_DESTINATIONS =
        [InstallLayout::SKILLS_DIR, InstallLayout::HYPERDRIVE_DIR, InstallLayout::LOCK_PATH].freeze

      WARN_LINES = 150
      WARN_TOKENS = 1_500

      MODES = %i[preserve overwrite additive sidecar merge].freeze

      Result = Struct.new(:installed, :updated, :unchanged, :skipped, :orphaned, :removed, :merged, :sidecars,
        keyword_init: true)

      def initialize(root:, shell:, artifacts:, mode: :preserve, warnings: [])
        raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

        @root = File.expand_path(root.to_s)
        @shell = shell
        @artifacts = artifacts
        @mode = mode
        @warnings = warnings
        @result = Result.new(
          installed: [], updated: [], unchanged: [], skipped: [], orphaned: [], removed: [], merged: [], sidecars: []
        )
      end

      def call
        @new_lock = LockFile.new(abs(InstallLayout::LOCK_PATH)).carry_settings(old_lock)
        @plan = plan

        report_collisions
        report_disabled
        install_skills
        guidelines = install_guidelines
        remove_disabled
        remove_stale_support_files
        carry_orphans
        eager_guidelines = write_index_md(guidelines)
        write_claude_md(guidelines)
        write_lock
        print_warnings
        print_footprint(guidelines: eager_guidelines)
        warn_if_destinations_gitignored
        @result
      end

      def plan
        build_result.entries
      end

      def lock
        @new_lock
      end

      private

      def build_result
        @build_result ||= InstallPlan.build(@artifacts, lock: old_lock)
      end

      def old_lock
        @old_lock ||= LockFile.load(abs(InstallLayout::LOCK_PATH))
      end

      def additive?
        @mode == :additive
      end

      def overwrite_mode?
        @mode == :overwrite
      end

      def merge_mode?
        @mode == :merge
      end

      def reconcile_mode?
        @mode == :sidecar || @mode == :merge
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
        build_result.disabled.each do |entry|
          @shell.say_status :disabled, "#{entry.type} '#{entry.final_name}' (listed in #{InstallLayout::LOCK_PATH})", :blue
        end
      end

      def install_skills
        @plan.select { |e| e.type == :skill }.each do |entry|
          skill_relpath = source_relpath_for(entry.artifact)
          install_file(entry: entry, type: :skill, install_ready_body: entry.install_ready_body,
            source_relpath: skill_relpath, final_name: entry.final_name)
          entry.support_files.each do |file|
            install_file(
              dest: file[:dest],
              type: :skill_support,
              install_ready_body: file[:body],
              source_gem: entry.source_gem,
              version: entry.version,
              artifact_kind: "skill_support",
              source_relpath: skill_relpath && File.join(File.dirname(skill_relpath), file[:path])
            )
          end
        end
      end

      def install_guidelines
        @plan.select { |e| e.type == :guideline }.map do |entry|
          body = entry.install_ready_body
          warn_if_oversize(entry.dest, body)
          install_file(entry: entry, type: :guideline, install_ready_body: body,
            source_relpath: source_relpath_for(entry.artifact), final_name: entry.final_name)
          { base: "#{entry.final_name}.md", dest: entry.dest, body: body }
        end
      end

      # The shipped file's path relative to its gem root, normalized to the
      # install-target form (.md.erb -> .md).
      def source_relpath_for(artifact)
        root = artifact.source_root
        return nil if root.nil? || root.to_s.empty?

        prefix = "#{File.expand_path(root.to_s)}/"
        expanded = File.expand_path(artifact.path.to_s)
        return nil unless expanded.start_with?(prefix)

        rel = expanded.delete_prefix(prefix)
        rel.end_with?(".md.erb") ? rel.delete_suffix(".erb") : rel
      end

      def install_file(dest: nil, type:, install_ready_body:, entry: nil, source_gem: nil, version: nil,
                       artifact_kind: nil, source_relpath: nil, final_name: nil)
        write = {
          dest: dest || entry.dest,
          type: type,
          body: install_ready_body,
          source_gem: source_gem || entry.source_gem,
          version: version || entry.version,
          gem_sha: DriftVerdict.body_sha(install_ready_body),
          artifact_kind: artifact_kind || entry.artifact_kind
        }
        old = old_lock.entry(write[:dest])

        return additive_install(write, old) if additive?

        file = abs(write[:dest])
        case DriftVerdict.verdict(file: file, kind: write[:artifact_kind], lock_entry: old, gem_sha: write[:gem_sha])
        when :missing
          @shell.say_status(:reinstall, "#{write[:dest]} (was missing)", :yellow) if old
          write_artifact(**write)
          sweep_sidecar(write, old)
        when :current
          @new_lock.carry(old)
          @result.unchanged << write[:dest]
          @shell.say_status :unchanged, write[:dest], :blue
          sweep_sidecar(write, old)
        when :outdated
          write_artifact(**write)
          sweep_sidecar(write, old)
        when :edited
          if overwrite_mode?
            write_artifact(**write)
            sweep_sidecar(write, old)
          elsif reconcile_mode?
            reconcile_edited(write, old, source_relpath: source_relpath, final_name: final_name)
          else
            skip_edited(write, old)
          end
        end
      end

      def skip_edited(write, old)
        @result.skipped << write[:dest]
        @shell.say_status :skip,
          "#{write[:dest]} (locally modified; run hyperdrive:sync with --merge, --sidecar, or --overwrite to reconcile)",
          :yellow
        @new_lock.carry(old) if old
      end

      # Reconciliation for a locally-modified destination in :sidecar/:merge
      # mode. The lock records the newest upstream *delivered* — installed
      # live, merged in, or written as a sidecar — never the live file's own
      # hash, so the same upstream version is offered exactly once.
      def reconcile_edited(write, old, source_relpath:, final_name:)
        dest = write[:dest]
        sidecar = InstallLayout.sidecar_path(dest)

        if old && old.source_sha == write[:gem_sha]
          skip_edited(write, old)
          if File.exist?(abs(sidecar))
            @shell.say_status :warn, "#{sidecar} (unresolved sidecar; reconcile it with #{dest}, then delete it)", :yellow
          end
          return
        end

        # An edited sidecar is user work: leave it, and leave the lock at the
        # old upstream so this delivery is re-offered once the user clears it.
        if File.exist?(abs(sidecar)) && !sidecar_pristine?(sidecar, write, old)
          @result.skipped << dest
          @shell.say_status :warn, "#{sidecar} (sidecar locally modified; resolve or delete it)", :yellow
          @new_lock.carry(old) if old
          return
        end

        reason = nil
        if merge_mode?
          if File.exist?(abs(sidecar))
            # A pending sidecar means the last delivered upstream never reached
            # the live file, so the reconstructable ancestor is stale; merging
            # over it would silently revert that delivery.
            reason = "previous delivery still unresolved"
          else
            merged, reason = attempt_merge(write, old, source_relpath: source_relpath, final_name: final_name)
            if merged
              write_merged(write, merged)
              sweep_sidecar(write, old)
              return
            end
          end
        end

        write_sidecar(write, reason)
      end

      def attempt_merge(write, old, source_relpath:, final_name:)
        return [nil, "no previous install recorded"] unless old

        ancestor = AncestorLocator.locate(
          kind: write[:artifact_kind], relpath: source_relpath, lock_entry: old, final_name: final_name
        )
        return [nil, "#{old.source_label} not found in installed gems"] unless ancestor

        ours = live_body(write)
        if ours.nil? || [ours, ancestor, write[:body]].any? { |b| ThreeWayMerge.binary?(b) }
          return [nil, "binary content"]
        end

        outcome = ThreeWayMerge.merge(ours: ours, base: ancestor, theirs: write[:body])
        case outcome.status
        when :clean      then [outcome.body, nil]
        when :conflicted then [nil, "conflicting edits"]
        else                  [nil, "git merge-file unavailable"]
        end
      end

      def live_body(write)
        file = abs(write[:dest])
        return File.binread(file) if write[:type] == :skill_support
        AuditHeader.strip(File.read(file))
      rescue StandardError
        nil
      end

      def write_merged(write, merged_body)
        installed_at = Time.now.utc
        on_disk = on_disk_body(**write.slice(:type, :source_gem, :version, :gem_sha), body: merged_body, installed_at: installed_at)
        @shell.create_file write[:dest], on_disk
        @result.merged << write[:dest]
        @shell.say_status :merged, "#{write[:dest]} (local edits merged with #{write[:source_gem]}@#{write[:version]})", :green
        upsert_lock(write, installed_at)
      end

      # The sidecar is byte-identical to what a live install of the new
      # upstream would write, so `mv <dest>.new <dest>` accepts it wholesale
      # and the lock already verifies it.
      def write_sidecar(write, reason)
        sidecar = InstallLayout.sidecar_path(write[:dest])
        installed_at = Time.now.utc
        on_disk = on_disk_body(**write.slice(:type, :source_gem, :version, :gem_sha), body: write[:body], installed_at: installed_at)
        @shell.create_file sidecar, on_disk
        @result.sidecars << write[:dest]
        message = "#{write[:dest]} (locally modified; new upstream delivered to #{sidecar}"
        message += "; #{reason}" if reason
        @shell.say_status :sidecar, "#{message})", :yellow
        upsert_lock(write, installed_at)
      end

      # Only a machine-pristine sidecar — one still hashing to a delivered
      # upstream — may be refreshed or removed; anything else is user work.
      def sidecar_pristine?(sidecar, write, old)
        sha = DriftVerdict.disk_sha(abs(sidecar), kind: write[:artifact_kind])
        [old&.source_sha, write[:gem_sha]].compact.include?(sha)
      rescue StandardError
        false
      end

      def sweep_sidecar(write, old)
        sidecar = InstallLayout.sidecar_path(write[:dest])
        return unless File.exist?(abs(sidecar))

        if sidecar_pristine?(sidecar, write, old)
          @shell.remove_file sidecar
          @result.removed << sidecar
        else
          @shell.say_status :warn, "#{sidecar} (sidecar locally modified; resolve or delete it)", :yellow
        end
      end

      # Additive installs can create a file and never overwrite one, so an
      # artifact the user edited — or deleted on purpose — survives.
      def additive_install(write, old)
        if old
          @new_lock.carry(old)
          (old.source_sha == write[:gem_sha] ? @result.unchanged : @result.skipped) << write[:dest]
        elsif File.exist?(abs(write[:dest]))
          @result.skipped << write[:dest]
        else
          write_artifact(**write)
        end
      end

      def write_artifact(dest:, type:, body:, source_gem:, version:, gem_sha:, artifact_kind:)
        installed_at = Time.now.utc
        on_disk = on_disk_body(
          type: type, body: body, source_gem: source_gem, version: version,
          gem_sha: gem_sha, installed_at: installed_at
        )

        existed = old_lock.entry(dest)
        @shell.create_file dest, on_disk
        (existed ? @result.updated : @result.installed) << dest
        @new_lock.upsert(
          path: dest,
          kind: artifact_kind,
          source_gem: source_gem,
          source_version: version,
          source_sha: gem_sha,
          installed_at: installed_at.iso8601
        )
      end

      # Supporting files land byte-identical to what the gem ships — no audit
      # header, since they may be non-markdown or binary; provenance and sha
      # live in the lock alone. sha256 is always the install-ready body's
      # hash, even when the written body is a merge result.
      def on_disk_body(type:, body:, source_gem:, version:, gem_sha:, installed_at:)
        header_args = { source_gem: source_gem, version: version, sha256: gem_sha, installed_at: installed_at }
        case type
        when :skill
          AuditHeader.inject_into_frontmatter(body, AuditHeader.build(**header_args))
        when :skill_support
          body
        else
          AuditHeader.prepend_html(body, AuditHeader.build_html(**header_args))
        end
      end

      def upsert_lock(write, installed_at)
        @new_lock.upsert(
          path: write[:dest],
          kind: write[:artifact_kind],
          source_gem: write[:source_gem],
          source_version: write[:version],
          source_sha: write[:gem_sha],
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
          type = InstallLayout::ARTIFACT_TYPES[entry.kind]
          next unless type
          next if @new_lock.entry(entry.path)

          next unless InstallPlan.disabled_dest?(old_lock, type, entry.path)

          file = abs(entry.path)
          next unless File.exist?(file)

          if DriftVerdict.unedited?(file, lock_entry: entry)
            @shell.remove_file entry.path
            @result.removed << entry.path
            prune_empty_dirs(entry.path)
          else
            @result.skipped << entry.path
            @shell.say_status :skip,
              "#{entry.path} (disabled but locally modified; delete it by hand)", :yellow
            @new_lock.carry(entry)
          end
        end
      end

      # Deletion is gated on the recorded sha, so a user-edited copy is never
      # removed.
      def remove_stale_support_files
        return if additive?

        planned_skill_dirs = @plan.select { |e| e.type == :skill }.map { |e| File.dirname(e.dest) }

        old_lock.each_entry do |entry|
          next unless entry.kind == "skill_support"
          next if @new_lock.entry(entry.path)
          next unless planned_skill_dirs.include?(InstallLayout.skill_dir_of(entry.path))

          file = abs(entry.path)
          next unless File.exist?(file)

          if DriftVerdict.unedited?(file, lock_entry: entry)
            @shell.remove_file entry.path
            @result.removed << entry.path
            prune_empty_dirs(entry.path)
          else
            @result.skipped << entry.path
            @shell.say_status :skip,
              "#{entry.path} (no longer shipped by #{entry.source_label} but locally modified; delete it by hand)",
              :yellow
            @new_lock.carry(entry)
          end
        end
      end

      # Skill directories go only once empty; any user file keeps the whole
      # chain alive. The just-removed entry is subtracted because a dry run
      # deletes nothing from disk.
      def prune_empty_dirs(removed_dest)
        removed = abs(removed_dest)
        dir = File.dirname(removed_dest)
        while dir.start_with?("#{InstallLayout::SKILLS_DIR}/")
          children = Dir.exist?(abs(dir)) ? Dir.children(abs(dir)).map { |c| File.join(abs(dir), c) } : []
          children -= [removed]
          break unless children.empty?

          @shell.remove_file dir
          removed = abs(dir)
          dir = File.dirname(dir)
        end
      end

      def carry_orphans
        planned = @plan.map(&:dest)
        old_lock.each_entry do |entry|
          next if planned.include?(entry.path)
          next if @new_lock.entry(entry.path)
          next unless DriftVerdict.verdict(file: abs(entry.path), kind: entry.kind, lock_entry: entry, gem_sha: nil) == :orphaned

          @result.orphaned << entry.path
          @shell.say_status :orphan,
            "#{entry.path} (no longer shipped by #{entry.source_label}; left in place)", :yellow
          @new_lock.carry(entry)
        end
      end

      # Returns the eager set: the guidelines index.md ends up including.
      def write_index_md(guidelines)
        return amend_index_md(guidelines) if additive?
        return teardown_index_md if guidelines.empty?

        existing = read_index
        rendered = IndexDocument.render(
          guidelines: guidelines,
          existing: existing,
          previously_installed: old_lock.guideline_paths.map { |p| File.basename(p) }
        )

        if existing == rendered.content
          @shell.say_status :unchanged, InstallLayout::INDEX_PATH, :blue
        else
          @shell.create_file InstallLayout::INDEX_PATH, rendered.content
        end
        rendered.guidelines
      end

      def amend_index_md(guidelines)
        added = guidelines.select { |g| @result.installed.include?(g[:dest]) }.map { |g| g[:base] }
        content = IndexDocument.amend(existing: read_index, added: added)
        @shell.create_file InstallLayout::INDEX_PATH, content if content
        [] # an additive run prints no footprint, so it reports no eager set
      end

      # No sha gate: the file has no lock entry, and the only user input it
      # carries is a deleted `@`-line, which is moot once no guideline is
      # planned.
      def teardown_index_md
        if File.exist?(abs(InstallLayout::INDEX_PATH))
          @shell.remove_file InstallLayout::INDEX_PATH
          @result.removed << InstallLayout::INDEX_PATH
        end
        []
      end

      def read_index
        file = abs(InstallLayout::INDEX_PATH)
        File.read(file) if File.exist?(file)
      end

      def write_claude_md(guidelines)
        file = abs(ClaudeMdImport::PATH)
        content = File.read(file) if File.exist?(file)
        decision =
          if guidelines.empty? && !additive?
            ClaudeMdImport.teardown(content: content, state: old_lock.claude_md_state)
          else
            ClaudeMdImport.decide(content: content, state: old_lock.claude_md_state, mode: @mode)
          end

        case decision.action
        when :create  then @shell.create_file ClaudeMdImport::PATH, decision.body
        when :append  then @shell.append_to_file ClaudeMdImport::PATH, decision.body
        when :rewrite then @shell.create_file ClaudeMdImport::PATH, decision.body
        when :delete  then @shell.remove_file ClaudeMdImport::PATH
        end
        @shell.say_status :warn, decision.warning, :yellow if decision.warning

        @new_lock.claude_md_state = decision.state
      end

      def write_lock
        @shell.create_file InstallLayout::LOCK_PATH, @new_lock.to_yaml
      end

      def print_warnings
        return if Array(@warnings).empty?
        @shell.say ""
        @shell.say_status :warn, "discovery skipped #{@warnings.size} artifact(s):", :yellow
        @warnings.each { |w| @shell.say "    - #{w}" }
      end

      def print_footprint(guidelines:)
        return if additive?

        EagerFootprint.lines(guidelines: guidelines).each do |line|
          @shell.say_status line.status, line.message, line.color
        end
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
        tokens = EagerFootprint.approx_tokens(body)
        return unless lines > WARN_LINES || tokens > WARN_TOKENS
        @shell.say_status :warn,
          "#{dest} is large (#{lines} lines, ~#{tokens} tokens); guidelines are eager — move tutorial content to a skill",
          :yellow
      end
    end
  end
end
