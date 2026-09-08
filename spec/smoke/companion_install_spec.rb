require "digest"
require "json"
require "yaml"
require "rails/hyperdrive/lock_file"
require_relative "smoke_helper"

RSpec.describe "hyperdrive companion install smoke", :smoke do
  describe "installing a single companion gem" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
    end

    it "installs the companion's skill and guideline verbatim, then re-syncs idempotently" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

      skill_path = File.join(app_dir, ".claude/skills/alpha-skill/SKILL.md")
      expect(File.exist?(skill_path)).to be(true), "alpha-skill not installed:\n#{out}"
      skill = File.read(skill_path)
      expect(skill).to start_with("---")
      expect(skill).not_to include("hyperdrive:") # no audit header
      expect(skill).to include("name: alpha-skill")
      expect(skill).not_to include("gem: railties") # the manifest's gate never reaches the installed body
      expect(skill).not_to include("conditional:")
      expect(skill).to include("description:")
      expect(skill).to include("# Alpha Skill")
      # alpha-skill is template/content paired: the installed definition must be
      # the template rendered against the app bundle, not the static face.
      expect(skill).to match(/This app persists with sqlite3 2\./)
      expect(skill).not_to include("(any version)")

      support_path = File.join(app_dir, ".claude/skills/alpha-skill/references/deep-dive.md")
      expect(File.exist?(support_path)).to be(true), "alpha-skill supporting file not installed:\n#{out}"
      shipped = File.binread(File.expand_path(
        "../fixtures/smoke_companions/rails-hyperdrive-alpha/skills/alpha-skill/references/deep-dive.md",
        __dir__
      ))
      expect(File.binread(support_path)).to eq(shipped) # byte-identical, no audit header

      gated_in = File.join(app_dir, ".claude/skills/alpha-skill/references/sqlite-notes.md")
      expect(File.exist?(gated_in)).to be(true), "gated-in supporting file not installed:\n#{out}"
      gated_out = File.join(app_dir, ".claude/skills/alpha-skill/references/alba-notes.md")
      expect(File.exist?(gated_out)).to be(false), "gated-out supporting file installed:\n#{out}"

      # The committed canonical face carries every branch, so an Alba-free body
      # proves the template-side render superseded it.
      rendered = File.join(app_dir, ".claude/skills/alpha-skill/references/stack-notes.md")
      expect(File.exist?(rendered)).to be(true), "rendered .md.erb not installed:\n#{out}"
      stack_notes = File.read(rendered)
      expect(stack_notes).to include("This app persists to SQLite (sqlite3 2.")
      expect(stack_notes).not_to include("Alba")
      expect(stack_notes).not_to include("<%")
      expect(File.exist?(rendered + ".erb")).to be(false)
      expect(out).not_to include("ignoring")

      guide_path = File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md")
      expect(File.exist?(guide_path)).to be(true), "alpha-guide not installed:\n#{out}"
      guide = File.read(guide_path)
      expect(guide).to start_with("# Alpha Guideline")
      expect(guide).not_to include("hyperdrive:") # no audit header
      expect(guide).not_to include("gem: railties") # frontmatter stripped

      # The eager chain exists only because the companion shipped a guideline.
      index = File.read(File.join(app_dir, ".claude/hyperdrive/index.md"))
      expect(index.lines.map(&:chomp)).to contain_exactly(
        "@guidelines/alpha-guide.md", "@guidelines/alpha-stack-guide.md"
      )
      expect(File.read(File.join(app_dir, "CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")

      agent_path = File.join(app_dir, ".claude/agents/alpha-agent.md")
      expect(File.exist?(agent_path)).to be(true), "alpha-agent not installed:\n#{out}"
      agent = File.read(agent_path)
      expect(agent).to start_with("---")
      expect(agent).to include("name: alpha-agent", "tools: Read, Grep") # frontmatter kept verbatim

      # command_prefix: alpha renames the file and the /slash-command with it.
      command_path = File.join(app_dir, ".claude/commands/alpha-analyze.md")
      expect(File.exist?(command_path)).to be(true), "alpha-analyze not installed:\n#{out}"
      command = File.read(command_path)
      expect(command).to eq(File.read(File.expand_path(
        "../fixtures/smoke_companions/rails-hyperdrive-alpha/commands/analyze.md", __dir__
      )))
      expect(File.exist?(File.join(app_dir, ".claude/commands/analyze.md"))).to be(false)

      # Flat kinds ship *.md.erb in their own root and install as the rendered face.
      scout_path = File.join(app_dir, ".claude/agents/alpha-scout.md")
      expect(File.exist?(scout_path)).to be(true), "alpha-scout not installed:\n#{out}"
      scout = File.read(scout_path)
      expect(scout).to start_with("---")
      expect(scout).to include("name: alpha-scout", "tools: Read, Grep") # frontmatter kept verbatim
      expect(scout).to match(/sqlite3 2\./)
      expect(scout).not_to include("Alba")
      expect(scout).not_to include("<%")
      expect(File.exist?(scout_path + ".erb")).to be(false)

      # A templated command takes its identity from the rendered stem, prefix and all.
      stack_cmd_path = File.join(app_dir, ".claude/commands/alpha-stack.md")
      expect(File.exist?(stack_cmd_path)).to be(true), "alpha-stack not installed:\n#{out}"
      stack_cmd = File.read(stack_cmd_path)
      expect(stack_cmd).to match(/sqlite3 2\./)
      expect(stack_cmd).not_to include("Alba")
      expect(stack_cmd).not_to include("<%")
      expect(File.exist?(File.join(app_dir, ".claude/commands/stack.md"))).to be(false)
      expect(File.exist?(stack_cmd_path + ".erb")).to be(false)

      # A templated guideline renders first, then has the rendered frontmatter stripped.
      stack_guide_path = File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-stack-guide.md")
      expect(File.exist?(stack_guide_path)).to be(true), "alpha-stack-guide not installed:\n#{out}"
      stack_guide = File.read(stack_guide_path)
      expect(stack_guide).to start_with("# Alpha Stack Guideline")
      expect(stack_guide).not_to include("description:") # frontmatter stripped post-render
      expect(stack_guide).to match(/sqlite3 2\./)
      expect(stack_guide).not_to include("Alba")
      expect(stack_guide).not_to include("<%")

      lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
      expect(lock).to include(".claude/agents/alpha-scout.md")
      expect(lock).to include(".claude/commands/alpha-stack.md")
      expect(lock).to include(".claude/hyperdrive/guidelines/alpha-stack-guide.md")
      expect(lock).not_to include(".md.erb")
      expect(lock).to include(".claude/agents/alpha-agent.md")
      expect(lock).to include(".claude/commands/alpha-analyze.md")
      expect(lock).to include("artifact: agent")
      expect(lock).to include("artifact: command")
      expect(lock).to include(".claude/skills/alpha-skill/SKILL.md")
      expect(lock).to include(".claude/skills/alpha-skill/references/deep-dive.md")
      expect(lock).to include(".claude/skills/alpha-skill/references/sqlite-notes.md")
      expect(lock).to include(".claude/skills/alpha-skill/references/stack-notes.md")
      expect(lock).not_to include("alba-notes.md")
      expect(lock).not_to include("stack-notes.md.erb")
      expect(lock).to include("artifact: skill_support")
      expect(lock).to include(".claude/hyperdrive/guidelines/alpha-guide.md")
      expect(lock).to include("rails-hyperdrive-alpha@0.1.0")

      expect(out).to match(/skill\s+alpha-skill \(\+3 files\)/)

      expect(out).to match(/2 guideline\(s\), ~[1-9]\d* tokens always in context/)

      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(/unchanged/)
      expect(out2).to match(%r{unchanged\s+\.claude/agents/alpha-agent\.md})
      expect(out2).to match(%r{unchanged\s+\.claude/commands/alpha-analyze\.md})
      expect(File.read(skill_path)).to eq(skill)
      expect(File.binread(support_path)).to eq(shipped)
      expect(File.read(guide_path)).to eq(guide)
      expect(File.read(agent_path)).to eq(agent)
      expect(File.read(command_path)).to eq(command)
      expect(File.read(scout_path)).to eq(scout)
      expect(File.read(stack_cmd_path)).to eq(stack_cmd)
      expect(File.read(stack_guide_path)).to eq(stack_guide)
    end
  end

  describe "hyperdrive:sync vs a locally-modified file" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      _out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true)
    end

    it "sync skips the edited file with a warning; --overwrite restores it" do
      pristine = File.read(guide_path)
      File.write(guide_path, pristine + "\n<!-- LOCAL EDIT, do not clobber -->\n")

      out_sync, st_sync = Smoke.run_hyperdrive_sync!(app_dir)
      expect(st_sync.success?).to be(true), out_sync
      expect(out_sync).to match(%r{skip.*alpha-guide\.md.*locally modified.*--merge, --sidecar, or --overwrite}m)
      expect(File.read(guide_path)).to include("LOCAL EDIT")

      out_ow, st_ow = Smoke.run_hyperdrive_sync!(app_dir, "--overwrite")
      expect(st_ow.success?).to be(true), out_ow
      expect(out_ow).to match(/hyperdrive synced/)
      restored = File.read(guide_path)
      expect(restored).not_to include("LOCAL EDIT")
      expect(restored).to start_with("# Alpha Guideline")
    end
  end

  describe "hyperdrive:sync --sidecar vs a locally-modified file" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:companion_dir) { File.join(app_dir, "vendor-alpha") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }
    let(:shipped_guide) do
      File.join(companion_dir, "lib/rails-hyperdrive-alpha/hyperdrive/guidelines/alpha-guide.md")
    end

    before do
      # A mutable copy of the companion, so the shipped body can change
      # underneath the app; delivery is keyed on the content hash the lock
      # records, not on a version bump.
      FileUtils.mkdir_p(companion_dir)
      Smoke.sh!("cp", "-a", "#{File.join(Smoke::COMPANIONS_ROOT, "rails-hyperdrive-alpha")}/.", companion_dir)
      Smoke.add_path_gem!(app_dir)
      File.open(File.join(app_dir, "Gemfile"), "a") do |f|
        f.write(%(gem "rails-hyperdrive-alpha", path: #{companion_dir.inspect}\n))
      end
      Smoke.bundle_install!(app_dir)
      _out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true)
    end

    it "delivers the upstream to <file>.new, re-locks it, and mv accepts it" do
      edited_live = File.read(guide_path) + "\n<!-- LOCAL EDIT, do not clobber -->\n"
      File.write(guide_path, edited_live)
      File.write(shipped_guide, File.read(shipped_guide) + "\nUpstream v2 addition.\n")

      out, st = Smoke.run_hyperdrive_sync!(app_dir, "--sidecar")
      expect(st.success?).to be(true), out
      expect(out).to match(%r{sidecar.*alpha-guide\.md.*delivered to}m)

      expect(File.read(guide_path)).to eq(edited_live) # live file byte-untouched
      sidecar = File.read("#{guide_path}.new")
      expect(sidecar).to start_with("# Alpha Guideline")
      expect(sidecar).to include("Upstream v2 addition.")
      expect(sidecar).not_to include("LOCAL EDIT")

      lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
      expect(lock).not_to include("alpha-guide.md.new")

      FileUtils.mv("#{guide_path}.new", guide_path)
      out2, st2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(st2.success?).to be(true), out2
      expect(out2).to match(%r{unchanged.*alpha-guide\.md})
      expect(File.read(guide_path)).to include("Upstream v2 addition.")
    end

    it "hands the sidecar to the configured resolver command and sweeps it on exit 0" do
      resolver = File.join(app_dir, "bin/fake-resolver")
      File.write(resolver, <<~RUBY)
        #!/usr/bin/env ruby
        merged = ENV.fetch("HYPERDRIVE_MERGED")
        File.write(merged, File.read(ENV.fetch("HYPERDRIVE_REMOTE")) + "\n" + ENV.fetch("HYPERDRIVE_PROMPT").lines.first)
      RUBY
      File.chmod(0o755, resolver)

      config_path = File.join(app_dir, ".hyperdrive/config.yml")
      config = YAML.safe_load(File.read(config_path)) || {}
      config["resolve"] = { "command" => "bin/fake-resolver $LOCAL $REMOTE" }
      File.write(config_path, config.to_yaml)

      File.write(guide_path, File.read(guide_path) + "\n<!-- LOCAL EDIT -->\n")
      File.write(shipped_guide, File.read(shipped_guide) + "\nUpstream v2 addition.\n")

      out, st = Smoke.run_hyperdrive_sync!(app_dir, "--sidecar", "--resolve")
      expect(st.success?).to be(true), out
      expect(out).to match(%r{\bresolved.*alpha-guide\.md})
      expect(out).to include("Sidecars: 1 resolved")

      expect(File.exist?("#{guide_path}.new")).to be(false)
      resolved = File.read(guide_path)
      expect(resolved).to include("Upstream v2 addition.")
      expect(resolved).to include("You are resolving one file")

      lock = YAML.safe_load(File.read(File.join(app_dir, ".hyperdrive/lock.yml")))
      entry = lock["files"].find { |f| f["path"] == ".claude/hyperdrive/guidelines/alpha-guide.md" }
      expect(entry["source"]).to start_with("rails-hyperdrive-alpha@")

      out2, st2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(st2.success?).to be(true), out2
      expect(out2).to include("locally modified")
      expect(out2).not_to include("unresolved sidecar")
      expect(File.read(guide_path)).to eq(resolved)
    end

    # An exit status is not proof of a resolution: a tool denied every write
    # still exits 0.
    it "leaves everything untouched when the resolver exits 0 without writing $MERGED" do
      resolver = File.join(app_dir, "bin/noop-resolver")
      File.write(resolver, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, resolver)

      config_path = File.join(app_dir, ".hyperdrive/config.yml")
      config = YAML.safe_load(File.read(config_path)) || {}
      config["resolve"] = { "command" => "bin/noop-resolver $LOCAL $REMOTE" }
      File.write(config_path, config.to_yaml)

      edited_live = File.read(guide_path) + "\n<!-- LOCAL EDIT -->\n"
      File.write(guide_path, edited_live)
      File.write(shipped_guide, File.read(shipped_guide) + "\nUpstream v2 addition.\n")

      out, st = Smoke.run_hyperdrive_sync!(app_dir, "--sidecar", "--resolve")
      expect(st.success?).to be(true), out
      expect(out).to match(%r{unresolved.*alpha-guide\.md.*command exited 0 but wrote nothing})
      expect(out).to include("Sidecars: 1 unresolved")

      sidecar = "#{guide_path}.new"
      expect(File.exist?(sidecar)).to be(true), "the sidecar was swept without a resolution:\n#{out}"
      expect(File.read(sidecar)).to include("Upstream v2 addition.")
      expect(File.read(guide_path)).to eq(edited_live)

      lock = YAML.safe_load(File.read(File.join(app_dir, ".hyperdrive/lock.yml")))
      entry = lock["files"].find { |f| f["path"] == ".claude/hyperdrive/guidelines/alpha-guide.md" }
      expect(entry["source_sha"]).to eq(Digest::SHA256.hexdigest(File.binread(sidecar)))
    end
  end

  describe "per-artifact opt-out" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }
    let(:config_path) { File.join(app_dir, ".hyperdrive/config.yml") }
    let(:skill_dir) { File.join(app_dir, ".claude/skills/alpha-skill") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      _out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true)
    end

    def rewrite_disabled(skills:, guidelines:)
      config = YAML.safe_load(File.read(config_path))
      config["disabled"] = { "skills" => skills, "guidelines" => guidelines, "agents" => [], "commands" => [] }
      File.write(config_path, config.to_yaml)
    end

    it "uninstalls disabled artifacts, keeps them gone, and restores them when re-enabled" do
      expect(File.exist?(File.join(skill_dir, "SKILL.md"))).to be(true)
      expect(File.exist?(guide_path)).to be(true)

      rewrite_disabled(skills: ["alpha-skill"], guidelines: ["alpha-guide", "alpha-stack-guide"])

      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), out
      expect(Dir.exist?(skill_dir)).to be(false), "disabled skill directory survived:\n#{out}"
      expect(File.exist?(guide_path)).to be(false), "disabled guideline survived:\n#{out}"

      # The last guideline going leaves nothing for the eager chain to carry.
      # CLAUDE.md here is still byte-identical to the one init wrote, so it goes too.
      expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/index.md"))).to be(false)
      expect(File.exist?(File.join(app_dir, "CLAUDE.md"))).to be(false)

      expect(YAML.safe_load(File.read(config_path))["disabled"])
        .to eq("skills" => ["alpha-skill"], "guidelines" => ["alpha-guide", "alpha-stack-guide"],
          "agents" => [], "commands" => [])
      expect(YAML.safe_load(File.read(lock_path))).not_to have_key("disabled")

      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(Dir.exist?(skill_dir)).to be(false)
      expect(File.exist?(guide_path)).to be(false)

      rewrite_disabled(skills: [], guidelines: [])
      out3, status3 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status3.success?).to be(true), out3
      expect(File.exist?(File.join(skill_dir, "SKILL.md"))).to be(true), "skill not restored:\n#{out3}"
      expect(File.exist?(File.join(skill_dir, "references/deep-dive.md"))).to be(true), "supporting file not restored:\n#{out3}"
      expect(File.exist?(guide_path)).to be(true), "guideline not restored:\n#{out3}"
      expect(File.read(File.join(app_dir, ".claude/hyperdrive/index.md")))
        .to include("@guidelines/alpha-guide.md")
      expect(File.read(File.join(app_dir, "CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")
    end
  end

  describe "cross-source skill collision" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
      Smoke.bundle_install!(app_dir)
    end

    it "installs both shared-skill variants postfixed by source, and stays idempotent" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

      expect(out).to match(/conflict.*shared-skill/)

      alpha = File.join(app_dir, ".claude/skills/shared-skill--rails-hyperdrive-alpha/SKILL.md")
      beta  = File.join(app_dir, ".claude/skills/shared-skill--rails-hyperdrive-beta/SKILL.md")
      expect(File.exist?(alpha)).to be(true), "alpha shared-skill missing:\n#{out}"
      expect(File.exist?(beta)).to be(true), "beta shared-skill missing:\n#{out}"

      expect(Dir.exist?(File.join(app_dir, ".claude/skills/shared-skill"))).to be(false)

      expect(File.read(alpha)).to include("name: shared-skill--rails-hyperdrive-alpha")
      expect(File.read(beta)).to include("name: shared-skill--rails-hyperdrive-beta")
      expect(File.read(alpha)).to include("alpha variant")
      expect(File.read(beta)).to include("beta variant")

      expect(File.exist?(File.join(app_dir, ".claude/skills/alpha-skill/SKILL.md"))).to be(true)
      expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md"))).to be(true)
      expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))).to be(true)

      index = File.read(File.join(app_dir, ".claude/hyperdrive/index.md"))
      expect(index).to include("@guidelines/alpha-guide.md")
      expect(index).to include("@guidelines/beta-guide.md")
      expect(out).to match(/3 guideline\(s\), ~[1-9]\d* tokens always in context/)

      # The installed name rewrite must be stable across runs, or a second run
      # would read as drift and rewrite the file.
      alpha_before = File.read(alpha)
      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(/unchanged/)
      expect(File.read(alpha)).to eq(alpha_before)
      expect(File.read(alpha)).to include("name: shared-skill--rails-hyperdrive-alpha")
    end
  end

  describe "a companion fenced out by hyperdrive_version:" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:beta_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-beta") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md") }

    def fence_line(kind, name)
      "#{kind} '#{name}' (from rails-hyperdrive-beta) requires rails-hyperdrive >= 99 " \
        "(this is #{Rails::Hyperdrive::VERSION}); upgrade rails-hyperdrive to install it"
    end

    def set_fence(requirement)
      path = File.join(beta_dir, "hyperdrive.yml")
      manifest = YAML.safe_load(File.read(path))
      requirement ? manifest["hyperdrive_version"] = requirement : manifest.delete("hyperdrive_version")
      File.write(path, manifest.to_yaml)
    end

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      set_fence(">= 99")
      Smoke.bundle_install!(app_dir)
    end

    it "skips every artifact with the fence line, and holds an installed one when the fence returns" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

      expect(out).to include("discovery skipped 2 item(s):")
      expect(out).to include(fence_line("guideline", "beta-guide"))
      expect(out).to include(fence_line("skill", "shared-skill"))
      expect(File.exist?(guide_path)).to be(false), "a fenced-out artifact installed:\n#{out}"

      set_fence(nil)
      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(File.exist?(guide_path)).to be(true), "beta-guide not installed once unfenced:\n#{out2}"

      set_fence(">= 99")
      out3, status3 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status3.success?).to be(true), out3
      expect(out3).to include(fence_line("guideline", "beta-guide"))
      expect(out3).to match(
        %r{orphan.*beta-guide\.md.*rails-hyperdrive-beta is still bundled but did not offer this file; left in place}
      )
      expect(File.exist?(guide_path)).to be(true), "a fenced-out artifact on disk must be held:\n#{out3}"
      expect(File.read(File.join(app_dir, ".hyperdrive/lock.yml")))
        .to include(".claude/hyperdrive/guidelines/beta-guide.md")
    end
  end

  describe "multi-target gem gates" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:beta_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-beta") }

    before do
      Smoke.add_path_gem!(app_dir)
      path = File.join(beta_dir, "hyperdrive.yml")
      manifest = YAML.safe_load(File.read(path))
      manifest["guidelines"] = {"beta-guide.md" => {"gem" => {"any" => %w[sqlite3 alba]}}}
      manifest["skills"] = {"shared-skill" => {"gem" => {"all" => %w[sqlite3 alba]}}}
      File.write(path, manifest.to_yaml)
      Smoke.bundle_install!(app_dir)
    end

    it "installs on an any: match and reports the AND-flavored miss for all:" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

      expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md")))
        .to be(true), "an any: gate matching sqlite3 did not install:\n#{out}"

      expect(out).to include("discovery skipped 1 item(s):")
      expect(out).to include(
        "skip shared-skill (from rails-hyperdrive-beta): required target gem 'alba' not in bundle"
      )
      expect(Dir.exist?(File.join(app_dir, ".claude/skills/shared-skill"))).to be(false)
    end
  end

  describe "a bundled gem that never opted in" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:config_path) { File.join(app_dir, ".hyperdrive/config.yml") }
    let(:skill_path) { File.join(app_dir, ".claude/skills/plain-skill/SKILL.md") }
    let(:notice) do
      %(gem 'plain-skills-gem' ships 1 skills.sh skill(s); add "plain-skills-gem" to enabled: ) +
        "in .hyperdrive/config.yml and re-run bin/rails hyperdrive:sync to install them"
    end

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.write_plain_gem!(app_dir, name: "plain-skills-gem", skill: "plain-skill")
      Smoke.bundle_install!(app_dir)
    end

    it "is surfaced as a notice, and installs only once enabled: names it" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      expect(out).to include(notice)
      expect(File.exist?(skill_path)).to be(false), "an un-opted gem's skill installed:\n#{out}"

      config = YAML.safe_load(File.read(config_path))
      config["enabled"] = ["plain-skills-gem"]
      File.write(config_path, config.to_yaml)

      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(File.exist?(skill_path)).to be(true), "an enabled: gem's skill did not install:\n#{out2}"
      expect(out2).not_to include(notice)
    end
  end

  describe "a companion that stops offering an artifact" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:beta_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-beta") }
    let(:shipped_guide) do
      File.join(beta_dir, "lib/rails-hyperdrive-beta/hyperdrive/guidelines/beta-guide.md")
    end
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      beta_dir
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      expect(File.exist?(guide_path)).to be(true)
    end

    it "removes the stale destination and drops its lock entry" do
      FileUtils.rm(shipped_guide)

      out, status = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status.success?).to be(true), out
      expect(out).to match(%r{remove\s+\.claude/hyperdrive/guidelines/beta-guide\.md})
      expect(File.exist?(guide_path)).to be(false), "the stale destination survived:\n#{out}"
      expect(File.read(lock_path)).not_to include("beta-guide.md")
      expect(File.read(File.join(app_dir, ".claude/hyperdrive/index.md")))
        .not_to include("@guidelines/beta-guide.md")
    end

    it "reports both orphan flavors and leaves the file in place" do
      File.write(shipped_guide, "# Beta Guideline\n\nShipped without frontmatter.\n")

      out, status = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status.success?).to be(true), out
      expect(out).to include("missing or malformed frontmatter")
      expect(out).to match(
        %r{orphan.*beta-guide\.md.*rails-hyperdrive-beta is still bundled but did not offer this file; left in place}
      )
      expect(File.exist?(guide_path)).to be(true), "a held orphan was removed:\n#{out}"

      gemfile = File.join(app_dir, "Gemfile")
      File.write(gemfile, File.read(gemfile).lines.reject { |l| l.include?("rails-hyperdrive-beta") }.join)
      Smoke.bundle_install!(app_dir)

      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(
        %r{orphan.*beta-guide\.md.*no longer shipped by rails-hyperdrive-beta@0\.2\.0; left in place}
      )
      expect(File.exist?(guide_path)).to be(true), "an orphan was removed:\n#{out2}"
      expect(File.read(lock_path)).to include(".claude/hyperdrive/guidelines/beta-guide.md")
    end
  end

  describe "a lock written by a newer installer" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
    end

    # A generator's Thor::Error prints and stops the run, but bin/rails still
    # exits 0, so the halt shows up as output plus the absence of any write.
    it "halts sync before any content write, --dry-run included" do
      FileUtils.rm(guide_path)
      File.write(lock_path, File.read(lock_path).sub(/^version: \d+$/, "version: 99"))
      frozen = File.binread(lock_path)
      message = ".hyperdrive/lock.yml was written by a newer rails-hyperdrive (lock schema 99, " \
        "this installer supports #{Rails::Hyperdrive::LockFile::SCHEMA_VERSION}); upgrade rails-hyperdrive"

      [["--dry-run"], []].each do |flags|
        out, = Smoke.run_hyperdrive_sync!(app_dir, *flags)
        expect(out).to include(message), "sync #{flags.inspect} did not halt:\n#{out}"
        expect(File.exist?(guide_path)).to be(false), "sync #{flags.inspect} wrote content:\n#{out}"
        expect(File.binread(lock_path)).to eq(frozen), "sync #{flags.inspect} rewrote the lock:\n#{out}"
      end
    end
  end

  describe "cross-source agent and command collision" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:beta_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-beta") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      FileUtils.mkdir_p(File.join(beta_dir, "agents"))
      File.write(File.join(beta_dir, "agents/alpha-agent.md"), <<~MD)
        ---
        name: alpha-agent
        description: Smoke-fixture subagent shipped by the beta companion too.
        ---

        Beta variant of the agent.
      MD
      # Beta declares no command_prefix, so the shipped stem is already the
      # identity alpha reaches by prefixing analyze.md.
      FileUtils.mkdir_p(File.join(beta_dir, "commands"))
      File.write(File.join(beta_dir, "commands/alpha-analyze.md"), "Beta variant of the command.\n")
      Smoke.bundle_install!(app_dir)
    end

    it "postfixes both kinds by source and rewrites name: for the agent only" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      expect(out).to match(/conflict\s+agent 'alpha-agent' shipped by/)
      expect(out).to match(/conflict\s+command 'alpha-analyze' shipped by/)

      alpha_agent = File.join(app_dir, ".claude/agents/alpha-agent--rails-hyperdrive-alpha.md")
      beta_agent = File.join(app_dir, ".claude/agents/alpha-agent--rails-hyperdrive-beta.md")
      expect(File.read(alpha_agent)).to include("name: alpha-agent--rails-hyperdrive-alpha")
      expect(File.read(beta_agent)).to include("name: alpha-agent--rails-hyperdrive-beta")
      expect(File.read(beta_agent)).to include("Beta variant of the agent.")
      expect(File.exist?(File.join(app_dir, ".claude/agents/alpha-agent.md"))).to be(false)

      alpha_command = File.join(app_dir, ".claude/commands/alpha-analyze--rails-hyperdrive-alpha.md")
      beta_command = File.join(app_dir, ".claude/commands/alpha-analyze--rails-hyperdrive-beta.md")
      expect(File.binread(alpha_command)).to eq(File.binread(
        File.join(Smoke::COMPANIONS_ROOT, "rails-hyperdrive-alpha/commands/analyze.md")
      ))
      expect(File.binread(beta_command)).to eq(File.binread(File.join(beta_dir, "commands/alpha-analyze.md")))
      expect(File.exist?(File.join(app_dir, ".claude/commands/alpha-analyze.md"))).to be(false)

      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(%r{unchanged\s+\.claude/agents/alpha-agent--rails-hyperdrive-beta\.md})
      expect(out2).to match(%r{unchanged\s+\.claude/commands/alpha-analyze--rails-hyperdrive-beta\.md})
    end
  end
end
