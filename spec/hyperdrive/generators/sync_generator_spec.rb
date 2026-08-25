require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "generators/hyperdrive/sync/sync_generator"
require "rails/hyperdrive/bundler_artifact_discovery"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Generators::Hyperdrive::SyncGenerator do
  include Rails::Generators::Testing::Behavior
  include FileUtils

  destination File.expand_path("../../tmp/sync_generator", __dir__)
  tests described_class

  Artifact = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact unless defined?(Artifact)

  def stub_rails_root(path)
    allow(::Rails).to receive(:root).and_return(Pathname.new(path))
  end

  def stub_discovery(artifacts)
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery)
      .to receive(:discover).and_return(artifacts)
  end

  def guideline_artifact(name:, source:, body: nil, version: "1.0.0", source_root: nil, path: nil)
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :guideline, source_gem: source, path: path || "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: version, source_root: source_root
    )
  end

  def skill_artifact(name:, source:, support_files: [], version: "1.0.0", body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# #{name}\n",
      spec_version: version, support_files: support_files
    )
  end

  before do
    prepare_destination
    @app_dir = destination_root
    # spec/tmp/ is gitignored by this repo, so without its own repository the
    # destination inherits that ignore and every run trips the gitignore warning.
    system("git", "init", "--quiet", @app_dir, out: File::NULL, err: File::NULL)
    FileUtils.mkdir_p(File.join(@app_dir, "config"))
    File.write(File.join(@app_dir, "config", "routes.rb"), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(@app_dir, "Gemfile.lock"), File.read(File.expand_path("../../fixtures/gemfile_lock/standard.lock", __dir__)))
    stub_rails_root(@app_dir)
    stub_discovery([])
  end

  def path(rel) = File.join(@app_dir, rel)

  describe "content-only surface" do
    it "installs full content on a fresh app with no prior init and no lock" do
      stub_discovery([guideline_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])
      expect(File).to exist(path(".claude/hyperdrive/guidelines/jobs-sidekiq.md"))
      expect(File.read(path(".claude/hyperdrive/index.md"))).to include("@guidelines/jobs-sidekiq.md")
      expect(File).to exist(path(".hyperdrive/lock.yml"))
      expect(File.read(path("CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")
    end

    it "writes no bootstrap artifact" do
      run_generator([])
      expect(File).not_to exist(path(".mcp.json"))
      expect(File).not_to exist(path(".gitignore"))
      expect(File.read(path("config/routes.rb"))).not_to include("Rails::Hyperdrive::Engine")
    end

    it "leaves an existing .mcp.json and config/routes.rb byte-identical" do
      mcp = %({"mcpServers":{"my-other-server":{"command":"npx"}}}\n)
      routes = "Rails.application.routes.draw do\n  root \"home#index\"\nend\n"
      File.write(path(".mcp.json"), mcp)
      File.write(path("config/routes.rb"), routes)

      run_generator([])
      expect(File.read(path(".mcp.json"))).to eq(mcp)
      expect(File.read(path("config/routes.rb"))).to eq(routes)
    end
  end

  describe "drift handling" do
    before { stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")]) }

    let(:gpath) { path(".claude/hyperdrive/guidelines/auth-pundit.md") }

    it "skips a locally-edited file by default, warning with every reconcile flag, and preserves the edit" do
      run_generator([])
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")
      out = run_generator([])
      expect(out).to include("locally modified; run hyperdrive:sync with --merge, --sidecar, or --overwrite to reconcile")
      expect(File.read(gpath)).to include("MY LOCAL EDIT")
    end

    it "restores the gem-shipped body with --overwrite (edit gone, lock restored)" do
      run_generator([])
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")

      run_generator(["--overwrite"])
      restored = File.read(gpath)
      expect(restored).not_to include("MY LOCAL EDIT")
      expect(restored).to start_with("# auth-pundit")

      # Re-locked: a following plain sync sees the file as current again.
      out = run_generator([])
      expect(out).to match(%r{unchanged.*auth-pundit\.md})
      expect(File.read(gpath)).to eq(restored)
    end

    it "rewrites an upgraded-unedited file without any flag" do
      run_generator([])
      expect(File.read(gpath)).to include("rule.")

      upgraded = "---\nname: auth-pundit\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# auth-pundit\n\nUPGRADED rule.\n"
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit", body: upgraded)])
      run_generator([])
      expect(File.read(gpath)).to include("UPGRADED rule.")
    end

    it "reinstalls a deleted managed file" do
      run_generator([])
      File.delete(gpath)
      out = run_generator([])
      expect(out).to include("was missing")
      expect(File.read(gpath)).to include("# auth-pundit")
    end
  end

  describe "drift handling for a skill's supporting files" do
    let(:spath) { path(".claude/skills/jobs-sidekiq/references/deep.md") }

    before do
      stub_discovery([skill_artifact(
        name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq",
        support_files: [{ path: "references/deep.md", body: "# Deep\n" }]
      )])
    end

    it "skips a locally-edited supporting file by default and restores it with --overwrite" do
      run_generator([])
      File.write(spath, "my rewrite\n")

      out = run_generator([])
      expect(out).to include("locally modified")
      expect(File.read(spath)).to eq("my rewrite\n")

      run_generator(["--overwrite"])
      expect(File.read(spath)).to eq("# Deep\n")
    end

    it "reinstalls a deleted supporting file" do
      run_generator([])
      File.delete(spath)

      out = run_generator([])
      expect(out).to include("was missing")
      expect(File.read(spath)).to eq("# Deep\n")
    end

    it "keeps the summary count when an edited SKILL.md lags the supporting files' source version" do
      run_generator([])
      File.write(path(".claude/skills/jobs-sidekiq/SKILL.md"), "my rewrite\n")

      stub_discovery([skill_artifact(
        name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq", version: "1.1.0",
        support_files: [{ path: "references/deep.md", body: "# Deep v2\n" }]
      )])

      out = run_generator([])
      expect(out).to match(/skill\s+jobs-sidekiq \(\+1 file\)/)
    end
  end

  describe "a supporting file the bundle stops offering" do
    let(:spath) { path(".claude/skills/jobs-sidekiq/references/gated.md") }

    it "removes the unedited file and its lock entry while the skill stays installed" do
      stub_discovery([skill_artifact(
        name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq",
        support_files: [{ path: "references/gated.md", body: "# Gated\n" }]
      )])
      run_generator([])
      expect(File.read(spath)).to eq("# Gated\n")

      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])

      expect(File.exist?(spath)).to be(false)
      expect(File).to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
      lock = YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))
      expect(lock["files"].map { |f| f["path"] })
        .not_to include(".claude/skills/jobs-sidekiq/references/gated.md")
    end
  end

  describe "--dry-run" do
    it "writes nothing" do
      run_generator(["--dry-run"])
      expect(File).not_to exist(path(".claude/hyperdrive/index.md"))
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
      expect(File).not_to exist(path("CLAUDE.md"))
    end

    it "announces a destination the plan no longer claims once, and leaves it on disk" do
      shipped = [skill_artifact(name: "jobs", source: "rails-hyperdrive-sidekiq")]
      allow(Rails::Hyperdrive::BundlerArtifactDiscovery).to receive(:discover) do |bundled_gems: [], **_|
        bundled_gems << "rails-hyperdrive-sidekiq"
        shipped
      end
      run_generator([])
      shipped = [skill_artifact(name: "tasks", source: "rails-hyperdrive-sidekiq")]

      out = run_generator(["--dry-run"])

      expect(File).to exist(path(".claude/skills/jobs/SKILL.md"))
      expect(out.scan(".claude/skills/jobs/SKILL.md").size).to eq(1)
    end
  end

  describe "a lock written by a newer installer" do
    before do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      run_generator([])
      lock = YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))
      lock["version"] = 3
      File.write(path(".hyperdrive/lock.yml"), lock.to_yaml)
    end

    ["", "--dry-run"].each do |flag|
      it "refuses to sync#{flag.empty? ? "" : " under #{flag}"}, naming the remedy, and leaves the lock byte-identical" do
        before_lock = File.read(path(".hyperdrive/lock.yml"))

        err = capture(:stderr) { run_generator([flag].reject(&:empty?)) }

        expect(err).to include(".hyperdrive/lock.yml was written by a newer rails-hyperdrive")
          .and include("lock schema 3, this installer supports 2")
          .and include("upgrade rails-hyperdrive")
        expect(File.read(path(".hyperdrive/lock.yml"))).to eq(before_lock)
      end
    end
  end

  describe "reconcile flag exclusivity" do
    [%w[--merge --overwrite], %w[--merge --sidecar], %w[--sidecar --overwrite],
     %w[--merge --sidecar --overwrite]].each do |flags|
      it "refuses #{flags.join(" ")} before any step runs" do
        stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
        err = capture(:stderr) { run_generator(flags) }
        expect(err).to include("mutually exclusive")
        expect(File).not_to exist(path(".hyperdrive/lock.yml"))
      end
    end
  end

  describe "--sidecar" do
    let(:gpath) { path(".claude/hyperdrive/guidelines/auth-pundit.md") }
    let(:spath) { path(".claude/skills/jobs-sidekiq/SKILL.md") }
    let(:refpath) { path(".claude/skills/jobs-sidekiq/references/deep.md") }

    def v1_artifacts
      [
        guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit"),
        skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq",
          support_files: [{ path: "references/deep.md", body: "# Deep v1\n" }])
      ]
    end

    def v2_artifacts
      [
        guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit", version: "2.0.0",
          body: "---\nname: auth-pundit\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# auth-pundit\n\nv2 rule.\n"),
        skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq", version: "2.0.0",
          body: "---\nname: jobs-sidekiq\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# jobs-sidekiq v2\n",
          support_files: [{ path: "references/deep.md", body: "# Deep v2\n" }])
      ]
    end

    before do
      stub_discovery(v1_artifacts)
      run_generator([])
      File.write(gpath, File.read(gpath) + "\nMY GUIDE EDIT\n")
      File.write(spath, File.read(spath) + "\nMY SKILL EDIT\n")
      File.write(refpath, "MY REF REWRITE\n")
      stub_discovery(v2_artifacts)
    end

    it "delivers sidecars for a guideline, a skill, and a supporting file, leaving all live files untouched" do
      out = run_generator(["--sidecar"])

      expect(out).to match(/sidecar.*auth-pundit\.md.*delivered to/)
      expect(File.read(gpath)).to include("MY GUIDE EDIT")
      expect(File.read(spath)).to include("MY SKILL EDIT")
      expect(File.read(refpath)).to eq("MY REF REWRITE\n")

      expect(File.read("#{gpath}.new")).to start_with("# auth-pundit")
      expect(File.read("#{gpath}.new")).to include("v2 rule.")
      expect(File.read("#{spath}.new")).to include("name: jobs-sidekiq")
      expect(File.read("#{spath}.new")).to include("# jobs-sidekiq v2")
      expect(File.read("#{refpath}.new")).to eq("# Deep v2\n")

      lock = YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))
      sources = lock["files"].to_h { |f| [f["path"], f["source"]] }
      expect(sources[".claude/hyperdrive/guidelines/auth-pundit.md"]).to eq("rails-hyperdrive-pundit@2.0.0")
      expect(sources[".claude/skills/jobs-sidekiq/SKILL.md"]).to eq("rails-hyperdrive-sidekiq@2.0.0")
      expect(sources[".claude/skills/jobs-sidekiq/references/deep.md"]).to eq("rails-hyperdrive-sidekiq@2.0.0")
      expect(lock["files"].map { |f| f["path"] }.grep(/\.new\z/)).to be_empty
    end

    it "mv .new over the live file accepts the upstream; the next plain sync reads it current" do
      run_generator(["--sidecar"])
      mv("#{gpath}.new", gpath)

      out = run_generator([])

      expect(out).to match(%r{unchanged.*auth-pundit\.md})
      expect(File.read(gpath)).to include("v2 rule.")
      expect(File).not_to exist("#{gpath}.new")
    end

    it "does not re-offer the delivered upstream on a second --sidecar run" do
      run_generator(["--sidecar"])
      out = run_generator(["--sidecar"])

      expect(out).to include("unresolved sidecar")
      expect(File.read("#{gpath}.new")).to include("v2 rule.")
    end

    it "writes nothing under --dry-run" do
      run_generator(["--sidecar", "--dry-run"])

      expect(File).not_to exist("#{gpath}.new")
      expect(File).not_to exist("#{spath}.new")
      lock = YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))
      sources = lock["files"].to_h { |f| [f["path"], f["source"]] }
      expect(sources[".claude/hyperdrive/guidelines/auth-pundit.md"]).to eq("rails-hyperdrive-pundit@1.0.0")
    end
  end

  describe "--merge" do
    let(:gpath) { path(".claude/hyperdrive/guidelines/auth-pundit.md") }
    let(:gem_home) { File.join(@app_dir, "fake-gem-home") }
    let(:relpath) { "lib/rails-hyperdrive-pundit/hyperdrive/guidelines/auth-pundit.md" }
    let(:v1_shipped) do
      "---\nname: auth-pundit\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n" \
        "# auth-pundit\n\nline a\nline b\nline c\nline d\n"
    end

    def v2_artifact(upstream_change: "line d (upstream)")
      current_root = File.join(@app_dir, "current-gem")
      guideline_artifact(
        name: "auth-pundit", source: "rails-hyperdrive-pundit", version: "2.0.0",
        body: v1_shipped.sub("line d", upstream_change),
        source_root: current_root, path: File.join(current_root, relpath)
      )
    end

    def ship_v1_ancestor!
      file = File.join(gem_home, "gems", "rails-hyperdrive-pundit-1.0.0", relpath)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, v1_shipped)
    end

    before do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit", body: v1_shipped)])
      run_generator([])
      File.write(gpath, File.read(gpath).sub("line a", "line a (mine)"))
      allow(Gem).to receive(:path).and_return([gem_home])
    end

    it "cleanly merges non-overlapping local and upstream edits into the live file and re-locks" do
      ship_v1_ancestor!
      stub_discovery([v2_artifact])

      out = run_generator(["--merge"])

      expect(out).to match(/merged.*auth-pundit\.md/)
      live = File.read(gpath)
      expect(live).to start_with("# auth-pundit")
      expect(live).to include("line a (mine)")
      expect(live).to include("line d (upstream)")
      expect(live).not_to include("<<<<<<<")
      expect(File).not_to exist("#{gpath}.new")
      lock = YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))
      entry = lock["files"].find { |f| f["path"] == ".claude/hyperdrive/guidelines/auth-pundit.md" }
      expect(entry["source"]).to eq("rails-hyperdrive-pundit@2.0.0")

      # The merged file truthfully reads edited, but the delivered upstream is
      # never re-offered.
      out2 = run_generator([])
      expect(out2).to include("locally modified")
      expect(File.read(gpath)).to eq(live)
    end

    it "degrades to a sidecar when the ancestor is not in any installed gem" do
      stub_discovery([v2_artifact])

      out = run_generator(["--merge"])

      expect(out).to match(/sidecar.*not found in installed gems/)
      expect(File.read(gpath)).to include("line a (mine)")
      expect(File.read(gpath)).not_to include("line d (upstream)")
      expect(File.read("#{gpath}.new")).to include("line d (upstream)")
    end

    it "degrades to a sidecar on conflicting edits" do
      ship_v1_ancestor!
      stub_discovery([guideline_artifact(
        name: "auth-pundit", source: "rails-hyperdrive-pundit", version: "2.0.0",
        body: v1_shipped.sub("line a", "line a (upstream)"),
        source_root: File.join(@app_dir, "current-gem"),
        path: File.join(@app_dir, "current-gem", relpath)
      )])

      out = run_generator(["--merge"])

      expect(out).to match(/sidecar.*conflicting edits/)
      expect(File.read(gpath)).to include("line a (mine)")
      expect(File.read(gpath)).not_to include("<<<<<<<")
      expect(File.read("#{gpath}.new")).to include("line a (upstream)")
    end

    it "degrades to a sidecar when git is unavailable" do
      ship_v1_ancestor!
      stub_discovery([v2_artifact])
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "git")

      out = run_generator(["--merge"])

      expect(out).to match(/sidecar.*git merge-file unavailable/)
      expect(File.read("#{gpath}.new")).to include("line d (upstream)")
    end

    it "writes nothing under --dry-run" do
      ship_v1_ancestor!
      stub_discovery([v2_artifact])
      before_live = File.read(gpath)

      run_generator(["--merge", "--dry-run"])

      expect(File.read(gpath)).to eq(before_live)
      expect(File).not_to exist("#{gpath}.new")
    end
  end

  describe "summary" do
    it "prints 'hyperdrive synced' and the source-grouped listing, without init's bootstrap lines" do
      stub_discovery([
        skill_artifact(name: "sidekiq-idempotency", source: "rails-hyperdrive-sidekiq"),
        guideline_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")
      ])
      out = run_generator([])

      expect(out).to include("hyperdrive synced")
      expect(out).to include("Installed 1 skill, 1 guideline")
      expect(out).to match(
        /rails-hyperdrive-sidekiq@1\.0\.0\n\s+skill\s+sidekiq-idempotency\n\s+guideline\s+jobs-sidekiq/
      )
      expect(out).not_to include("Mount:")
      expect(out).not_to include("Next steps")
    end
  end

  describe "environment guard" do
    it "refuses to run outside Rails.env.development?" do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      capture(:stderr) { run_generator([]) }
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
    end

    it "refuses to run when not inside a Rails app" do
      allow(::Rails).to receive(:root).and_return(nil)
      capture(:stderr) { run_generator([]) }
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
    end
  end
end
