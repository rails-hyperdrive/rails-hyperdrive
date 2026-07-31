require "spec_helper"
require "rails/hyperdrive/stack_profile"
require "rails/hyperdrive/bundler_artifact_discovery"

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

  it "buckets test gems" do
    keys = profile[:test].map { |t| t[:key] }
    expect(keys).to include(:rspec, :"rspec-rails")
  end

  it "buckets job gems" do
    expect(profile[:jobs].map { |t| t[:key] }).to include(:sidekiq)
  end

  it "buckets auth gems" do
    expect(profile[:auth].map { |t| t[:key] }).to include(:devise)
  end

  it "buckets authz gems" do
    expect(profile[:authz].map { |t| t[:key] }).to include(:pundit)
  end

  it "rolls turbo+stimulus into a hotwire entry" do
    hotwire = profile[:frontend].find { |t| t[:key] == :hotwire }
    expect(hotwire).not_to be_nil
    expect(hotwire[:versions]).to include(turbo: "2.0.5", stimulus: "1.3.4")
  end

  it "returns an error sentinel for a missing lockfile" do
    p = described_class.from_lockfile("/no/such/path/Gemfile.lock").to_h
    expect(p[:error]).to match(/not found/)
  end

  it "exposes the spec-mandated top-level keys" do
    expect(profile.keys).to include(
      :rails, :ruby, :database, :test, :jobs, :frontend,
      :auth, :authz, :db_gems, :gem_skills
    )
  end

  it "buckets db gems separately from the database adapter" do
    keys = profile[:db_gems].map { |g| g[:key] }
    # pg is categorised as a db gem, not as the adapter.
    expect(keys).to include(:pg)
  end

  it "returns an empty gem_skills list when discovery raises (never propagates)" do
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery)
      .to receive(:discover).and_raise(StandardError, "bundler exploded")
    expect(described_class.from_lockfile(lockfile).to_h[:gem_skills]).to eq([])
  end
end
