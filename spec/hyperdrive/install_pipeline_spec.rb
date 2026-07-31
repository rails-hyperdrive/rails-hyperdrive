require "spec_helper"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::InstallPipeline do
  Artifact = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact unless defined?(Artifact)

  let(:root) { Dir.mktmpdir("hyperdrive-pipeline") }
  let(:stack) { { rails: { version: "8.0.0", major: 8 }, ruby: { version: "3.3.0" }, database: { adapter: "sqlite3" } } }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def guideline(name:, source: "rails-hyperdrive-x", body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  def skill(name:, source: "rails-hyperdrive-x")
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n",
      spec_version: "1.0.0"
    )
  end

  def run(mode: :init, artifacts: [])
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root),
      artifacts: artifacts,
      stack: stack,
      mode: mode
    ).call
  end

  def read(rel) = File.read(File.join(root, rel))
  def exist?(rel) = File.exist?(File.join(root, rel))

  describe "running without a booted Rails application" do
    before { allow(::Rails).to receive(:root).and_return(nil) }

    it "installs a full content set into the given root" do
      run(artifacts: [guideline(name: "auth-pundit"), skill(name: "jobs-sidekiq")])

      expect(exist?(".claude/hyperdrive/stack.md")).to be true
      expect(exist?(".claude/skills/jobs-sidekiq/SKILL.md")).to be true
      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to start_with("<!-- hyperdrive: source=rails-hyperdrive-x@1.0.0")
      expect(read(".claude/hyperdrive/index.md")).to include("@guidelines/auth-pundit.md")
      expect(read("CLAUDE.md")).to include("@.claude/hyperdrive/index.md")
      expect(read(".hyperdrive/lock.yml")).to include("artifact: guideline")
    end

    it "reports what it wrote" do
      result = run(artifacts: [guideline(name: "auth-pundit")])
      expect(result.installed).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(result.installed).to include(".claude/hyperdrive/stack.md")
    end
  end

  describe "additive mode" do
    let(:existing) { guideline(name: "auth-pundit") }

    before { run(artifacts: [existing]) }

    it "installs an artifact the lockfile does not record yet" do
      result = run(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      expect(exist?(".claude/hyperdrive/guidelines/jobs-sidekiq.md")).to be true
      expect(result.installed).to eq([".claude/hyperdrive/guidelines/jobs-sidekiq.md"])
    end

    it "adds the new guideline to index.md so it is actually loaded" do
      run(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      index = read(".claude/hyperdrive/index.md")
      expect(index).to include("@guidelines/jobs-sidekiq.md")
      expect(index).to include("@guidelines/auth-pundit.md")
      expect(index.lines.first.strip).to eq("@stack.md")
    end

    it "leaves a locally-edited file alone" do
      path = ".claude/hyperdrive/guidelines/auth-pundit.md"
      File.write(File.join(root, path), read(path) + "\nMY LOCAL EDIT\n")

      result = run(mode: :additive, artifacts: [existing])

      expect(read(path)).to include("MY LOCAL EDIT")
      expect(result.installed).to be_empty
    end

    it "leaves an upgraded artifact alone rather than overwriting it" do
      upgraded = guideline(
        name: "auth-pundit",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# auth-pundit\n\nUPGRADED.\n"
      )

      result = run(mode: :additive, artifacts: [upgraded])

      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to include("rule.")
      expect(result.installed).to be_empty
      expect(result.skipped).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
    end

    it "does not resurrect a tracked file the user deleted" do
      path = ".claude/hyperdrive/guidelines/auth-pundit.md"
      File.delete(File.join(root, path))

      run(mode: :additive, artifacts: [existing])

      expect(exist?(path)).to be false
    end

    it "does not re-add an index.md line the user removed" do
      File.write(File.join(root, ".claude/hyperdrive/index.md"), "@stack.md\n")

      run(mode: :additive, artifacts: [existing])

      expect(read(".claude/hyperdrive/index.md")).not_to include("@guidelines/auth-pundit.md")
    end

    it "does not touch CLAUDE.md" do
      File.write(File.join(root, "CLAUDE.md"), "# mine only\n")

      run(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      expect(read("CLAUDE.md")).to eq("# mine only\n")
    end

    it "keeps carrying entries whose source gem left the bundle" do
      run(mode: :additive, artifacts: [])

      expect(exist?(".claude/hyperdrive/guidelines/auth-pundit.md")).to be true
      expect(read(".hyperdrive/lock.yml")).to include("auth-pundit")
    end
  end

  describe "gitignored install destination" do
    def run_reporting(mode: :init, artifacts: [])
      io = StringIO.new
      described_class.new(
        root: root,
        shell: Rails::Hyperdrive::InstallShell.new(root: root, io: io),
        artifacts: artifacts,
        stack: stack,
        mode: mode
      ).call
      io.string
    end

    before { system("git", "init", "--quiet", root, out: File::NULL, err: File::NULL) }

    it "warns when the destinations are ignored" do
      File.write(File.join(root, ".gitignore"), ".claude/\n")

      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to include(".claude/skills", ".claude/hyperdrive")
      expect(out).to match(/gitignored/)
      expect(out).to match(/unreviewed/)
    end

    it "stays quiet when they are tracked" do
      expect(run_reporting(artifacts: [guideline(name: "auth-pundit")])).not_to match(/gitignored/)
    end

    it "stays quiet in additive mode" do
      File.write(File.join(root, ".gitignore"), ".claude/\n")
      run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(run_reporting(mode: :additive, artifacts: [])).not_to match(/gitignored/)
    end
  end

  it "rejects an unknown mode" do
    expect {
      described_class.new(root: root, shell: nil, artifacts: [], stack: stack, mode: :clobber)
    }.to raise_error(ArgumentError, /clobber/)
  end
end
