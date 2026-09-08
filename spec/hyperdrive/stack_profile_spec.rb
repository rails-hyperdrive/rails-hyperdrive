require "spec_helper"
require "tmpdir"
require "digest"
require "rails/hyperdrive/stack_profile"
require "rails/hyperdrive/bundler_artifact_discovery"
require "rails/hyperdrive/config_file"

RSpec.describe Rails::Hyperdrive::StackProfile do
  let(:lockfile) { File.expand_path("../fixtures/gemfile_lock/standard.lock", __dir__) }
  subject(:profile) { described_class.from_lockfile(lockfile).to_h }

  it "extracts Rails version + major" do
    expect(profile[:rails]).to eq(version: "8.0.1", major: 8)
  end

  it "extracts ruby version" do
    expect(profile[:ruby][:version]).to start_with("3.3.6")
  end

  it "derives the database adapter from config/database.yml when available" do
    # The internal dummy app ships a sqlite3 database.yml, so it wins over the
    # `pg` gem present in the fixture lockfile.
    expect(profile[:database][:adapter]).to eq("sqlite3")
  end

  it "falls back to gem hints when database.yml is unavailable" do
    allow(::Rails).to receive(:root).and_return(Pathname.new("/no/such/path"))
    p = described_class.from_lockfile(lockfile).to_h
    expect(p[:database][:adapter]).to eq("postgresql")
  end

  it "reports direct dependencies with their resolved versions, sorted by name" do
    expect(profile[:direct_dependencies]).to include(
      { name: "devise", version: "4.9.4" },
      { name: "rspec-rails", version: "7.0.1" },
      { name: "sidekiq", version: "7.3.4" }
    )
    names = profile[:direct_dependencies].map { |d| d[:name] }
    expect(names).to eq(names.sort)
  end

  it "excludes resolved-but-transitive gems" do
    names = profile[:direct_dependencies].map { |d| d[:name] }
    # minitest and rspec are in the resolved specs but not in DEPENDENCIES.
    expect(names).not_to include("minitest", "rspec")
  end

  it "returns an error sentinel for a missing lockfile" do
    p = described_class.from_lockfile("/no/such/path/Gemfile.lock").to_h
    expect(p[:error]).to match(/not found/)
  end

  it "exposes the spec-mandated top-level keys" do
    expect(profile.keys).to include(
      :rails, :ruby, :database, :direct_dependencies, :gem_skills
    )
  end

  it "forwards the app config's enabled: list to skill discovery" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".hyperdrive"))
      File.write(File.join(root, ".hyperdrive/config.yml"), "enabled:\n- opted_gem\n")
      expect(Rails::Hyperdrive::BundlerArtifactDiscovery)
        .to receive(:discover).with(enabled_gems: ["opted_gem"]).and_return([])
      described_class.from_lockfile(lockfile, app_root: root)
    end
  end

  it "discovers with no enabled gems when the config cannot be read" do
    allow(Rails::Hyperdrive::ConfigFile).to receive(:load).and_raise(StandardError, "corrupt")
    expect(Rails::Hyperdrive::BundlerArtifactDiscovery)
      .to receive(:discover).with(enabled_gems: []).and_return([])
    described_class.from_lockfile(lockfile, app_root: "/anywhere")
  end

  it "returns an empty gem_skills list when discovery raises (never propagates)" do
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery)
      .to receive(:discover).and_raise(StandardError, "bundler exploded")
    expect(described_class.from_lockfile(lockfile).to_h[:gem_skills]).to eq([])
  end

  describe "the default lockfile path" do
    it "reads Rails.root's Gemfile.lock when Rails is booted" do
      expect(described_class.default_lockfile_path).to eq(Rails.root.join("Gemfile.lock").to_s)
    end

    it "falls back to the working directory when no Rails root is available" do
      allow(::Rails).to receive(:respond_to?).with(:root).and_return(false)

      expect(described_class.default_lockfile_path).to eq(File.expand_path("Gemfile.lock", Dir.pwd))
    end
  end

  describe "the database adapter" do
    def lockfile_declaring(gem_name, version)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Gemfile.lock")
        File.write(path, <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              railties (8.0.1)
              #{gem_name} (#{version})

          PLATFORMS
            ruby

          DEPENDENCIES
            #{gem_name}

          BUNDLED WITH
             2.5.22
        LOCK
        yield path, dir
      end
    end

    # An app_root with no config/database.yml is what forces the gem-hint path.
    def adapter_for(gem_name, version)
      lockfile_declaring(gem_name, version) do |path, dir|
        described_class.from_lockfile(path, app_root: dir).to_h[:database]
      end
    end

    it "reads mysql2 from the resolved gems" do
      expect(adapter_for("mysql2", "0.5.6")).to eq(adapter: "mysql2")
    end

    it "reads trilogy from the resolved gems" do
      expect(adapter_for("trilogy", "2.8.1")).to eq(adapter: "trilogy")
    end

    it "reads sqlite3 from the resolved gems" do
      expect(adapter_for("sqlite3", "2.1.0")).to eq(adapter: "sqlite3")
    end

    it "reports no adapter when nothing names one" do
      expect(adapter_for("rake", "13.2.1")).to eq({})
    end

    it "falls back to gem hints when config/database.yml cannot be parsed" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config/database.yml"), "development:\n\tadapter: [unterminated\n")

        expect(described_class.from_lockfile(lockfile, app_root: root).to_h[:database])
          .to eq(adapter: "postgresql")
      end
    end
  end

  describe "gem_skills_info" do
    let(:skill) do
      Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
        name: "alpha-skill", artifact_type: :skill, target_gem: ["devise"],
        source_gem: "rails-hyperdrive-alpha", spec_version: "1.2.0",
        path: "/gems/rails-hyperdrive-alpha-1.2.0/skills/alpha-skill/SKILL.md",
        body: "---\nname: alpha-skill\n---\n"
      )
    end

    let(:guideline) do
      Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
        name: "alpha-guide", artifact_type: :guideline, source_gem: "rails-hyperdrive-alpha",
        spec_version: "1.2.0", path: "/gems/x/guidelines/alpha-guide.md", body: "body\n"
      )
    end

    before do
      allow(Rails::Hyperdrive::BundlerArtifactDiscovery)
        .to receive(:discover).and_return([skill, guideline])
    end

    it "describes each installed skill with its provenance and body hash" do
      expect(profile[:gem_skills]).to eq([{
        name: "alpha-skill",
        gem: ["devise"],
        source: "rails-hyperdrive-alpha",
        version: "1.2.0",
        path: "/gems/rails-hyperdrive-alpha-1.2.0/skills/alpha-skill/SKILL.md",
        sha256: Digest::SHA256.hexdigest(skill.body)
      }])
    end

    it "reports a universal skill's target as [\"*\"]" do
      skill.target_gem = ["*"]

      expect(profile[:gem_skills].first[:gem]).to eq(["*"])
    end

    it "reports skills only, never the other artifact kinds" do
      expect(profile[:gem_skills].map { |s| s[:name] }).to eq(["alpha-skill"])
    end
  end
end
