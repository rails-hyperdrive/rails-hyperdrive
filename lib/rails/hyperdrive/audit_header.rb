require "time"

module Rails
  module Hyperdrive
    module AuditHeader
      YAML_LINE = /\A#\s*hyperdrive:/.freeze
      HTML_LINE = /\A<!--\s*hyperdrive:.*-->\s*\z/.freeze

      module_function

      def fields(source_gem:, version:, sha256:, installed_at: Time.now.utc)
        [
          "source=#{source_gem}@#{version}",
          "sha256=#{sha256}",
          "installed_at=#{installed_at.iso8601}"
        ]
      end

      def build(source_gem:, version:, sha256:, installed_at: Time.now.utc)
        fields(source_gem: source_gem, version: version, sha256: sha256, installed_at: installed_at)
          .map { |f| "# hyperdrive: #{f}" }
          .join("\n")
      end

      def build_html(source_gem:, version:, sha256:, installed_at: Time.now.utc)
        fields(source_gem: source_gem, version: version, sha256: sha256, installed_at: installed_at)
          .map { |f| "<!-- hyperdrive: #{f} -->" }
          .join("\n")
      end

      def inject_into_frontmatter(body, header_block)
        lines = body.lines
        unless lines.first&.strip == "---"
          return "---\n#{header_block}\n---\n\n#{body}"
        end

        closing_index = lines[1..].index { |l| l.strip == "---" }
        return body unless closing_index

        absolute_closing = closing_index + 1
        lines.insert(absolute_closing, header_block + "\n")
        lines.join
      end

      def prepend_html(body, header_block)
        "#{header_block}\n\n#{body}"
      end

      # Strips only the contiguous injected block, never stray "# hyperdrive:"
      # or "<!-- -->" lines elsewhere in the body.
      def strip(body)
        lines = body.lines
        if lines.first&.strip == "---"
          strip_yaml(lines)
        else
          strip_html(lines)
        end
      end

      def strip_yaml(lines)
        closing_index = lines[1..].index { |l| l.strip == "---" }
        return lines.join unless closing_index

        absolute_closing = closing_index + 1
        first = (1...absolute_closing).find { |i| lines[i] =~ YAML_LINE }
        return lines.join unless first

        last = first
        last += 1 while last < absolute_closing && lines[last] =~ YAML_LINE
        (lines[0...first] + lines[last..]).join
      end

      def strip_html(lines)
        return lines.join unless lines.first =~ HTML_LINE

        i = 0
        i += 1 while lines[i] =~ HTML_LINE
        i += 1 if lines[i] && lines[i].strip.empty?
        lines[i..].join
      end
    end
  end
end
