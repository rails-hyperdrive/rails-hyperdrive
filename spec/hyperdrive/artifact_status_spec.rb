require "spec_helper"
require "rails/hyperdrive/artifact_status"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::ArtifactStatus do
  let(:root) { Dir.mktmpdir("hyperdrive-status") }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def guideline(name:, source: "rails-hyperdrive-x", body: nil)
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  def install(artifacts)
    Rails::Hyperdrive::InstallPipeline.new(
      root: root, shell: Rails::Hyperdrive::InstallShell.new(root: root),
      artifacts: artifacts, mode: :preserve
    ).call
  end

  def compare(artifacts, bundled_gems: [])
    described_class.compare(root: root, artifacts: artifacts, bundled_gems: bundled_gems)
  end

  it "reports everything as missing before anything is installed" do
    status = compare([guideline(name: "auth-pundit")])

    expect(status.missing.map(&:path)).to eq([".claude/hyperdrive/guidelines/auth-pundit.md"])
    expect(status).to be_stale
  end

  context "with a fully installed application" do
    let(:artifacts) { [guideline(name: "auth-pundit")] }

    before { install(artifacts) }

    it "reports nothing stale" do
      status = compare(artifacts)

      expect(status.installed.map(&:path)).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(status).not_to be_stale
    end

    it "reports a newly bundled companion as missing" do
      status = compare(artifacts + [guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      expect(status.missing.map(&:path)).to eq([".claude/hyperdrive/guidelines/jobs-sidekiq.md"])
    end

    it "reports changed content as outdated, naming both sources" do
      upgraded = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
        **guideline(name: "auth-pundit").to_h,
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# auth-pundit\n\nUPGRADED.\n",
        spec_version: "2.0.0"
      )

      entry = compare([upgraded]).outdated.first

      expect(entry.path).to eq(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(entry.locked_source).to eq("rails-hyperdrive-x@1.0.0")
      expect(entry.bundle_source).to eq("rails-hyperdrive-x@2.0.0")
    end

    it "reports an artifact no gem ships any more as orphaned" do
      status = compare([])

      expect(status.orphaned.map(&:path)).to eq([".claude/hyperdrive/guidelines/auth-pundit.md"])
      expect(status.orphaned.first.locked_source).to eq("rails-hyperdrive-x@1.0.0")
      expect(status.orphaned.first.to_s).to include("no longer shipped by rails-hyperdrive-x@1.0.0")
    end

    it "never says an artifact is no longer shipped while its source gem is bundled" do
      entry = compare([], bundled_gems: ["rails-hyperdrive-x"]).orphaned.first

      expect(entry.to_s).to eq(
        ".claude/hyperdrive/guidelines/auth-pundit.md (rails-hyperdrive-x is still bundled but did not offer this file)"
      )
    end

    it "judges the lockfile, not the disk" do
      FileUtils.rm_rf(File.join(root, ".claude"))

      expect(compare(artifacts)).not_to be_stale
    end
  end

  describe "a skill's supporting files" do
    def multi_skill(support_files:)
      Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
        name: "jobs", description: "d", target_gem: "*", versions: "*",
        artifact_type: :skill, source_gem: "rails-hyperdrive-x", path: "/x/jobs/SKILL.md",
        body: "---\nname: jobs\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# jobs\n",
        spec_version: "1.0.0", support_files: support_files
      )
    end

    let(:support) { [{ path: "references/deep.md", body: "deep\n" }] }

    it "reports a supporting file the lock does not record as missing" do
      install([multi_skill(support_files: [])])

      status = compare([multi_skill(support_files: support)])

      expect(status.missing.map(&:path)).to eq([".claude/skills/jobs/references/deep.md"])
      expect(status.missing.first.artifact).to eq(:skill_support)
    end

    it "reports an installed supporting file as current" do
      install([multi_skill(support_files: support)])

      expect(compare([multi_skill(support_files: support)])).not_to be_stale
    end

    it "reports changed supporting content as outdated" do
      install([multi_skill(support_files: support)])

      status = compare([multi_skill(support_files: [{ path: "references/deep.md", body: "deeper\n" }])])

      expect(status.outdated.map(&:path)).to eq([".claude/skills/jobs/references/deep.md"])
    end
  end

  describe "agents and commands" do
    def agent(name:, source: "rails-hyperdrive-x", body: nil)
      Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
        name: name, description: "d", target_gem: "*", versions: "*",
        artifact_type: :agent, source_gem: source, path: "/x/agents/#{name}.md",
        body: body || "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n", spec_version: "1.0.0"
      )
    end

    def command(name:, source: "rails-hyperdrive-x", body: nil)
      Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
        name: name, description: nil, target_gem: "*", versions: "*",
        artifact_type: :command, source_gem: source, path: "/x/commands/#{name}.md",
        body: body || "# #{name}\n", spec_version: "1.0.0"
      )
    end

    it "runs them through the same four states as guidelines" do
      artifacts = [agent(name: "reviewer"), command(name: "analyze")]
      expect(compare(artifacts).missing.map(&:path))
        .to contain_exactly(".claude/agents/reviewer.md", ".claude/commands/analyze.md")

      install(artifacts)
      expect(compare(artifacts)).not_to be_stale
      expect(compare(artifacts).installed.map(&:artifact)).to contain_exactly(:agent, :command)

      status = compare([agent(name: "reviewer"), command(name: "analyze", body: "# v2\n")])
      expect(status.outdated.map(&:path)).to eq([".claude/commands/analyze.md"])

      expect(compare([]).orphaned.map(&:artifact)).to contain_exactly(:agent, :command)
    end

    it "offers no supporting-file entries" do
      install([agent(name: "reviewer")])

      expect(compare([agent(name: "reviewer")]).entries.map(&:artifact)).to eq([:agent])
    end

    it "is not reported as missing while disabled" do
      lock_path = File.join(root, Rails::Hyperdrive::InstallLayout::LOCK_PATH)
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, { "disabled" => { "commands" => ["analyze"] } }.to_yaml)

      expect(compare([command(name: "analyze")]).missing).to be_empty
    end
  end

  describe "a disabled artifact" do
    def disable(*names)
      lock_path = File.join(root, Rails::Hyperdrive::InstallLayout::LOCK_PATH)
      FileUtils.mkdir_p(File.dirname(lock_path))
      data = File.exist?(lock_path) ? YAML.safe_load(File.read(lock_path)) : {}
      (data["disabled"] ||= {})["guidelines"] = names
      File.write(lock_path, data.to_yaml)
    end

    it "is not reported as missing" do
      disable("auth-pundit")

      status = compare([guideline(name: "auth-pundit")])

      expect(status.missing).to be_empty
    end

    it "left on disk is not reported as orphaned" do
      artifacts = [guideline(name: "auth-pundit")]
      install(artifacts)
      disable("auth-pundit")

      expect(compare(artifacts).orphaned).to be_empty
    end
  end
end
