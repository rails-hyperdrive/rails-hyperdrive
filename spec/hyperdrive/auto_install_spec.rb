require "spec_helper"
require "rails/hyperdrive/auto_install"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::AutoInstall do
  let(:root) { Dir.mktmpdir("hyperdrive-auto-install") }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def guideline(name:, source: "rails-hyperdrive-x", body: nil, version: "1.0.0")
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: version
    )
  end

  def bundle_ships(artifacts)
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery).to receive(:discover).and_return(artifacts)
  end

  def initialize_app(artifacts)
    Rails::Hyperdrive::InstallPipeline.new(
      root: root, shell: Rails::Hyperdrive::InstallShell.new(root: root),
      artifacts: artifacts, mode: :preserve
    ).call
  end

  # Unpinned CI/frozen-bundle state would make every example a vacuously-passing no-op.
  around { |example| with_env("CI" => nil) { example.run } }

  before do
    allow(::Bundler).to receive(:frozen_bundle?).and_return(false)
    FileUtils.cp(File.expand_path("../fixtures/gemfile_lock/standard.lock", __dir__), File.join(root, "Gemfile.lock"))
  end

  describe "guards" do
    it "does nothing in an application that has never run hyperdrive:init" do
      bundle_ships([guideline(name: "auth-pundit")])

      result = described_class.run(root: root)

      expect(result.skipped).to eq(:not_initialized)
      expect(File).not_to exist(File.join(root, ".claude"))
    end

    it "does nothing outside development" do
      initialize_app([])
      bundle_ships([guideline(name: "auth-pundit")])

      result = described_class.run(root: root, env: "production")

      expect(result.skipped).to eq(:not_development)
      expect(File).not_to exist(File.join(root, ".claude/hyperdrive/guidelines/auth-pundit.md"))
    end

    it "does nothing on CI, where the environment often still reads as development" do
      initialize_app([])
      bundle_ships([guideline(name: "auth-pundit")])

      result = with_env("CI" => "true") { described_class.run(root: root) }

      expect(result.skipped).to eq(:not_development)
    end

    it "does nothing when the bundle is frozen" do
      initialize_app([])
      bundle_ships([guideline(name: "auth-pundit")])
      allow(::Bundler).to receive(:frozen_bundle?).and_return(true)

      expect(described_class.run(root: root).skipped).to eq(:not_development)
    end

    it "reports rather than raises when discovery blows up" do
      initialize_app([])
      allow(Rails::Hyperdrive::BundlerArtifactDiscovery).to receive(:discover).and_raise("boom")

      result = described_class.run(root: root)

      expect(result.skipped).to eq(:error)
      expect(result.error.message).to eq("boom")
    end
  end

  describe "installing what the lockfile does not record" do
    before { initialize_app([guideline(name: "auth-pundit")]) }

    it "installs a newly bundled companion's artifacts" do
      bundle_ships([guideline(name: "auth-pundit"), guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      result = described_class.run(root: root)

      expect(result.installed).to eq([".claude/hyperdrive/guidelines/jobs-sidekiq.md"])
      expect(File.read(File.join(root, ".claude/hyperdrive/index.md"))).to include("@guidelines/jobs-sidekiq.md")
    end

    it "leaves an installed guideline wired when the eager chain already exists" do
      bundle_ships([guideline(name: "auth-pundit"), guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      result = described_class.run(root: root)

      expect(result.unwired).to be false
      expect(result.messages.join("\n")).not_to include("not in context yet")
    end

    it "writes nothing at all when the lockfile is already current" do
      bundle_ships([guideline(name: "auth-pundit")])
      before_mtime = File.mtime(File.join(root, ".hyperdrive/lock.yml"))

      result = described_class.run(root: root)

      expect(result.installed).to be_empty
      expect(File.mtime(File.join(root, ".hyperdrive/lock.yml"))).to eq(before_mtime)
    end

    it "reports an upgraded companion instead of overwriting it" do
      bundle_ships([guideline(name: "auth-pundit", version: "2.0.0", body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# auth-pundit\n\nUPGRADED.\n")])

      result = described_class.run(root: root)

      expect(result.installed).to be_empty
      expect(result.outdated.map(&:path)).to eq([".claude/hyperdrive/guidelines/auth-pundit.md"])
      expect(File.read(File.join(root, ".claude/hyperdrive/guidelines/auth-pundit.md"))).to include("rule.")
      expect(result.messages.join("\n")).to include("bin/rails hyperdrive:sync")
    end

    it "reports an artifact whose source gem left the bundle" do
      bundle_ships([])

      result = described_class.run(root: root)

      expect(result.orphaned.map(&:path)).to eq([".claude/hyperdrive/guidelines/auth-pundit.md"])
      expect(File).to exist(File.join(root, ".claude/hyperdrive/guidelines/auth-pundit.md"))
    end

    it "never installs a disabled artifact" do
      disable("jobs-sidekiq")
      bundle_ships([guideline(name: "auth-pundit"), guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      result = described_class.run(root: root)

      expect(result.installed).to be_empty
      expect(File).not_to exist(File.join(root, ".claude/hyperdrive/guidelines/jobs-sidekiq.md"))
    end

    it "leaves an installed artifact on disk when it is disabled" do
      disable("auth-pundit")
      bundle_ships([guideline(name: "auth-pundit")])

      described_class.run(root: root)

      expect(File).to exist(File.join(root, ".claude/hyperdrive/guidelines/auth-pundit.md"))
    end
  end

  describe "the first guideline to reach a zero-companion application" do
    before { initialize_app([]) }

    it "lands on disk, and says it is not in context until a sync" do
      bundle_ships([guideline(name: "auth-pundit")])

      result = described_class.run(root: root)

      expect(result.installed).to eq([".claude/hyperdrive/guidelines/auth-pundit.md"])
      expect(result.unwired).to be true
      expect(result.messages.join("\n")).to include("not in context yet — run bin/rails hyperdrive:sync")
      expect(File).not_to exist(File.join(root, "CLAUDE.md"))
    end

    it "says nothing about context when only a skill arrives" do
      bundle_ships([skill(name: "jobs-sidekiq")])

      result = described_class.run(root: root)

      expect(result.installed).to eq([".claude/skills/jobs-sidekiq/SKILL.md"])
      expect(result.unwired).to be false
    end
  end

  def skill(name:, source: "rails-hyperdrive-x", version: "1.0.0")
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nhow to.\n",
      spec_version: version
    )
  end

  def disable(*names)
    lock_path = File.join(root, Rails::Hyperdrive::InstallLayout::LOCK_PATH)
    data = YAML.safe_load(File.read(lock_path))
    (data["disabled"] ||= {})["guidelines"] = names
    File.write(lock_path, data.to_yaml)
  end

  def with_env(vars)
    original = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end
end
