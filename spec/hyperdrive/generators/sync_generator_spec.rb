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

  def guideline_artifact(name:, source:, body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  def skill_artifact(name:, source:, support_files: [], version: "1.0.0")
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# #{name}\n",
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
      expect(File).not_to exist(path("config/initializers/hyperdrive.rb"))
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

    it "skips a locally-edited file by default, warns, and preserves the edit" do
      run_generator([])
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")
      out = run_generator([])
      expect(out).to include("locally modified; run hyperdrive:sync --overwrite to overwrite")
      expect(File.read(gpath)).to include("MY LOCAL EDIT")
    end

    it "restores the gem-shipped body with --overwrite (edit gone, header + lock restored)" do
      run_generator([])
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")

      run_generator(["--overwrite"])
      restored = File.read(gpath)
      expect(restored).not_to include("MY LOCAL EDIT")
      expect(restored).to start_with("<!-- hyperdrive: source=rails-hyperdrive-pundit@1.0.0 -->")

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
