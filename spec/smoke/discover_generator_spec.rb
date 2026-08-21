require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "smoke_helper"

# discover fails open: offline/rate-limited runs still exit 0, so a clean exit
# alone proves nothing.
RSpec.describe "hyperdrive:discover smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("full_stack") }

  before do
    Smoke.add_path_gem!(app_dir)
    Smoke.bundle_install!(app_dir)
  end

  HEALTHY_OUTCOME = /no rails-hyperdrive companion gems found|Found gems with rails-hyperdrive/
  DEGRADED_OUTCOME = /discovery unavailable|rubygems unreachable/

  # A clean exit matching neither pattern is the silently-broken case and must fail.
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

    gitignore = File.join(app_dir, ".gitignore")
    expect(File.exist?(gitignore)).to be(true)
    lines = File.read(gitignore).split("\n").map(&:strip)
    expect(lines).to include(".hyperdrive/discover_cache.json")
    expect(lines).not_to include(".hyperdrive/", ".hyperdrive")

    expect(File.exist?(File.join(app_dir, ".mcp.json"))).to be(false)
    expect(File.exist?(File.join(app_dir, ".hyperdrive/lock.yml"))).to be(false)
    expect(Dir.exist?(File.join(app_dir, ".claude"))).to be(false)
    expect(File.read(File.join(app_dir, "Gemfile"))).not_to match(/rails-hyperdrive-/)
  end

  it "accepts --refresh through the command/Thor argv plumbing" do
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
  # ecosystem.
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
