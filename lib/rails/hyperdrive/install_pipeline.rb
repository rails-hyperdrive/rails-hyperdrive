require "set"
require "time"
require "rails/hyperdrive/ancestor_locator"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/claude_md_import"
require "rails/hyperdrive/config_file"
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
        (InstallLayout.dest_roots + [InstallLayout::LOCK_PATH, InstallLayout::CONFIG_PATH]).freeze

      WARN_LINES = 150
      WARN_TOKENS = 1_500

      MODES = %i[preserve overwrite additive sidecar merge].freeze

      Result = Struct.new(:installed, :updated, :unchanged, :skipped, :orphaned, :removed, :merged, :sidecars,
        keyword_init: true)

      Sidecar = Struct.new(:dest, :ancestor, :previous_source, keyword_init: true)

      def initialize(root:, shell:, artifacts:, mode: :preserve, report: BundlerArtifactDiscovery::Report.new,
                     config: nil)
        raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

        @root = File.expand_path(root.to_s)
        @shell = shell
        @artifacts = artifacts
        @mode = mode
        @report = report
        @config = config
        @bundled_gems = Array(report.bundled_gems).map(&:to_s)
        @skipped_gems = Array(report.skipped_gems).map(&:to_s)
        @result = Result.new(
          installed: [], updated: [], unchanged: [], skipped: [], orphaned: [], removed: [], merged: [], sidecars: []
        )
      end

      def call
        return halt_schema_ahead if old_lock.schema_ahead?

        report_settings_warnings
        @new_lock = LockFile.new(abs(InstallLayout::LOCK_PATH)).carry_document(old_lock)
        @plan = plan

        report_collisions
        report_disabled
        guidelines = install_artifacts
        remove_disabled
        remove_stale_support_files
        remove_stale_dests
        carry_orphans
        eager_guidelines = write_index_md(guidelines)
        write_claude_md(guidelines)
        clear_resolved_ancestors
        write_lock
        print_warnings
        print_notices
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

      # The backstop for callers that do not check the lock themselves: nothing
      # is written, in every mode including :additive.
      def halt_schema_ahead
        @shell.say_status :warn, old_lock.schema_ahead_message(InstallLayout::LOCK_PATH), :yellow
        @result
      end

      def build_result
        @build_result ||= InstallPlan.build(@artifacts, config: config)
      end

      def config
        @config ||= ConfigFile.load(abs(InstallLayout::CONFIG_PATH))
      end

      def report_settings_warnings
        return if additive?

        config.warnings.each { |warning| @shell.say_status :warn, warning, :yellow }
        return unless old_lock.legacy_settings?
        @shell.say_status :warn, old_lock.legacy_settings_message(InstallLayout::LOCK_PATH), :yellow
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
          @shell.say_status :disabled, "#{entry.type} '#{entry.final_name}' (listed in #{InstallLayout::CONFIG_PATH})", :blue
        end
      end

      # Returns the eager artifacts: the ones the index and the CLAUDE.md
      # import line are built from.
      def install_artifacts
        eager = []
        InstallLayout.content_kinds.each do |kind|
          @plan.select { |e| e.type == kind.type }.each do |entry|
            relpath = source_relpath_for(entry.artifact)
            body = entry.install_ready_body
            warn_if_oversize(entry.dest, body) if kind.eager
            install_file(entry: entry, type: kind.type, install_ready_body: body,
              source_relpath: relpath, final_name: entry.final_name)
            install_support_files(entry, relpath) if kind.dir_shaped?
            eager << { base: "#{entry.final_name}.md", dest: entry.dest, body: body } if kind.eager
          end
        end
        eager
      end

      def install_support_files(entry, relpath)
        support_base = support_relpath_base(entry.artifact, relpath)
        entry.support_files.each do |file|
          install_file(
            dest: file[:dest],
            type: :skill_support,
            install_ready_body: file[:body],
            source_gem: entry.source_gem,
            version: entry.version,
            artifact_kind: "skill_support",
            source_relpath: file[:source_relpath] || (support_base && File.join(support_base, file[:path]))
          )
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

      # Supporting files live under the artifact's support root, which for a
      # template-paired skill is not the definition file's directory.
      def support_relpath_base(artifact, skill_relpath)
        support_root = artifact.support_root
        return skill_relpath && File.dirname(skill_relpath) if support_root.nil? || support_root.to_s.empty?

        root = artifact.source_root
        return nil if root.nil? || root.to_s.empty?

        prefix = "#{File.expand_path(root.to_s)}/"
        expanded = File.expand_path(support_root.to_s)
        return nil unless expanded.start_with?(prefix)

        expanded.delete_prefix(prefix)
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
        case DriftVerdict.verdict(file: file, lock_entry: old, gem_sha: write[:gem_sha])
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
      # hash, so the same upstream version is offered exactly once. While a
      # sidecar is pending the entry also records the *ancestor*: the upstream
      # the live file's own edits descend from, which a later run needs as the
      # merge base.
      def reconcile_edited(write, old, source_relpath:, final_name:)
        dest = write[:dest]
        sidecar = InstallLayout.sidecar_path(dest)
        pending = File.exist?(abs(sidecar))
        pristine = pending && delivered_sidecar?(sidecar, delivered_shas(write, old))

        if old && old.source_sha == write[:gem_sha]
          return retry_pending(write, old, sidecar, pending: pending, pristine: pristine, final_name: final_name)
        end

        # An edited sidecar is user work: leave it, and leave the lock at the
        # old upstream so this delivery is re-offered once the user clears it.
        if pending && !pristine
          @result.skipped << dest
          @shell.say_status :warn, "#{sidecar} (sidecar locally modified; resolve or delete it)", :yellow
          @new_lock.carry(old) if old
          return
        end

        deliver(write, old, pending: pending, source_relpath: source_relpath, final_name: final_name)
      end

      # Nothing new to deliver: the pending sidecar is still the standing
      # offer, so --merge attempts to complete it rather than re-offering it.
      def retry_pending(write, old, sidecar, pending:, pristine:, final_name:)
        reason = nil
        if merge_mode? && pristine
          ancestor = AncestorLocator.locate_recorded_ancestor(old, final_name: final_name)
          merged, reason = ancestor ? merge_bodies(write, ancestor) : [nil, "ancestor unavailable"]
          if merged
            write_merged(write, merged)
            sweep_sidecar(write, old)
            return
          end
        end

        skip_edited(write, old)
        return unless pending

        message = "#{sidecar} (unresolved sidecar; reconcile it with #{write[:dest]}, then delete it"
        message += "; #{reason}" if reason
        @shell.say_status :warn, "#{message})", :yellow
      end

      # The ancestor is the live file's own base, so a delivery landing on top
      # of a pending one keeps the ancestor already recorded.
      def deliver(write, old, pending:, source_relpath:, final_name:)
        if pending
          record = recorded_ancestor(old)
          ancestor = AncestorLocator.locate_recorded_ancestor(old, final_name: final_name)
          previous_source = old&.ancestor_label
          reason = "ancestor unavailable" if merge_mode? && ancestor.nil?
        else
          record = fresh_ancestor(old, source_relpath)
          ancestor = locate_ancestor(write, old, source_relpath: source_relpath, final_name: final_name)
          previous_source = old&.source_label
          reason = fresh_merge_reason(old, ancestor) if merge_mode?
        end

        if merge_mode? && ancestor
          merged, reason = merge_bodies(write, ancestor)
          if merged
            write_merged(write, merged)
            sweep_sidecar(write, old)
            return
          end
        end

        write_sidecar(write, reason, ancestor: ancestor, previous_source: previous_source, ancestor_record: record)
      end

      def fresh_merge_reason(old, ancestor)
        return "no previous install recorded" unless old
        return "#{old.source_label} not found in installed gems" unless ancestor
        nil
      end

      # A fresh delivery always reads the ancestor off the entry's own source,
      # never off ancestor keys left over from a window that already closed.
      def fresh_ancestor(old, source_relpath)
        return nil unless old && source_relpath
        { gem: old.source_gem, version: old.source_version, sha: old.source_sha, relpath: source_relpath }
      end

      def recorded_ancestor(old)
        return nil unless old&.ancestor?
        { gem: old.ancestor_gem, version: old.ancestor_version, sha: old.ancestor_sha,
          relpath: old.ancestor_relpath }
      end

      def merge_bodies(write, ancestor)
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

      # Reconstruction is sha-gated against the lock entry recorded before this
      # run, so it must happen before the new upstream is locked.
      def locate_ancestor(write, old, source_relpath:, final_name:)
        return nil unless old

        AncestorLocator.locate(
          kind: write[:artifact_kind], relpath: source_relpath, lock_entry: old, final_name: final_name
        )
      end

      def live_body(write)
        file = abs(write[:dest])
        return File.binread(file) if write[:type] == :skill_support
        File.read(file)
      rescue StandardError
        nil
      end

      def write_merged(write, merged_body)
        @shell.create_file write[:dest], merged_body
        @result.merged << write[:dest]
        @shell.say_status :merged, "#{write[:dest]} (local edits merged with #{write[:source_gem]}@#{write[:version]})", :green
        upsert_lock(write, Time.now.utc)
      end

      # The sidecar is byte-identical to what a live install of the new
      # upstream would write, so `mv <dest>.new <dest>` accepts it wholesale
      # and the lock already verifies it.
      def write_sidecar(write, reason, ancestor: nil, previous_source: nil, ancestor_record: nil)
        sidecar = InstallLayout.sidecar_path(write[:dest])
        @shell.create_file sidecar, write[:body]
        @result.sidecars << Sidecar.new(dest: write[:dest], ancestor: ancestor, previous_source: previous_source)
        message = "#{write[:dest]} (locally modified; new upstream delivered to #{sidecar}"
        message += "; #{reason}" if reason
        @shell.say_status :sidecar, "#{message})", :yellow
        upsert_lock(write, Time.now.utc, ancestor: ancestor_record)
      end

      # Only a machine-pristine sidecar — one still hashing to a delivered
      # upstream — may be refreshed or removed; anything else is user work.
      def delivered_sidecar?(sidecar, shas)
        Array(shas).compact.include?(DriftVerdict.disk_sha(abs(sidecar)))
      rescue StandardError
        false
      end

      def delivered_shas(write, old)
        [old&.source_sha, write[:gem_sha]]
      end

      def sweep_sidecar(write, old)
        sweep_sidecar_at(write[:dest], delivered_shas(write, old))
      end

      def sweep_sidecar_at(dest, shas)
        sidecar = InstallLayout.sidecar_path(dest)
        return unless File.exist?(abs(sidecar))

        if delivered_sidecar?(sidecar, shas)
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

      # Every artifact lands byte-identical to its install-ready body;
      # provenance and sha live in the lock alone.
      def write_artifact(dest:, type:, body:, source_gem:, version:, gem_sha:, artifact_kind:)
        existed = old_lock.entry(dest)
        @shell.create_file dest, body
        (existed ? @result.updated : @result.installed) << dest
        @new_lock.upsert(
          path: dest,
          kind: artifact_kind,
          source_gem: source_gem,
          source_version: version,
          source_sha: gem_sha,
          installed_at: Time.now.utc.iso8601
        )
      end

      def upsert_lock(write, installed_at, ancestor: nil)
        @new_lock.upsert(
          path: write[:dest],
          kind: write[:artifact_kind],
          source_gem: write[:source_gem],
          source_version: write[:version],
          source_sha: write[:gem_sha],
          installed_at: installed_at.iso8601,
          ancestor_gem: ancestor && ancestor[:gem],
          ancestor_version: ancestor && ancestor[:version],
          ancestor_sha: ancestor && ancestor[:sha],
          ancestor_relpath: ancestor && ancestor[:relpath]
        )
      end

      # Deleting <dest>.new is the only resolution signal, so a recorded
      # ancestor stays until the run that finds the sidecar gone drops it.
      def clear_resolved_ancestors
        return if additive?

        @new_lock.each_entry do |entry|
          next unless entry.ancestor?
          next if File.exist?(abs(InstallLayout.sidecar_path(entry.path)))
          @new_lock.clear_ancestor(entry.path)
        end
      end

      # The pipeline's only delete path, so it is gated on the file still
      # matching the content the lock recorded: hand-edited work is reported and
      # left for its owner to remove. The dest's sidecar goes with it, since
      # nothing would reference or clean it afterwards.
      def remove_or_carry(entry)
        file = abs(entry.path)
        return unless File.exist?(file)

        if DriftVerdict.unedited?(file, lock_entry: entry)
          @shell.remove_file entry.path
          @result.removed << entry.path
          sweep_sidecar_at(entry.path, [entry.source_sha])
          prune_empty_dirs(entry.path)
        else
          @result.skipped << entry.path
          @shell.say_status :skip, "#{entry.path} (#{yield entry})", :yellow
          @new_lock.carry(entry)
        end
      end

      # Runs before orphans are carried, or a removed file would read as one.
      def remove_disabled
        return if additive?

        old_lock.each_entry do |entry|
          type = InstallLayout::ARTIFACT_TYPES[entry.kind]
          next unless type
          next if @new_lock.entry(entry.path)
          next unless InstallPlan.disabled_dest?(config, type, entry.path, source_gem: entry.source_gem)

          remove_or_carry(entry) { "disabled but locally modified; delete it by hand" }
        end
      end

      def remove_stale_support_files
        return if additive?

        planned_skill_dirs = @plan.select { |e| e.type == :skill }.map { |e| File.dirname(e.dest) }.to_set

        old_lock.each_entry do |entry|
          next unless entry.kind == "skill_support"
          next if @new_lock.entry(entry.path)
          next unless planned_skill_dirs.include?(InstallLayout.skill_dir_of(entry.path))

          remove_or_carry(entry) do |e|
            "no longer shipped by #{e.source_label} but locally modified; delete it by hand"
          end
        end
      end

      # An artifact that moved — renamed, or flipped between its canonical and
      # postfixed destination — leaves a byte-duplicate copy at the old
      # destination. Removal also requires the source gem to be bundled and to
      # have lost nothing to a discovery skip, so a broken companion release or
      # a version fence never removes a good install.
      def remove_stale_dests
        return if additive?

        planned = @plan.flat_map { |e| [e.dest, *e.support_files.map { |f| f[:dest] }] }.to_set

        old_lock.each_entry do |entry|
          next unless InstallLayout::ARTIFACT_TYPES[entry.kind]
          next if planned.include?(entry.path)
          next if @new_lock.entry(entry.path)
          next if already_removed?(entry.path)
          next unless source_gem_converged?(entry)

          remove_or_carry(entry) do |e|
            "#{e.source_gem} no longer installs this path but it is locally modified; delete it by hand"
          end
        end
      end

      def source_gem_converged?(entry)
        name = entry.source_gem.to_s
        @bundled_gems.include?(name) && !@skipped_gems.include?(name)
      end

      # A dry run deletes nothing, so a path an earlier removal step already
      # claimed is still on disk and must not be reported a second time.
      def already_removed?(path)
        @result.removed.include?(path)
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
        planned = @plan.map(&:dest).to_set
        old_lock.each_entry do |entry|
          next if planned.include?(entry.path)
          next if @new_lock.entry(entry.path)
          next if already_removed?(entry.path)
          next unless DriftVerdict.verdict(file: abs(entry.path), lock_entry: entry, gem_sha: nil) == :orphaned

          @result.orphaned << entry.path
          @shell.say_status :orphan, "#{entry.path} (#{orphan_reason(entry)}; left in place)", :yellow
          @new_lock.carry(entry)
        end
      end

      def orphan_reason(entry)
        LockFile.orphan_reason(
          source_label: entry.source_label,
          source_gem: entry.source_gem,
          bundled: @bundled_gems.include?(entry.source_gem.to_s)
        )
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

      # A skip dropped shipped content — a whole artifact, or one supporting
      # file of one; an advisory names a manifest problem that changed nothing
      # about what installed.
      def print_warnings
        skips = Array(@report.skips)
        advisories = @report.advisories
        print_warning_group skips, "discovery skipped #{skips.size} item(s):"
        print_warning_group advisories, "discovery reported #{advisories.size} advisory warning(s):"
      end

      def print_warning_group(lines, header)
        return if lines.empty?
        @shell.say ""
        @shell.say_status :warn, header, :yellow
        lines.each { |line| @shell.say "    - #{line}" }
      end

      def print_notices
        notices = Array(@report.notices)
        return if additive? || notices.empty?
        @shell.say ""
        notices.each { |n| @shell.say_status :info, n, :blue }
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
