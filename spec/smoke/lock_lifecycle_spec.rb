require "digest"
require "fileutils"
require "yaml"
require "rails/hyperdrive/lock_file"
require_relative "smoke_helper"

# The lock and drift machine observed across more than one run: what a run
# records is what the next run — sync, init, or the bundler hook — must honour.
RSpec.describe "hyperdrive lock lifecycle smoke", :smoke do
  describe "a companion that stops shipping a supporting file" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:alpha_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-alpha") }
    let(:shipped_skill) { File.join(alpha_dir, "skills/alpha-skill") }
    let(:installed_skill) { File.join(app_dir, ".claude/skills/alpha-skill") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }

    before do
      Smoke.add_path_gem!(app_dir)
      FileUtils.mkdir_p(File.join(shipped_skill, "extras"))
      FileUtils.mkdir_p(File.join(shipped_skill, "scratch"))
      File.write(File.join(shipped_skill, "extras/customized.md"), "# Customized\n")
      File.write(File.join(shipped_skill, "scratch/disposable.md"), "# Disposable\n")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
    end

    it "removes the unedited copy and prunes its directory, keeping the edited one" do
      customized = File.join(installed_skill, "extras/customized.md")
      disposable = File.join(installed_skill, "scratch/disposable.md")
      expect(File.exist?(customized)).to be(true)
      expect(File.exist?(disposable)).to be(true)

      File.write(customized, "# Customized\n\nMY LOCAL EDIT\n")
      FileUtils.rm_rf(File.join(shipped_skill, "extras"))
      FileUtils.rm_rf(File.join(shipped_skill, "scratch"))

      out, status = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status.success?).to be(true), out

      expect(File.exist?(disposable)).to be(false), "an unedited stale supporting file survived:\n#{out}"
      expect(Dir.exist?(File.dirname(disposable))).to be(false), "the emptied directory was not pruned:\n#{out}"

      expect(out).to match(
        %r{skip\s+\.claude/skills/alpha-skill/extras/customized\.md \(no longer shipped by rails-hyperdrive-alpha@0\.1\.0 but locally modified; delete it by hand\)}
      )
      expect(File.read(customized)).to eq("# Customized\n\nMY LOCAL EDIT\n")

      lock = File.read(lock_path)
      expect(lock).to include(".claude/skills/alpha-skill/extras/customized.md")
      expect(lock).not_to include("disposable.md")
      # The owning skill is still planned, so nothing else moved.
      expect(File.exist?(File.join(installed_skill, "SKILL.md"))).to be(true)
      expect(File.exist?(File.join(installed_skill, "references/deep-dive.md"))).to be(true)
    end
  end

  describe "the CLAUDE.md import line the user removed" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:claude_md) { File.join(app_dir, "CLAUDE.md") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }
    let(:import_line) { "@.claude/hyperdrive/index.md" }

    def claude_md_state
      YAML.safe_load(File.read(lock_path)).dig("claude_md", "state")
    end

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      expect(File.read(claude_md)).to include(import_line)
      expect(claude_md_state).to eq("present")
    end

    it "is never re-added, by a sync or by the bundler hook" do
      File.write(claude_md, File.read(claude_md).lines.reject { |l| l.strip == import_line }.join)
      kept = File.read(claude_md)

      out, status = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status.success?).to be(true), out
      expect(out).to include("you removed #{import_line} from CLAUDE.md; leaving it out (won't re-add)")
      expect(File.read(claude_md)).to eq(kept)
      expect(claude_md_state).to eq("removed-by-user")

      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(File.read(claude_md)).to eq(kept)
      expect(claude_md_state).to eq("removed-by-user")

      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
      hook_out = Smoke.bundle_install!(app_dir)

      # The printed line is what proves the hook ran rather than no-opping.
      expect(hook_out).to include("[hyperdrive] installed")
      expect(File).to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
      expect(File.read(claude_md)).to eq(kept)
      expect(claude_md_state).to eq("removed-by-user")
    end
  end

  describe "a guideline the user removed from index.md" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:index_path) { File.join(app_dir, ".claude/hyperdrive/index.md") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      expect(File.read(index_path).lines.map(&:chomp))
        .to contain_exactly("@guidelines/alpha-guide.md", "@guidelines/alpha-stack-guide.md")
    end

    it "stays out across a sync and a bundle install, and an index that renders empty is kept" do
      File.write(index_path, "@guidelines/alpha-guide.md\n")

      out, status = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status.success?).to be(true), out
      expect(File.read(index_path)).to eq("@guidelines/alpha-guide.md\n")
      expect(out).to match(/1 guideline\(s\), ~[1-9]\d* tokens always in context/)
      # The opt-out is index.md's alone; the guideline itself stays installed.
      expect(File).to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-stack-guide.md"))

      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
      hook_out = Smoke.bundle_install!(app_dir)
      expect(hook_out).to include("[hyperdrive] installed")
      expect(File.read(index_path).lines.map(&:chomp))
        .to contain_exactly("@guidelines/alpha-guide.md", "@guidelines/beta-guide.md")

      File.write(index_path, "")
      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(File.exist?(index_path)).to be(true), "an index.md that renders empty was torn down:\n#{out2}"
      expect(File.read(index_path)).to eq("")
      expect(File.read(File.join(app_dir, "CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")
    end
  end

  describe "a lock still carrying disabled:/enabled:" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }
    let(:warning) do
      ".hyperdrive/lock.yml carries disabled:/enabled:; those settings now live in .hyperdrive/config.yml"
    end

    def add_legacy_settings!
      lock = YAML.safe_load(File.read(lock_path))
      lock["disabled"] = { "skills" => ["alpha-skill"] }
      lock["enabled"] = ["plain-skills-gem"]
      File.write(lock_path, lock.to_yaml)
    end

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
    end

    it "warns once per run, drops the keys on write, and warns again from the bundler hook" do
      add_legacy_settings!

      out, status = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status.success?).to be(true), out
      expect(out.scan(warning).length).to eq(1)
      lock = YAML.safe_load(File.read(lock_path))
      expect(lock).not_to have_key("disabled")
      expect(lock).not_to have_key("enabled")
      # The keys were never read, so the skill they named is still installed.
      expect(File).to exist(File.join(app_dir, ".claude/skills/alpha-skill/SKILL.md"))

      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).not_to include(warning)

      add_legacy_settings!
      out3, status3 = Smoke.run_hyperdrive_init!(app_dir)
      expect(status3.success?).to be(true), out3
      expect(out3.scan(warning).length).to eq(1)

      add_legacy_settings!
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
      hook_out = Smoke.bundle_install!(app_dir)
      expect(hook_out).to include("[hyperdrive] #{warning}")
    end
  end

  describe "a lock written by a newer installer" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:lock_path) { File.join(app_dir, ".hyperdrive/lock.yml") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }
    let(:message) do
      ".hyperdrive/lock.yml was written by a newer rails-hyperdrive (lock schema 99, " \
        "this installer supports #{Rails::Hyperdrive::LockFile::SCHEMA_VERSION}); upgrade rails-hyperdrive"
    end

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      FileUtils.rm(guide_path)
      File.write(lock_path, File.read(lock_path).sub(/^version: \d+$/, "version: 99"))
    end

    # A generator's Thor::Error prints and stops the run, but bin/rails still
    # exits 0, so the halt shows up as output plus the absence of any write.
    it "runs init's lock-independent bootstrap steps and writes no content" do
      FileUtils.rm(File.join(app_dir, ".mcp.json"))
      frozen = File.binread(lock_path)

      out, = Smoke.run_hyperdrive_init!(app_dir)

      expect(out).to include(message)
      expect(File.exist?(File.join(app_dir, ".mcp.json"))).to be(true),
        "init halted before its bootstrap steps:\n#{out}"
      expect(File.exist?(guide_path)).to be(false), "init wrote content past the halt:\n#{out}"
      expect(File.binread(lock_path)).to eq(frozen), "init rewrote the lock:\n#{out}"
    end

    it "halts the bundler hook without failing bundle install" do
      frozen = File.binread(lock_path)

      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
      out = Smoke.bundle_install!(app_dir)

      expect(out).to include("[hyperdrive] #{message}")
      expect(File.exist?(guide_path)).to be(false), "the hook wrote content past the halt:\n#{out}"
      expect(File).not_to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
      expect(File.binread(lock_path)).to eq(frozen), "the hook rewrote the lock:\n#{out}"
    end
  end

  describe "hyperdrive:sync --dry-run with a pending sidecar" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:alpha_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-alpha") }
    let(:shipped_guide) do
      File.join(alpha_dir, "lib/rails-hyperdrive-alpha/hyperdrive/guidelines/alpha-guide.md")
    end
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }

    before do
      Smoke.add_path_gem!(app_dir)
      alpha_dir
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

      File.write(guide_path, File.read(guide_path) + "\n<!-- LOCAL EDIT -->\n")
      File.write(shipped_guide, File.read(shipped_guide) + "\nUpstream v2 addition.\n")
      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir, "--sidecar")
      expect(status2.success?).to be(true), out2
      expect(File.exist?("#{guide_path}.new")).to be(true), out2

      # A third upstream, so both dry runs have a delivery left to report.
      File.write(shipped_guide, File.read(shipped_guide) + "\nUpstream v3 addition.\n")
    end

    def managed_digests
      paths = Dir.glob(File.join(app_dir, "{.claude,.hyperdrive}/**/*")).select { |p| File.file?(p) }
      (paths + [File.join(app_dir, "CLAUDE.md")]).sort.to_h do |path|
        [path.sub("#{app_dir}/", ""), Digest::SHA256.hexdigest(File.binread(path))]
      end
    end

    it "prints the would-be delivery in both reconcile modes and writes nothing" do
      untouched = managed_digests
      expect(untouched.keys).to include(
        ".claude/hyperdrive/guidelines/alpha-guide.md",
        ".claude/hyperdrive/guidelines/alpha-guide.md.new",
        ".claude/hyperdrive/index.md",
        ".hyperdrive/lock.yml",
        "CLAUDE.md"
      )

      %w[--sidecar --merge].each do |mode|
        out, status = Smoke.run_hyperdrive_sync!(app_dir, "--dry-run", mode)
        expect(status.success?).to be(true), out
        expect(out).to match(%r{sidecar.*alpha-guide\.md.*new upstream delivered to}),
          "sync --dry-run #{mode} printed no would-be delivery:\n#{out}"
        expect(managed_digests).to eq(untouched), "sync --dry-run #{mode} wrote to disk:\n#{out}"
      end
    end
  end

  describe "a manifest gate carrying a member-level version requirement" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }
    let(:beta_dir) { Smoke.vendor_companion!(app_dir, "rails-hyperdrive-beta") }
    let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md") }

    def require_railties(requirement)
      path = File.join(beta_dir, "hyperdrive.yml")
      manifest = YAML.safe_load(File.read(path))
      manifest["gems"] = [{ "railties" => requirement }]
      File.write(path, manifest.to_yaml)
    end

    before do
      Smoke.add_path_gem!(app_dir)
      beta_dir
      Smoke.bundle_install!(app_dir)
    end

    it "installs against a satisfied requirement and skips with the resolved version against an unsatisfied one" do
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
      expect(File.exist?(guide_path)).to be(true), "the shipped railties >= 7.0 gate did not install:\n#{out}"

      require_railties(">= 99")
      out2, status2 = Smoke.run_hyperdrive_sync!(app_dir)
      expect(status2.success?).to be(true), out2
      expect(out2).to match(
        %r{skip beta-guide \(from rails-hyperdrive-beta\): railties [\d.]+ does not satisfy '>= 99'}
      )
      expect(out2).to match(%r{skip shared-skill \(from rails-hyperdrive-beta\): railties [\d.]+ does not satisfy})
      # A gate that simply does not match is not a broken companion, so the
      # stale destination still converges.
      expect(File.exist?(guide_path)).to be(false), "a newly gated-out artifact was left behind:\n#{out2}"
    end
  end
end
