module Rails
  module Hyperdrive
    # Guardrail (not a sandbox) against an AI accidentally mutating the dev
    # database. Rejects anything other than read-only statements at the regex
    # level. A determined caller with `run_ruby` can trivially bypass it.
    module SqlSafety
      ALLOWED_LEADERS = /\A\s*(WITH\b.*?\bSELECT\b|SELECT\b|EXPLAIN\b|SHOW\b|PRAGMA\b)/im
      FORBIDDEN_TOKEN = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|REPLACE|MERGE|RENAME|VACUUM|ATTACH|DETACH)\b/i

      class Error < StandardError; end

      module_function

      def assert_read_only!(sql)
        raise Error, "empty SQL" if sql.nil? || sql.strip.empty?
        unless sql =~ ALLOWED_LEADERS
          raise Error, "only SELECT / WITH...SELECT / EXPLAIN / SHOW / PRAGMA are allowed"
        end
        # Second pass catches a mutation smuggled inside a CTE body
        # (e.g. `WITH x AS (DELETE ...) SELECT ...`).
        if sql =~ FORBIDDEN_TOKEN
          raise Error, "forbidden token detected: #{Regexp.last_match(1)}"
        end
        true
      end
    end
  end
end
