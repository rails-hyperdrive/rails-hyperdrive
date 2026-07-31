require "spec_helper"
require "generators/hyperdrive/sync_runner"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe Rails::Generators::Hyperdrive::SyncRunner do
  Artifact = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact unless defined?(Artifact)

  let(:root) { Dir.mktmpdir("hyperdrive-runner") }
  let(:io) { StringIO.new }
  let(:shell) { Rails::Hyperdrive::InstallShell.new(root: root, io: io) }
  let(:runner) { described_class.new(shell: shell, root: root) }

  before do
    FileUtils.cp(File.expand_path("../../fixtures/gemfile_lock/standard.lock", __dir__), File.join(root, "Gemfile.lock"))
    stub_discovery([])
  end

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def stub_discovery(artifacts)
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery).to receive(:discover).and_return(artifacts)
  end

  def guideline(name:, source: "rails-hyperdrive-x", body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  def exist?(rel) = File.exist?(File.join(root, rel))
  def read(rel) = File.read(File.join(root, rel))

  describe "#verify_environment!" do
    it "passes inside a development Rails app" do
      expect { runner.verify_environment! }.not_to raise_error
    end

    it "refuses to run when not inside a Rails app" do
      allow(::Rails).to receive(:root).and_return(nil)

      expect { runner.verify_environment! }.to raise_error(Thor::Error, /not in a Rails app/)
      expect(io.string).to include("must be run inside a Rails app")
    end

    it "refuses to run outside development" do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      allow(runner).to receive(:warn)

      expect { runner.verify_environment! }.to raise_error(Thor::Error, /refuse to run outside development/)
      expect(runner).to have_received(:warn).with(/Rails.env=development \(current: production\)/)
    end
  end

  describe "#load_stack_profile" do
    it "parses the app's Gemfile.lock once" do
      expect(Rails::Hyperdrive::StackProfile).to receive(:from_lockfile)
        .with(File.join(root, "Gemfile.lock"), app_root: root).once.and_call_original

      profile = runner.load_stack_profile
      expect(profile[:rails][:version]).to eq("8.0.1")
      expect(runner.load_stack_profile).to equal(profile)
    end
  end

  describe "#discover_artifacts" do
    it "collects warnings for the pipeline to print" do
      expect(Rails::Hyperdrive::BundlerArtifactDiscovery)
        .to receive(:discover).with(warnings: []).and_return([guideline(name: "g1")])

      expect(runner.discover_artifacts.map(&:name)).to eq(["g1"])
    end

    it "skips artifact discovery for the whole run when asked to" do
      stub_discovery([guideline(name: "g1")])
      expect(Rails::Hyperdrive::BundlerArtifactDiscovery).not_to receive(:discover).with(warnings: anything)

      expect(runner.discover_artifacts(skip: true)).to eq([])
      runner.install(mode: :preserve)
      expect(exist?(".claude/hyperdrive/guidelines/g1.md")).to be false
    end
  end

  describe "#install" do
    it "installs discovered content into the given root" do
      stub_discovery([guideline(name: "auth-pundit")])

      result = runner.install(mode: :preserve)

      expect(exist?(".claude/hyperdrive/stack.md")).to be true
      expect(exist?(".hyperdrive/lock.yml")).to be true
      expect(result).to be_a(Rails::Hyperdrive::InstallPipeline::Result)
      expect(result.installed).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
    end

    it "forwards the mode, so --overwrite restores a hand-edited file" do
      stub_discovery([guideline(name: "auth-pundit")])
      runner.install(mode: :preserve)
      path = ".claude/hyperdrive/guidelines/auth-pundit.md"
      File.write(File.join(root, path), "hand-edited\n")

      described_class.new(shell: shell, root: root).install(mode: :overwrite)

      expect(read(path)).to include("rule.")
    end
  end

  describe "#summary_lines" do
    it "is empty before anything is installed" do
      expect(runner.summary_lines).to eq([])
    end

    it "reports the lock the install left behind" do
      stub_discovery([guideline(name: "auth-pundit")])
      runner.install(mode: :preserve)

      expect(runner.summary_lines.first).to eq("  Installed 0 skills, 1 guideline + stack.md")
    end
  end
end
