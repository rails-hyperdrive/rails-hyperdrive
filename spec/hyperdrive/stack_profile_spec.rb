require "spec_helper"
require "tmpdir"
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
end
