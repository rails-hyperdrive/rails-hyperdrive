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

    it "installs the companion's skill and guideline with audit headers, then re-syncs idempotently" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

      skill_path = File.join(app_dir, ".claude/skills/alpha-skill/SKILL.md")
      expect(File.exist?(skill_path)).to be(true), "alpha-skill not installed:\n#{out}"
      skill = File.read(skill_path)
      expect(skill).to start_with("---")
      expect(skill).to include("# hyperdrive: source=rails-hyperdrive-alpha@0.1.0")
      expect(skill).to include("# hyperdrive: sha256=")
      expect(skill).to include("name: alpha-skill")
      expect(skill).to include("gem: railties") # frontmatter retained
      expect(skill).to include("# Alpha Skill")

      guide_path = File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md")
      expect(File.exist?(guide_path)).to be(true), "alpha-guide not installed:\n#{out}"
      guide = File.read(guide_path)
      expect(guide).to start_with("<!-- hyperdrive: source=rails-hyperdrive-alpha@0.1.0 -->")
      expect(guide).to include("<!-- hyperdrive: sha256=")
      expect(guide).to include("# Alpha Guideline")
      expect(guide).not_to include("gem: railties") # frontmatter stripped

      index = File.read(File.join(app_dir, ".claude/hyperdrive/index.md"))
      expect(index).to include("@stack.md")
      expect(index).to include("@guidelines/alpha-guide.md")

      lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
      expect(lock).to include(".claude/skills/alpha-skill/SKILL.md")
      expect(lock).to include(".claude/hyperdrive/guidelines/alpha-guide.md")
      expect(lock).to include("rails-hyperdrive-alpha@0.1.0")

      expect(out).to match(/1 guideline\(s\) \+ stack\.md, ~[1-9]\d* tokens always in context/)

      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(/unchanged/)
      expect(File.read(skill_path)).to eq(skill)
      expect(File.read(guide_path)).to eq(guide)
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
      expect(out_sync).to match(%r{skip.*alpha-guide\.md.*locally modified.*hyperdrive:sync --overwrite}m)
      expect(File.read(guide_path)).to include("LOCAL EDIT")

      out_ow, st_ow = Smoke.run_hyperdrive_sync!(app_dir, "--overwrite")
      expect(st_ow.success?).to be(true), out_ow
      expect(out_ow).to match(/hyperdrive synced/)
      restored = File.read(guide_path)
      expect(restored).not_to include("LOCAL EDIT")
      expect(restored).to start_with("<!-- hyperdrive: source=rails-hyperdrive-alpha@0.1.0 -->")
      expect(restored).to include("# Alpha Guideline")
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

      index = File.read(File.join(app_dir, ".claude/hyperdrive/index.md"))
      expect(index).to include("@stack.md")
      expect(index).not_to include("@guidelines/alpha-guide.md")

      expect(YAML.safe_load(File.read(lock_path))["disabled"])
        .to eq("skills" => ["alpha-skill"], "guidelines" => ["alpha-guide"])

      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(Dir.exist?(skill_dir)).to be(false)
      expect(File.exist?(guide_path)).to be(false)

      rewrite_disabled(skills: [], guidelines: [])
      out3, status3 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status3.success?).to be(true), out3
      expect(File.exist?(File.join(skill_dir, "SKILL.md"))).to be(true), "skill not restored:\n#{out3}"
      expect(File.exist?(guide_path)).to be(true), "guideline not restored:\n#{out3}"
      expect(File.read(File.join(app_dir, ".claude/hyperdrive/index.md")))
        .to include("@guidelines/alpha-guide.md")
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
      expect(out).to match(/2 guideline\(s\) \+ stack\.md, ~[1-9]\d* tokens always in context/)

      # The installed name rewrite must round-trip through the header strip,
      # or a second run would read as drift and rewrite the file.
      alpha_before = File.read(alpha)
      out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(/unchanged/)
      expect(File.read(alpha)).to eq(alpha_before)
      expect(File.read(alpha)).to include("name: shared-skill--rails-hyperdrive-alpha")
    end
  end
end
