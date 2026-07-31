require "yaml"

module Rails
  module Hyperdrive
    # Reads and writes `.hyperdrive/lock.yml` — the git-tracked manifest that
    # records, per installed file, the source gem + version, the canonical
    # `source_sha` (SHA256 of the install-ready body, pre audit-header
    # injection), and an install timestamp. Also tracks the CLAUDE.md
    # injected-line opt-out state and the hand-editable `disabled:` list.
    #
    # `installed_at` is volatile metadata, never an input to any comparison.
    #
    # Top-level keys this version does not recognize survive a read/write
    # round-trip; entries under `files:` are regenerated from the install run.
    class LockFile
      SCHEMA_VERSION = 1
      STATE_PRESENT  = "present".freeze
      STATE_REMOVED  = "removed-by-user".freeze

      DISABLED_KEYS = { skill: "skills", guideline: "guidelines" }.freeze

      attr_reader :path
      attr_accessor :claude_md_state

      # Load existing lock state from disk (absent file → empty lock).
      def self.load(path)
        new(path).tap(&:read)
      end

      def initialize(path)
        @path = path.to_s
        @claude_md_state = nil # nil = no lock has been written yet
        @files = {}            # path(String) => entry Hash(symbol keys)
        @document = {}         # raw parsed YAML, kept so unknown keys survive
        @disabled = empty_disabled
      end

      def read
        return self unless File.exist?(@path)

        data = YAML.safe_load(File.read(@path))
        return self unless data.is_a?(Hash)

        @document = data
        claude_md = data["claude_md"]
        @claude_md_state = claude_md["state"] if claude_md.is_a?(Hash)
        @disabled = parse_disabled(data["disabled"])
        Array(data["files"]).each do |raw|
          next unless raw.is_a?(Hash)
          entry = symbolize(raw)
          @files[entry[:path]] = entry if entry[:path]
        end
        self
      rescue Psych::SyntaxError
        self
      end

      def exists?
        File.exist?(@path)
      end

      def entry(file_path)
        @files[file_path.to_s]
      end

      def known?(file_path)
        @files.key?(file_path.to_s)
      end

      def guideline_paths
        @files.values.select { |e| e[:artifact] == "guideline" }.map { |e| e[:path] }
      end

      def each_entry(&block)
        @files.values.each(&block)
      end

      def disabled?(type, name)
        Array(@disabled[type.to_sym]).include?(name.to_s)
      end

      def disabled(type)
        Array(@disabled[type.to_sym]).dup
      end

      # Adopt the state that is not derived from installed content, so
      # rewriting the file preserves it.
      def carry_settings(other)
        @document = other.document.dup
        @disabled = other.disabled_lists.dup
        self
      end

      def upsert(path:, artifact:, source:, source_sha:, installed_at:)
        @files[path.to_s] = {
          path: path.to_s,
          artifact: artifact.to_s,
          source: source.to_s,
          source_sha: source_sha.to_s,
          installed_at: installed_at.to_s
        }
      end

      # Carry an existing entry forward unchanged (preserves installed_at).
      def carry(entry)
        return unless entry && entry[:path]
        @files[entry[:path]] = entry
      end

      def to_yaml
        claude_md = @document["claude_md"]
        claude_md = {} unless claude_md.is_a?(Hash)

        @document.merge(
          "version"   => SCHEMA_VERSION,
          "claude_md" => claude_md.merge("state" => (@claude_md_state || STATE_PRESENT)),
          "disabled"  => DISABLED_KEYS.each_with_object({}) { |(type, key), h| h[key] = @disabled[type] },
          "files"     => @files.values.sort_by { |e| e[:path] }.map { |e| stringify(e) }
        ).to_yaml
      end

      protected

      def document
        @document
      end

      def disabled_lists
        @disabled
      end

      private

      def empty_disabled
        DISABLED_KEYS.keys.each_with_object({}) { |type, h| h[type] = [] }
      end

      def parse_disabled(raw)
        return empty_disabled unless raw.is_a?(Hash)

        DISABLED_KEYS.each_with_object({}) do |(type, key), h|
          h[type] = Array(raw[key]).map { |name| name.to_s.strip }.reject(&:empty?).uniq
        end
      end

      def symbolize(raw)
        raw.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def stringify(entry)
        {
          "path"         => entry[:path],
          "artifact"     => entry[:artifact],
          "source"       => entry[:source],
          "source_sha"   => entry[:source_sha],
          "installed_at" => entry[:installed_at]
        }
      end
    end
  end
end
