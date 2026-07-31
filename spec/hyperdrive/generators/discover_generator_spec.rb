require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "generators/hyperdrive/discover/discover_generator"
require "rails/hyperdrive/companion_discovery"
require "fileutils"

RSpec.describe Rails::Generators::Hyperdrive::DiscoverGenerator do
  include Rails::Generators::Testing::Behavior
  include FileUtils

  destination File.expand_path("../../tmp/discover_generator", __dir__)
  tests described_class

  Suggestion = Rails::Hyperdrive::CompanionDiscovery::Suggestion
  Result = Rails::Hyperdrive::CompanionDiscovery::Result

  def stub_rails_root(path)
    allow(::Rails).to receive(:root).and_return(Pathname.new(path))
  end

  def stub_discovery(result)
    fake = instance_double(Rails::Hyperdrive::CompanionDiscovery, run: result)
    allow(Rails::Hyperdrive::CompanionDiscovery).to receive(:new).and_return(fake)
  end

  before do
    prepare_destination
    @app_dir = destination_root
    File.write(File.join(@app_dir, "Gemfile.lock"), File.read(File.expand_path("../../fixtures/gemfile_lock/standard.lock", __dir__)))
    stub_rails_root(@app_dir)
  end

  def path(rel) = File.join(@app_dir, rel)

  describe ".gitignore management" do
    before { stub_discovery(Result.new(suggestions: [], warnings: [], status: :online)) }

    it "creates .gitignore with the discover-cache rule when none exists" do
      run_generator([])
      expect(File.read(path(".gitignore"))).to include(".hyperdrive/discover_cache.json")
    end

    it "appends the rule to an existing .gitignore" do
      File.write(path(".gitignore"), "/log\n/tmp\n")
      run_generator([])
      body = File.read(path(".gitignore"))
      expect(body).to include("/log")
      expect(body).to include(".hyperdrive/discover_cache.json")
    end

    it "is idempotent — does not duplicate the rule" do
      run_generator([])
      run_generator([])
      occurrences = File.read(path(".gitignore")).scan(".hyperdrive/discover_cache.json").length
      expect(occurrences).to eq(1)
    end

    it "ignores the specific file, not the .hyperdrive/ directory" do
      run_generator([])
      lines = File.read(path(".gitignore")).split("\n").map(&:strip)
      expect(lines).to include(".hyperdrive/discover_cache.json")
      expect(lines).not_to include(".hyperdrive/", ".hyperdrive")
    end
  end

  describe "reporting suggestions" do
    it "lists installed and suggested companions and prints bundle add only for suggested" do
      suggestions = [
        Suggestion.new(gem_name: "rails-hyperdrive-sidekiq", version: "1.2.0", targets: ["sidekiq"],
                       artifacts: ["skill"], matched_target: "sidekiq", matched_version: "7.3.4", installed: true),
        Suggestion.new(gem_name: "rails-hyperdrive-devise", version: "0.4.0", targets: ["devise"],
                       artifacts: ["guideline", "skill"], matched_target: "devise", matched_version: "4.9.4", installed: false)
      ]
      stub_discovery(Result.new(suggestions: suggestions, warnings: [], status: :online))

      out = run_generator([])
      expect(out).to include("Found gems with rails-hyperdrive content for your stack:")
      expect(out).to include("rails-hyperdrive-sidekiq 1.2.0")
      expect(out).to include("(installed)")
      expect(out).to include("ships guideline + skill")
      expect(out).to include("bundle add rails-hyperdrive-devise --group=development")
      expect(out).to include("bin/rails hyperdrive:init")
      expect(out).not_to include("bundle add rails-hyperdrive-sidekiq")
    end

    it "labels a universal companion as applying to any stack" do
      suggestions = [
        Suggestion.new(gem_name: "rails-hyperdrive-core", version: "1.0.0", targets: ["*"],
                       artifacts: ["guideline"], matched_target: nil, matched_version: nil, installed: false)
      ]
      stub_discovery(Result.new(suggestions: suggestions, warnings: [], status: :online))
      out = run_generator([])
      expect(out).to include("applies to any stack")
      expect(out).to include("ships guideline")
    end

    it "prints a friendly note when nothing matches the stack" do
      stub_discovery(Result.new(suggestions: [], warnings: [], status: :online))
      out = run_generator([])
      expect(out).to include("no rails-hyperdrive companion gems found")
    end

    it "surfaces warnings for skipped companions" do
      stub_discovery(Result.new(suggestions: [], warnings: ["rails-hyperdrive-x 1.0.0: no targets declared (skipped)"], status: :online))
      out = run_generator([])
      expect(out).to include("no targets declared")
    end
  end

  describe "environment guard" do
    it "refuses to run when not inside a Rails app" do
      allow(::Rails).to receive(:root).and_return(nil)
      capture(:stderr) { run_generator([]) }
      expect(File).not_to exist(path(".gitignore"))
    end
  end

  describe "degraded network" do
    it "flags stale cached results" do
      stub_discovery(Result.new(suggestions: [], warnings: [], status: :stale, age_seconds: 48 * 3600, detail: "rubygems unreachable (timeout)"))
      out = run_generator([])
      expect(out).to include("rubygems unreachable")
    end

    it "reports unavailable and still exits cleanly" do
      stub_discovery(Result.new(suggestions: [], warnings: [], status: :unavailable, detail: "rubygems unreachable (timeout)"))
      out = run_generator([])
      expect(out).to include("discovery unavailable")
    end
  end
end
