require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require "time"
require "fileutils"
require "bundler"

module Rails
  module Hyperdrive
    # Read-only, networked discovery of *uninstalled* companion gems.
    #
    # Queries the rubygems search API for gems under the `rails-hyperdrive-`
    # prefix, reads their pre-install discovery metadata (`hyperdrive_targets` /
    # `hyperdrive_artifacts`) straight from the API response (no `.gem`
    # download), and matches the declared targets against the app's
    # `Gemfile.lock`. The result is a list of suggestions the user can act on
    # with `bundle add` + `hyperdrive:init`.
    #
    # Ships **dormant**: until companions exist on rubygems under the prefix the
    # search returns nothing and `run` yields an empty suggestion set.
    #
    # Network is best-effort: results are cached to `.hyperdrive/discover_cache.json`
    # (24h TTL, `--refresh` busts). Offline / API-down falls back to a stale
    # cache when present, otherwise reports "unavailable" — never raises.
    #
    # The pre-install `hyperdrive_targets` hint is deliberately NOT reconciled
    # with the per-artifact frontmatter `gem:` the installer uses; once a
    # companion is in the bundle, the in-bundle walk (BundlerArtifactDiscovery)
    # alone governs what installs. Companions are expected to keep each
    # artifact's targets within this coarser set — a target declared only in
    # frontmatter never reaches an app that has just that gem, because the
    # companion is never suggested to it.
    class CompanionDiscovery
      PREFIX              = "rails-hyperdrive-".freeze
      SEARCH_ENDPOINT     = "https://rubygems.org/api/v1/search.json".freeze
      CACHE_RELATIVE_PATH = ".hyperdrive/discover_cache.json".freeze
      PER_PAGE            = 30
      MAX_PAGES           = 34 # ~1000 companions; a runaway-pagination backstop
      CACHE_TTL           = 24 * 60 * 60
      OPEN_TIMEOUT        = 5
      READ_TIMEOUT        = 5

      # A companion gem matched to the user's stack.
      #   matched_target  — the in-bundle target gem that triggered the match
      #                     (nil for a universal `*` companion)
      #   installed       — whether the companion gem itself is already bundled
      Suggestion = Struct.new(
        :gem_name, :version, :targets, :artifacts,
        :matched_target, :matched_version, :installed,
        keyword_init: true
      )

      # Outcome of a run.
      #   status: :online      — served live or fresh-cached results
      #           :stale       — network failed; served an expired cache
      #           :unavailable — network failed and no cache to fall back to
      Result = Struct.new(:suggestions, :warnings, :status, :age_seconds, :detail, keyword_init: true)

      # Raised internally when the network path can't produce candidates.
      class Unavailable < StandardError
        attr_reader :retry_after

        def initialize(message, retry_after: nil)
          super(message)
          @retry_after = retry_after
        end
      end

      # Minimal HTTP client over Net::HTTP. Swappable in tests via the
      # `fetcher:` keyword — any object responding to `get(uri) -> Response`.
      Response = Struct.new(:code, :body, :retry_after, keyword_init: true)

      class NetHttpFetcher
        def get(uri)
          uri = URI(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          resp = http.get(uri.request_uri)
          Response.new(code: resp.code.to_i, body: resp.body.to_s, retry_after: resp["retry-after"])
        end
      end

      def initialize(lockfile_path:, cache_path:, refresh: false, fetcher: NetHttpFetcher.new, clock: -> { Time.now.utc })
        @lockfile_path = lockfile_path.to_s
        @cache_path    = cache_path.to_s
        @refresh       = refresh
        @fetcher       = fetcher
        @clock         = clock
      end

      def run
        warnings = []
        now = @clock.call
        candidates, status, age, detail = resolve_candidates(now)

        return Result.new(suggestions: [], warnings: warnings, status: :unavailable, detail: detail) if status == :unavailable

        suggestions = match(candidates, warnings)
        Result.new(suggestions: suggestions, warnings: warnings, status: status, age_seconds: age, detail: detail)
      end

      private

      # Returns [candidates, status, age_seconds, detail].
      def resolve_candidates(now)
        cache = read_cache
        if !@refresh && cache && fresh?(cache, now)
          return [cache[:candidates], :online, age_of(cache, now), nil]
        end

        begin
          candidates = fetch_all
          write_cache(candidates, now)
          [candidates, :online, 0, nil]
        rescue Unavailable => e
          detail = unavailable_detail(e)
          if cache
            [cache[:candidates], :stale, age_of(cache, now), detail]
          else
            [[], :unavailable, nil, detail]
          end
        end
      end

      def unavailable_detail(error)
        if error.retry_after
          "rubygems rate-limited the request (retry after #{error.retry_after}s)"
        else
          "rubygems unreachable (#{error.message})"
        end
      end

      # ---------- network ----------

      def fetch_all
        candidates = []
        page = 1
        loop do
          batch = fetch_page(page)
          candidates.concat(batch.select { |c| c[:name].start_with?(PREFIX) })
          break if batch.size < PER_PAGE # short page → last page
          page += 1
          break if page > MAX_PAGES
        end
        candidates
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => e
        raise Unavailable, e.message
      end

      def fetch_page(page)
        uri = "#{SEARCH_ENDPOINT}?query=#{URI.encode_www_form_component(PREFIX)}&page=#{page}"
        resp = @fetcher.get(uri)

        case resp.code
        when 200
          parse_search(resp.body)
        when 429
          raise Unavailable.new("rate limited", retry_after: resp.retry_after)
        else
          raise Unavailable, "HTTP #{resp.code}"
        end
      end

      def parse_search(body)
        data = JSON.parse(body)
        return [] unless data.is_a?(Array)
        data.map { |gem| { name: gem["name"].to_s, version: gem["version"].to_s, metadata: gem["metadata"] || {} } }
      rescue JSON::ParserError => e
        raise Unavailable, "malformed search response (#{e.message})"
      end

      # ---------- matching ----------

      def match(candidates, warnings)
        installed = installed_gems
        candidates.filter_map { |c| build_suggestion(c, installed, warnings) }
                  .sort_by { |s| [s.installed ? 0 : 1, s.gem_name] }
      end

      def build_suggestion(candidate, installed, warnings)
        name     = candidate[:name]
        metadata = candidate[:metadata] || {}
        targets  = parse_list(metadata["hyperdrive_targets"])

        if targets.empty?
          warnings << "#{name} #{candidate[:version]}: no targets declared (skipped)"
          return nil
        end

        matched_target, matched_version =
          if targets.include?("*")
            [nil, nil]
          else
            hit = targets.find { |t| installed.key?(t) }
            return nil unless hit # declared targets, none in this stack → not for us
            [hit, installed[hit]]
          end

        Suggestion.new(
          gem_name: name,
          version: candidate[:version],
          targets: targets,
          artifacts: parse_list(metadata["hyperdrive_artifacts"]),
          matched_target: matched_target,
          matched_version: matched_version,
          installed: installed.key?(name)
        )
      end

      def parse_list(raw)
        raw.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      def installed_gems
        return {} unless File.exist?(@lockfile_path)
        parser = ::Bundler::LockfileParser.new(File.read(@lockfile_path))
        parser.specs.each_with_object({}) { |s, h| h[s.name.to_s] = s.version.to_s }
      rescue StandardError
        # A malformed/unreadable lockfile must not break discovery — treat the
        # stack as empty (only `*`-target companions will then match).
        {}
      end

      # ---------- cache ----------

      def read_cache
        return nil unless File.exist?(@cache_path)
        data = JSON.parse(File.read(@cache_path))
        fetched_at = Time.iso8601(data["fetched_at"].to_s)
        candidates = Array(data["candidates"]).map do |c|
          { name: c["name"].to_s, version: c["version"].to_s, metadata: c["metadata"] || {} }
        end
        { fetched_at: fetched_at, candidates: candidates }
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def write_cache(candidates, now)
        FileUtils.mkdir_p(File.dirname(@cache_path))
        payload = {
          "fetched_at" => now.iso8601,
          "candidates" => candidates.map { |c| { "name" => c[:name], "version" => c[:version], "metadata" => c[:metadata] } }
        }
        File.write(@cache_path, JSON.pretty_generate(payload) + "\n")
      rescue SystemCallError
        # A non-writable cache dir must not break discovery.
        nil
      end

      def fresh?(cache, now)
        age_of(cache, now) < CACHE_TTL
      end

      def age_of(cache, now)
        now - cache[:fetched_at]
      end
    end
  end
end
