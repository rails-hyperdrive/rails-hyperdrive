require "spec_helper"
require "rails/hyperdrive/companion_discovery"
require "json"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::CompanionDiscovery do
  Response = described_class::Response

  # Stand-in for the Net::HTTP fetcher. `pages` maps page-number → array of gem
  # hashes (rubygems search.json shape); `raise_error` simulates offline; a
  # `code` override drives the non-200 paths (e.g. 429).
  class FakeFetcher
    attr_reader :calls

    def initialize(pages: {}, raise_error: nil, code: 200, retry_after: nil)
      @pages = pages
      @raise_error = raise_error
      @code = code
      @retry_after = retry_after
      @calls = []
    end

    def get(uri)
      @calls << uri
      raise @raise_error if @raise_error

      page = uri[/page=(\d+)/, 1].to_i
      body = @code == 200 ? JSON.generate(@pages[page] || []) : ""
      Response.new(code: @code, body: body, retry_after: @retry_after)
    end
  end

  def gem_entry(name, version, targets: nil, artifacts: nil)
    metadata = {}
    metadata["rails_hyperdrive_targets"] = targets if targets
    metadata["rails_hyperdrive_artifacts"] = artifacts if artifacts
    { "name" => name, "version" => version, "metadata" => metadata }
  end

  let(:lockfile) { File.expand_path("../fixtures/gemfile_lock/standard.lock", __dir__) }
  let(:cache_dir) { Dir.mktmpdir("hyperdrive-discover") }
  let(:cache_path) { File.join(cache_dir, ".hyperdrive", "discover_cache.json") }

  after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

  def discovery(fetcher:, refresh: false, now: Time.utc(2026, 5, 29, 12, 0, 0))
    described_class.new(
      lockfile_path: lockfile, cache_path: cache_path,
      refresh: refresh, fetcher: fetcher, clock: -> { now }
    )
  end

  describe "matching against the stack" do
    let(:fetcher) do
      FakeFetcher.new(pages: { 1 => [
        gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq", artifacts: "skill"),
        gem_entry("rails-hyperdrive-devise", "0.4.0", targets: "devise", artifacts: "guideline,skill"),
        gem_entry("rails-hyperdrive-resque", "0.1.0", targets: "resque"), # not in stack
        gem_entry("some-unrelated-gem", "9.9.9", targets: "sidekiq")       # wrong prefix
      ] })
    end

    it "suggests companions whose declared target is in Gemfile.lock" do
      result = discovery(fetcher: fetcher).run
      names = result.suggestions.map(&:gem_name)
      expect(names).to contain_exactly("rails-hyperdrive-sidekiq", "rails-hyperdrive-devise")
    end

    it "records the matched target gem and its installed version" do
      result = discovery(fetcher: fetcher).run
      devise = result.suggestions.find { |s| s.gem_name == "rails-hyperdrive-devise" }
      expect(devise.matched_target).to eq("devise")
      expect(devise.matched_version).to eq("4.9.4")
      expect(devise.artifacts).to eq(%w[guideline skill])
    end

    it "drops companions whose target is not in the stack" do
      result = discovery(fetcher: fetcher).run
      expect(result.suggestions.map(&:gem_name)).not_to include("rails-hyperdrive-resque")
    end

    it "filters out non-prefixed gems the substring search returns" do
      result = discovery(fetcher: fetcher).run
      expect(result.suggestions.map(&:gem_name)).not_to include("some-unrelated-gem")
    end
  end

  describe "universal companions" do
    it "suggests a `*`-target companion regardless of stack, with no matched target" do
      fetcher = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-core", "1.0.0", targets: "*")] })
      result = discovery(fetcher: fetcher).run
      suggestion = result.suggestions.first
      expect(suggestion.gem_name).to eq("rails-hyperdrive-core")
      expect(suggestion.matched_target).to be_nil
    end
  end

  describe "missing metadata" do
    it "skips a companion with no declared targets and warns" do
      fetcher = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-mystery", "1.0.0")] })
      result = discovery(fetcher: fetcher).run
      expect(result.suggestions).to be_empty
      expect(result.warnings.join).to include("no targets declared")
    end
  end

  describe "installed vs suggested" do
    it "marks a companion installed when the companion gem itself is bundled" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            sidekiq (7.3.4)
            rails-hyperdrive-sidekiq (1.2.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          rails-hyperdrive-sidekiq
          sidekiq

        BUNDLED WITH
           2.5.0
      LOCK
      lock_path = File.join(cache_dir, "Gemfile.lock")
      File.write(lock_path, lock)

      fetcher = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      result = described_class.new(
        lockfile_path: lock_path, cache_path: cache_path, fetcher: fetcher, clock: -> { Time.utc(2026, 5, 29) }
      ).run

      expect(result.suggestions.first.installed).to be(true)
    end
  end

  describe "pagination" do
    it "follows pages until a short page and stops" do
      page1 = Array.new(30) { |i| gem_entry("rails-hyperdrive-x#{i}", "1.0.0", targets: "sidekiq") }
      page2 = [gem_entry("rails-hyperdrive-tail", "1.0.0", targets: "sidekiq")]
      fetcher = FakeFetcher.new(pages: { 1 => page1, 2 => page2 })
      result = discovery(fetcher: fetcher).run
      expect(fetcher.calls.size).to eq(2)
      expect(result.suggestions.map(&:gem_name)).to include("rails-hyperdrive-tail")
    end
  end

  describe "caching" do
    it "writes a cache file after a live fetch" do
      fetcher = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      discovery(fetcher: fetcher).run
      expect(File).to exist(cache_path)
      expect(JSON.parse(File.read(cache_path))).to include("fetched_at", "candidates")
    end

    it "serves a fresh cache without hitting the network" do
      first = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      now = Time.utc(2026, 5, 29, 12, 0, 0)
      discovery(fetcher: first, now: now).run

      second = FakeFetcher.new(raise_error: SocketError.new("should not be called"))
      result = discovery(fetcher: second, now: now + 3600).run # 1h later, within TTL
      expect(second.calls).to be_empty
      expect(result.status).to eq(:online)
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-sidekiq"])
    end

    it "re-queries once the cache is older than the 24h TTL" do
      first = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      now = Time.utc(2026, 5, 29, 12, 0, 0)
      discovery(fetcher: first, now: now).run

      second = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-devise", "0.4.0", targets: "devise")] })
      result = discovery(fetcher: second, now: now + (25 * 3600)).run
      expect(second.calls).not_to be_empty
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-devise"])
    end

    it "busts a fresh cache with refresh: true" do
      first = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      now = Time.utc(2026, 5, 29, 12, 0, 0)
      discovery(fetcher: first, now: now).run

      second = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-devise", "0.4.0", targets: "devise")] })
      result = discovery(fetcher: second, refresh: true, now: now + 60).run
      expect(second.calls).not_to be_empty
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-devise"])
    end
  end

  describe "offline / API-down" do
    it "falls back to a stale cache and flags it" do
      first = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      now = Time.utc(2026, 5, 29, 12, 0, 0)
      discovery(fetcher: first, now: now).run

      down = FakeFetcher.new(raise_error: SocketError.new("getaddrinfo failed"))
      result = discovery(fetcher: down, now: now + (48 * 3600)).run
      expect(result.status).to eq(:stale)
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-sidekiq"])
      expect(result.detail).to include("unreachable")
    end

    it "reports unavailable when offline with no cache" do
      down = FakeFetcher.new(raise_error: SocketError.new("getaddrinfo failed"))
      result = discovery(fetcher: down).run
      expect(result.status).to eq(:unavailable)
      expect(result.suggestions).to be_empty
    end

    it "treats HTTP 429 as unavailable and surfaces the Retry-After hint" do
      throttled = FakeFetcher.new(code: 429, retry_after: "120")
      result = discovery(fetcher: throttled).run
      expect(result.status).to eq(:unavailable)
      expect(result.detail).to include("120")
    end

    it "treats a non-200/429 HTTP status as unavailable" do
      result = discovery(fetcher: FakeFetcher.new(code: 500)).run
      expect(result.status).to eq(:unavailable)
      expect(result.detail).to include("HTTP 500")
    end

    it "treats a malformed search response as unavailable" do
      malformed = Class.new do
        def get(_uri)
          Rails::Hyperdrive::CompanionDiscovery::Response.new(code: 200, body: "{ not json")
        end
      end.new
      result = discovery(fetcher: malformed).run
      expect(result.status).to eq(:unavailable)
      expect(result.detail).to include("malformed search response")
    end
  end

  describe "resilience" do
    it "treats an unparseable lockfile as an empty stack (only universal companions match)" do
      allow(::Bundler::LockfileParser).to receive(:new).and_raise(RuntimeError, "boom")
      fetcher = FakeFetcher.new(pages: { 1 => [
        gem_entry("rails-hyperdrive-sidekiq", "1.0.0", targets: "sidekiq"),
        gem_entry("rails-hyperdrive-core", "1.0.0", targets: "*")
      ] })
      result = discovery(fetcher: fetcher).run
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-core"])
    end

    it "ignores a corrupt cache file and re-fetches" do
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(cache_path, "{ corrupt")
      fetcher = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      result = discovery(fetcher: fetcher).run
      expect(fetcher.calls).not_to be_empty
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-sidekiq"])
    end

    it "does not raise when the cache cannot be written" do
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES, "denied")
      fetcher = FakeFetcher.new(pages: { 1 => [gem_entry("rails-hyperdrive-sidekiq", "1.2.0", targets: "sidekiq")] })
      result = nil
      expect { result = discovery(fetcher: fetcher).run }.not_to raise_error
      expect(result.suggestions.map(&:gem_name)).to eq(["rails-hyperdrive-sidekiq"])
    end
  end

  describe described_class::NetHttpFetcher do
    it "performs the HTTP GET and maps the response shape" do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      raw = instance_double(Net::HTTPResponse, code: "200", body: "[]")
      allow(raw).to receive(:[]).with("retry-after").and_return(nil)
      allow(http).to receive(:get).and_return(raw)

      resp = described_class.new.get("https://rubygems.org/api/v1/search.json?query=x&page=1")
      expect(resp.code).to eq(200)
      expect(resp.body).to eq("[]")
      expect(resp.retry_after).to be_nil
    end
  end
end
