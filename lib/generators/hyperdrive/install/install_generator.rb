require "rails/generators"
require "rails/generators/base"
require "digest"
require "time"
require "rails/hyperdrive"
require "rails/hyperdrive/stack_profile"
require "rails/hyperdrive/stack_document"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/audit_header"
require "rails/hyperdrive/lock_file"
require "rails/hyperdrive/companion_discovery"
require "generators/hyperdrive/gitignore_support"

module Rails
  module Generators
    module Hyperdrive
      # Backs `bin/rails hyperdrive:init` and `bin/rails hyperdrive:update`.
      #
      # init   — first-run + idempotent re-sync; skips locally-modified files.
      # update — same pipeline, but force-overwrites locally-modified files.
      #
      # rails-hyperdrive ships no content. It walks the bundle for companion
      # gems' skills + guidelines, installs them, generates stack.md, maintains
      # the index.md aggregator, and injects exactly one `@`-include line into
      # CLAUDE.md.
      class InstallGenerator < ::Rails::Generators::Base
        include GitignoreSupport

        ENGINE_MOUNT_TOKEN = "Rails::Hyperdrive::Engine"
        DEFAULT_MOUNT_AT = "/_hyperdrive".freeze

        CLAUDE_MD = "CLAUDE.md".freeze
        INDEX_LINE = "@.claude/hyperdrive/index.md".freeze
        HYPERDRIVE_DIR = ".claude/hyperdrive".freeze
        INDEX_PATH = ".claude/hyperdrive/index.md".freeze
        STACK_PATH = ".claude/hyperdrive/stack.md".freeze
        LOCK_PATH = ".hyperdrive/lock.yml".freeze

        # Eager-budget soft caps (per guideline).
        WARN_LINES = 150
        WARN_TOKENS = 1_500

        source_root File.expand_path("templates", __dir__)

        class_option :mount_at,      type: :string,  default: DEFAULT_MOUNT_AT, desc: "Engine mount path."
        class_option :skip_content,  type: :boolean, default: false, desc: "Skip all .claude content, CLAUDE.md, and the lockfile; write only .mcp.json and the mount."
        class_option :dry_run,       type: :boolean, default: false, desc: "Show what would change; write nothing."
        class_option :force_install, type: :boolean, default: false, desc: "Force-overwrite locally-modified files (same as update)."
        class_option :update,        type: :boolean, default: false, desc: "Update mode: force-overwrite locally-modified files."

        def verify_environment
          unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
            say_status :error, "must be run inside a Rails app", :red
            raise Thor::Error, "hyperdrive: not in a Rails app"
          end
          unless ::Rails.respond_to?(:env) && ::Rails.env.development?
            env = ::Rails.respond_to?(:env) ? ::Rails.env.to_s : "unknown"
            warn "hyperdrive: hyperdrive:init must run with Rails.env=development (current: #{env})"
            raise Thor::Error, "hyperdrive: refuse to run outside development (Rails.env=#{env})"
          end
          # Thor's create_file / inject_into_file / append_to_file all honor
          # `options[:pretend]`. Translate our user-facing --dry-run to that.
          if options[:dry_run]
            self.options = options.merge(pretend: true).freeze
          end
        end

        def parse_stack_profile
          @stack_profile = ::Rails::Hyperdrive::StackProfile.from_lockfile(
            ::Rails.root.join("Gemfile.lock").to_s
          )
        end

        def discover_artifacts
          @warnings = []
          @artifacts =
            if options[:skip_content]
              []
            else
              ::Rails::Hyperdrive::BundlerArtifactDiscovery.discover(warnings: @warnings)
            end
        end

        def write_mcp_json
          template "mcp.json.tt", ".mcp.json"
        end

        # The `hyperdrive:discover` cache is the only gitignored
        # rails-hyperdrive artifact — the lockfile `.hyperdrive/lock.yml` stays
        # git-tracked. Ignore the specific file, not the `.hyperdrive/`
        # directory.
        def ignore_discover_cache
          ensure_gitignored(::Rails::Hyperdrive::CompanionDiscovery::CACHE_RELATIVE_PATH)
        end

        def write_initializer
          return if mount_path == DEFAULT_MOUNT_AT
          template "initializer.rb.tt", "config/initializers/hyperdrive.rb"
        end

        def mount_engine
          routes_file = "config/routes.rb"
          unless File.exist?(::Rails.root.join(routes_file))
            say_status :skip, "no #{routes_file} found; skipping engine mount", :yellow
            return
          end

          contents = File.read(::Rails.root.join(routes_file))
          if contents.include?(ENGINE_MOUNT_TOKEN)
            say_status :identical, "#{routes_file} (engine already mounted)", :blue
            return
          end

          snippet = "  mount Rails::Hyperdrive::Engine => \"#{mount_path}\" if Rails.env.development?\n"
          inject_into_file routes_file, snippet, after: /Rails\.application\.routes\.draw do\s*\n/
        end

        # The whole .claude content pipeline: skills, guidelines, stack.md,
        # index.md, CLAUDE.md injection, lockfile. One Thor step so ivars flow
        # in order.
        # `--skip-content` deliberately writes no lockfile either. The lock is a
        # manifest *of installed content*; with nothing installed there is
        # nothing to record, and an empty lock would assert "zero files is the
        # managed set". A later plain init/update reconstructs from scratch:
        # LockFile.load treats an absent file as empty, so every path reads as
        # missing → reinstall and claude_md.state as nil → inject.
        def sync_content
          return if options[:skip_content]

          @old_lock = ::Rails::Hyperdrive::LockFile.load(::Rails.root.join(LOCK_PATH).to_s)
          @new_lock = ::Rails::Hyperdrive::LockFile.new(::Rails.root.join(LOCK_PATH).to_s)

          @plan = build_install_plan
          install_skills
          install_guidelines
          install_stack
          carry_orphans
          write_index_md
          inject_claude_md
          write_lock
          print_warnings
          print_footprint
        end

        def print_summary
          say ""
          say_status :done, "hyperdrive #{update_mode? ? "updated" : "initialized"}", :green
          say "  Mount: #{mount_path} (in config/routes.rb)"
          unless options[:skip_content]
            say "  Guidelines: #{Array(@plan).count { |a| a[:type] == :guideline }} + stack.md"
            say "  Skills: #{Array(@plan).count { |a| a[:type] == :skill }}"
          end
          say ""
          say "  Next steps:"
          say "    1. bin/rails server"
          say "    2. Open Claude Code in this directory; it will read .mcp.json"
          say "    3. Verify the connection: curl http://localhost:3000#{mount_path}/mcp"
        end

        # ---------- helpers ----------

        no_tasks do
          def update_mode?
            options[:update] || options[:force_install]
          end

          # Normalize the user-supplied mount path.
          def mount_path
            raw = options[:mount_at].to_s
            raw = "/" + raw unless raw.start_with?("/")
            raw.length > 1 ? raw.chomp("/") : raw
          end

          def stack
            @stack_profile.to_h
          end

          # Phase 2: group Phase-1 survivors by [type, name]. A name shipped by
          # one source installs at its canonical path; a name shipped by
          # multiple sources installs all variants, postfixed --<source_gem>.
          def build_install_plan
            plan = []
            @artifacts.group_by { |a| [a.artifact_type, a.name] }.each do |(type, name), group|
              collision = group.size > 1
              if collision
                say_status :conflict,
                  "#{type} '#{name}' shipped by #{group.map(&:source_gem).join(", ")}; installing all (postfixed)",
                  :yellow
              end
              group.each do |artifact|
                final_name = collision ? "#{name}--#{artifact.source_gem}" : name
                plan << {
                  type: type,
                  artifact: artifact,
                  final_name: final_name,
                  dest: dest_for(type, final_name)
                }
              end
            end
            plan
          end

          def dest_for(type, final_name)
            case type
            when :skill     then ".claude/skills/#{final_name}/SKILL.md"
            when :guideline then ".claude/hyperdrive/guidelines/#{final_name}.md"
            end
          end

          def install_skills
            @plan.select { |p| p[:type] == :skill }.each do |p|
              artifact = p[:artifact]
              body = ::Rails::Hyperdrive::BundlerArtifactDiscovery.install_ready_body(artifact)
              # Postfixed skills rename the display `name:` to match the dir.
              body = rename_skill(body, p[:final_name]) if p[:final_name] != artifact.name
              install_file(
                dest: p[:dest],
                type: :skill,
                install_ready_body: body,
                source_gem: artifact.source_gem,
                version: artifact.spec_version,
                artifact_kind: "skill"
              )
            end
          end

          def install_guidelines
            @installed_guidelines = []
            @plan.select { |p| p[:type] == :guideline }.each do |p|
              artifact = p[:artifact]
              body = ::Rails::Hyperdrive::BundlerArtifactDiscovery.install_ready_body(artifact)
              warn_if_oversize(p[:dest], body)
              install_file(
                dest: p[:dest],
                type: :guideline,
                install_ready_body: body,
                source_gem: artifact.source_gem,
                version: artifact.spec_version,
                artifact_kind: "guideline"
              )
              @installed_guidelines << { base: "#{p[:final_name]}.md", dest: p[:dest], body: body }
            end
          end

          def install_stack
            body = ::Rails::Hyperdrive::StackDocument.render(stack)
            @stack_body = body
            warn_if_oversize(STACK_PATH, body)
            install_file(
              dest: STACK_PATH,
              type: :stack,
              install_ready_body: body,
              source_gem: "internal",
              version: ::Rails::Hyperdrive::VERSION,
              artifact_kind: "stack"
            )
          end

          # The drift state machine (spec §3.6). Decides, per file, whether to
          # leave it untouched (current), rewrite (gem changed / missing), or
          # skip-with-warning (user-edited, init) vs. force-overwrite (update).
          def install_file(dest:, type:, install_ready_body:, source_gem:, version:, artifact_kind:)
            abs = ::Rails.root.join(dest)
            gem_sha = sha(install_ready_body)
            old = @old_lock.entry(dest)
            source_label = "#{source_gem}@#{version}"

            if File.exist?(abs)
              disk_sha = sha(::Rails::Hyperdrive::AuditHeader.strip(File.read(abs)))
              unedited = old && disk_sha == old[:source_sha]

              if unedited && old[:source_sha] == gem_sha
                # Current: source unchanged → leave untouched, preserve installed_at.
                @new_lock.carry(old)
                say_status :unchanged, dest, :blue
                return
              elsif unedited
                # Gem upgraded, file not edited → rewrite.
                write_artifact(dest, type, install_ready_body, source_gem, version, gem_sha, artifact_kind)
                return
              else
                # User-edited (disk != lock) or untracked file present.
                if update_mode?
                  write_artifact(dest, type, install_ready_body, source_gem, version, gem_sha, artifact_kind)
                else
                  say_status :skip, "#{dest} (locally modified; run hyperdrive:update to overwrite)", :yellow
                  @new_lock.carry(old) if old
                end
                return
              end
            end

            # File missing.
            say_status(:reinstall, "#{dest} (was missing)", :yellow) if old
            write_artifact(dest, type, install_ready_body, source_gem, version, gem_sha, artifact_kind)
          end

          def write_artifact(dest, type, install_ready_body, source_gem, version, gem_sha, artifact_kind)
            installed_at = Time.now.utc
            body =
              if type == :skill
                header = ::Rails::Hyperdrive::AuditHeader.build(
                  source_gem: source_gem, version: version, body: install_ready_body, installed_at: installed_at
                )
                ::Rails::Hyperdrive::AuditHeader.inject_into_frontmatter(install_ready_body, header)
              else
                header = ::Rails::Hyperdrive::AuditHeader.build_html(
                  source_gem: source_gem, version: version, body: install_ready_body, installed_at: installed_at
                )
                ::Rails::Hyperdrive::AuditHeader.prepend_html(install_ready_body, header)
              end

            create_file dest, body, force: true
            @new_lock.upsert(
              path: dest,
              artifact: artifact_kind,
              source: "#{source_gem}@#{version}",
              source_sha: gem_sha,
              installed_at: installed_at.iso8601
            )
          end

          # Retain lock entries whose source gem is gone but whose file remains.
          def carry_orphans
            planned = @plan.map { |p| p[:dest] } + [STACK_PATH]
            @old_lock.each_entry do |entry|
              next if planned.include?(entry[:path])
              next if @new_lock.entry(entry[:path])
              abs = ::Rails.root.join(entry[:path])
              if File.exist?(abs)
                say_status :orphan, "#{entry[:path]} (source #{entry[:source]} no longer in bundle; left in place)", :yellow
                @new_lock.carry(entry)
              end
            end
          end

          # Managed aggregator: `@stack.md` + one `@guidelines/<name>.md` per
          # installed guideline. Honors per-guideline opt-out (a guideline whose
          # line a user deleted from an existing index.md is not re-added).
          def write_index_md
            index_abs = ::Rails.root.join(INDEX_PATH)
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

            # Only guidelines actually referenced by index.md are eager; opted-out
            # ones stay on disk but out of context. Footprint counts the eager set.
            @index_guideline_count = included.size
            @eager_guideline_bodies = included.map { |g| g[:body] }

            if existing == content
              say_status :unchanged, INDEX_PATH, :blue
            else
              create_file INDEX_PATH, content, force: true
            end
          end

          # Inject exactly one `@`-include line into CLAUDE.md, governed by the
          # opt-out state machine in lock.yml > claude_md.state.
          def inject_claude_md
            abs = ::Rails.root.join(CLAUDE_MD)
            present_on_disk = File.exist?(abs) && File.read(abs).include?(INDEX_LINE)
            state = @old_lock.claude_md_state

            new_state =
              if state.nil?
                if !File.exist?(abs)
                  create_file CLAUDE_MD,
                    "<!-- AI instructions for this project. Managed content lives in #{HYPERDRIVE_DIR}/. -->\n\n#{INDEX_LINE}\n"
                  ::Rails::Hyperdrive::LockFile::STATE_PRESENT
                elsif present_on_disk
                  ::Rails::Hyperdrive::LockFile::STATE_PRESENT
                else
                  append_to_file CLAUDE_MD, "\n#{INDEX_LINE}\n"
                  ::Rails::Hyperdrive::LockFile::STATE_PRESENT
                end
              elsif state == ::Rails::Hyperdrive::LockFile::STATE_PRESENT && !present_on_disk
                say_status :warn,
                  "you removed #{INDEX_LINE} from CLAUDE.md; leaving it out (won't re-add)", :yellow
                ::Rails::Hyperdrive::LockFile::STATE_REMOVED
              elsif state == ::Rails::Hyperdrive::LockFile::STATE_REMOVED && present_on_disk
                ::Rails::Hyperdrive::LockFile::STATE_PRESENT
              else
                state
              end

            @new_lock.claude_md_state = new_state
          end

          def write_lock
            create_file LOCK_PATH, @new_lock.to_yaml, force: true
          end

          def print_warnings
            return if Array(@warnings).empty?
            say ""
            say_status :warn, "discovery skipped #{@warnings.size} artifact(s):", :yellow
            @warnings.each { |w| say "    - #{w}" }
          end

          def print_footprint
            bodies = Array(@eager_guideline_bodies).dup
            bodies << @stack_body if @stack_body
            tokens = bodies.sum { |b| approx_tokens(b) }
            count = @index_guideline_count.to_i
            say_status :eager, "#{count} guideline(s) + stack.md, ~#{tokens} tokens always in context", :cyan
          end

          def warn_if_oversize(dest, body)
            lines = body.lines.size
            tokens = approx_tokens(body)
            return unless lines > WARN_LINES || tokens > WARN_TOKENS
            say_status :warn,
              "#{dest} is large (#{lines} lines, ~#{tokens} tokens); guidelines are eager — move tutorial content to a skill",
              :yellow
          end

          def approx_tokens(body)
            (body.to_s.length / 4.0).ceil
          end

          # Rewrite a skill's frontmatter `name:` to match its postfixed dir.
          def rename_skill(body, final_name)
            body.sub(/^name:\s*.+$/, "name: #{final_name}")
          end

          def sha(content)
            Digest::SHA256.hexdigest(content.to_s)
          end
        end
      end
    end
  end
end
