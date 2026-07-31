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
    # Installs discovered artifacts into an application. The application root is
    # explicit and no Rails constant is touched, so any process that can see the
    # bundle can run this.
    class InstallPipeline
      CLAUDE_MD = "CLAUDE.md".freeze
      INDEX_LINE = "@.claude/hyperdrive/index.md".freeze
      HYPERDRIVE_DIR = ".claude/hyperdrive".freeze
      INDEX_PATH = ".claude/hyperdrive/index.md".freeze
      STACK_PATH = ".claude/hyperdrive/stack.md".freeze
      LOCK_PATH = ".hyperdrive/lock.yml".freeze

      WARN_LINES = 150
      WARN_TOKENS = 1_500

      # Soft cap on the assembled eager set — roughly six at-the-limit
      # guidelines, or ~5% of a 200k context window.
      TOTAL_WARN_TOKENS = 10_000

      MODES = %i[init update additive].freeze

      Result = Struct.new(:installed, :updated, :unchanged, :skipped, :orphaned, keyword_init: true)

      def initialize(root:, shell:, artifacts:, stack:, mode: :init, warnings: [])
        raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

        @root = File.expand_path(root.to_s)
        @shell = shell
        @artifacts = artifacts
        @stack = stack
        @mode = mode
        @warnings = warnings
        @result = Result.new(installed: [], updated: [], unchanged: [], skipped: [], orphaned: [])
      end

      def call
        @old_lock = LockFile.load(abs(LOCK_PATH))
        @new_lock = LockFile.new(abs(LOCK_PATH))
        @plan = InstallPlan.build(@artifacts)

        report_collisions
        install_skills
        install_guidelines
        install_stack
        carry_orphans
        write_index_md
        inject_claude_md
        write_lock
        print_warnings
        print_footprint
        @result
      end

      def plan
        @plan ||= InstallPlan.build(@artifacts)
      end

      private

      def additive?
        @mode == :additive
      end

      def update_mode?
        @mode == :update
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

      def install_skills
        @plan.select { |e| e.type == :skill }.each do |entry|
          install_file(entry: entry, type: :skill, install_ready_body: entry.install_ready_body)
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
        old = @old_lock.entry(write[:dest])

        return additive_install(write, old) if additive?

        file = abs(write[:dest])
        unless File.exist?(file)
          @shell.say_status(:reinstall, "#{write[:dest]} (was missing)", :yellow) if old
          write_artifact(**write)
          return
        end

        disk_sha = sha(AuditHeader.strip(File.read(file)))
        unedited = old && disk_sha == old[:source_sha]

        if unedited && old[:source_sha] == write[:gem_sha]
          @new_lock.carry(old)
          @result.unchanged << write[:dest]
          @shell.say_status :unchanged, write[:dest], :blue
        elsif unedited || update_mode?
          write_artifact(**write)
        else
          @result.skipped << write[:dest]
          @shell.say_status :skip, "#{write[:dest]} (locally modified; run hyperdrive:update to overwrite)", :yellow
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

      def write_artifact(dest:, type:, body:, source_gem:, version:, gem_sha:, artifact_kind:)
        installed_at = Time.now.utc
        header_args = { source_gem: source_gem, version: version, body: body, installed_at: installed_at }
        on_disk =
          if type == :skill
            AuditHeader.inject_into_frontmatter(body, AuditHeader.build(**header_args))
          else
            AuditHeader.prepend_html(body, AuditHeader.build_html(**header_args))
          end

        existed = @old_lock.entry(dest)
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

      def carry_orphans
        planned = @plan.map(&:dest) + [STACK_PATH]
        @old_lock.each_entry do |entry|
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
        old_known = @old_lock.guideline_paths.map { |p| File.basename(p) }

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

      # Existing lines carry over untouched, so a line the user deleted stays
      # deleted and an orphan keeps its inclusion.
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
        state = @old_lock.claude_md_state

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
