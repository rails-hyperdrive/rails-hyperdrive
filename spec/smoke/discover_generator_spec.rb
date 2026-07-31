require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "smoke_helper"

# End-to-end smoke for `bin/rails hyperdrive:discover` against a real
# Rails app subprocess. Covers what the unit generator spec can't:
#   - bin/rails -> rake -> Thor argv plumbing (the `--` separator, --refresh)
#   - the discover_generator + companion_discovery require chain loading under
#     a real bundle
#   - a real Gemfile.lock read by CompanionDiscovery
#
# discover is the only networked command and ships dormant: no companion gems
# declaring `rails_hyperdrive_targets` are published yet, so a live query
# returns an empty suggestion set. It is also resilient — offline / API-down /
# rate-limited paths fall back to "stale" or "unavailable" and still exit 0.
#
# We hold a *healthy* run (rubygems reachable) to the real contract — it exits
# cleanly, gitignores its cache, and prints a HEALTHY_OUTCOME — so a silently
# broken discover (clean exit, no recognized output) fails. A degraded run is
# flagged and the outcome assertion skipped (the network-independent checks
# still run), keeping the suite deterministic regardless of network state.
#
# Out of scope here (Gap 6): discover with a *non-empty* live result and the
# 24h-cache-reuse path can't be exercised until companion gems are published to
# rubygems; both are covered at unit level via CompanionDiscovery's injectable
# `fetcher:`.
RSpec.describe "hyperdrive:discover smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("full_stack") }

  before do
    Smoke.add_path_gem!(app_dir)
    Smoke.bundle_install!(app_dir)
  end

  # A healthy discover run (rubygems reachable) prints one of these — the real
  # contract. We hold discover to it rather than to "any terminal string", so a
  # silently-broken command (clean exit, no recognized output) fails loudly.
  HEALTHY_OUTCOME = /no rails-hyperdrive companion gems found|Found gems with rails-hyperdrive/
  # Degraded runs (offline / API down / rate-limited) still exit 0 but can't
  # exercise the healthy contract. We flag + skip the outcome assertion only
  # (keeping the network-independent checks) so the suite stays deterministic.
  DEGRADED_OUTCOME = /discovery unavailable|rubygems unreachable/

  # Assert the healthy outcome, unless the run degraded (then warn + skip the
  # outcome check only). A clean exit whose output matches NEITHER fails here —
  # that's the silently-broken case this guards against.
  def assert_healthy_or_degraded(out)
    if out.match?(DEGRADED_OUTCOME)
      warn "[discover smoke] degraded run (offline/rate-limited); skipped healthy-outcome assertion:\n#{out}"
    else
      expect(out).to match(HEALTHY_OUTCOME), "discover exited 0 but printed no recognized outcome:\n#{out}"
    end
  end

  it "runs end-to-end, exits cleanly, and gitignores its cache" do
    out, status = Smoke.run_hyperdrive_discover!(app_dir)

    expect(status.success?).to be(true), "hyperdrive:discover failed:\n#{out}"
    assert_healthy_or_degraded(out)

    # The cache file is the one gitignored rails-hyperdrive artifact; ignore the
    # specific file, not the .hyperdrive/ directory (the lockfile stays tracked).
    gitignore = File.join(app_dir, ".gitignore")
    expect(File.exist?(gitignore)).to be(true)
    lines = File.read(gitignore).split("\n").map(&:strip)
    expect(lines).to include(".hyperdrive/discover_cache.json")
    expect(lines).not_to include(".hyperdrive/", ".hyperdrive")

    # discover never touches the Gemfile or installs content.
    expect(File.exist?(File.join(app_dir, ".mcp.json"))).to be(false)
    expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/stack.md"))).to be(false)
    expect(File.read(File.join(app_dir, "Gemfile"))).not_to match(/rails-hyperdrive-/)
  end

  it "accepts --refresh through the rake/Thor argv plumbing" do
    out, status = Smoke.run_hyperdrive_discover!(app_dir, "--refresh")
    expect(status.success?).to be(true), "hyperdrive:discover --refresh failed:\n#{out}"
    assert_healthy_or_degraded(out)
  end

  it "is idempotent — does not duplicate the .gitignore rule across runs" do
    Smoke.run_hyperdrive_discover!(app_dir)
    Smoke.run_hyperdrive_discover!(app_dir)
    occurrences = File.read(File.join(app_dir, ".gitignore")).scan(".hyperdrive/discover_cache.json").length
    expect(occurrences).to eq(1)
  end

  # Discovery depends on rubygems' undocumented field-scoped metadata search,
  # which fails open: a retired query returns an empty 200 that reads as an empty
  # ecosystem. A widely-published key must match, and an absent key must not.
  describe "rubygems field-scoped metadata search" do
    def search_count(query)
      uri = URI("https://rubygems.org/api/v1/search.json")
      uri.query = URI.encode_www_form(query: query)
      resp = Net::HTTP.get_response(uri)
      skip "rubygems returned HTTP #{resp.code}" unless resp.code.to_i == 200
      body = JSON.parse(resp.body)
      body.is_a?(Array) ? body.length : skip("unexpected search payload shape")
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => e
      skip "rubygems unreachable (#{e.class}: #{e.message})"
    end

    it "matches a metadata key that is widely published" do
      expect(search_count("metadata.rubygems_mfa_required:true")).to be > 0
    end

    it "matches nothing for a metadata key no gem declares" do
      expect(search_count("metadata.zzz_rails_hyperdrive_canary_absent:*")).to eq(0)
    end
  end
end
