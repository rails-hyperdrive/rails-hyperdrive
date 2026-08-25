require "json"
require "yaml"
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
      expect(index).to eq("@guidelines/alpha-guide.md\n")
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

      lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
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

      expect(out).to match(/1 guideline\(s\), ~[1-9]\d* tokens always in context/)

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
  end

  describe "per-artifact opt-out" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }
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
      lock = YAML.safe_load(File.read(lock_path))
      lock["disabled"] = { "skills" => skills, "guidelines" => guidelines }
      File.write(lock_path, lock.to_yaml)
    end

    it "uninstalls disabled artifacts, keeps them gone, and restores them when re-enabled" do
      expect(File.exist?(File.join(skill_dir, "SKILL.md"))).to be(true)
      expect(File.exist?(guide_path)).to be(true)

      rewrite_disabled(skills: ["alpha-skill"], guidelines: ["alpha-guide"])

      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), out
      expect(Dir.exist?(skill_dir)).to be(false), "disabled skill directory survived:\n#{out}"
      expect(File.exist?(guide_path)).to be(false), "disabled guideline survived:\n#{out}"

      # The last guideline going leaves nothing for the eager chain to carry.
      # CLAUDE.md here is still byte-identical to the one init wrote, so it goes too.
      expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/index.md"))).to be(false)
      expect(File.exist?(File.join(app_dir, "CLAUDE.md"))).to be(false)

      expect(YAML.safe_load(File.read(lock_path))["disabled"])
        .to eq("skills" => ["alpha-skill"], "guidelines" => ["alpha-guide"], "agents" => [], "commands" => [])

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
      expect(out).to match(/2 guideline\(s\), ~[1-9]\d* tokens always in context/)

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
end
