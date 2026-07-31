require "spec_helper"
require "rails/hyperdrive/artifact_status"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::ArtifactStatus do
  let(:root) { Dir.mktmpdir("hyperdrive-status") }
  let(:stack) { { rails: { version: "8.0.0", major: 8 }, ruby: { version: "3.3.0" }, database: { adapter: "sqlite3" } } }

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
      artifacts: artifacts, stack: stack, mode: :init
    ).call
  end

  def compare(artifacts)
    described_class.compare(root: root, artifacts: artifacts, stack: stack)
  end

  it "reports everything as missing before anything is installed" do
    status = compare([guideline(name: "auth-pundit")])

    expect(status.missing.map(&:path)).to contain_exactly(
      ".claude/hyperdrive/guidelines/auth-pundit.md",
      ".claude/hyperdrive/stack.md"
    )
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
    end

    it "judges the lockfile, not the disk" do
      FileUtils.rm_rf(File.join(root, ".claude"))

      expect(compare(artifacts)).not_to be_stale
    end
  end
end
