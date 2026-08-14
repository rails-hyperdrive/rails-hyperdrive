require "yaml"

module Rails
  module Hyperdrive
    # installed_at is volatile metadata, never an input to any comparison.
    class LockFile
      SCHEMA_VERSION = 1
      STATE_PRESENT  = "present".freeze
      STATE_REMOVED  = "removed-by-user".freeze

      DISABLED_KEYS = { skill: "skills", guideline: "guidelines" }.freeze

      # In-memory form of one files: entry. On disk, source_gem and
      # source_version are a single "gem@version" string; the split/join lives
      # in this file only.
      Entry = Struct.new(:path, :kind, :source_gem, :source_version, :source_sha, :installed_at, keyword_init: true) do
        def source_label
          source_version ? "#{source_gem}@#{source_version}" : source_gem
        end
      end

      attr_reader :path
      attr_accessor :claude_md_state

      # Load existing lock state from disk (absent file → empty lock).
      def self.load(path)
        new(path).tap(&:read)
      end

      def initialize(path)
        @path = path.to_s
        @claude_md_state = nil # nil = no lock has been written yet
        @files = {}            # path(String) => Entry
        @document = {}         # raw parsed YAML, kept so unknown keys survive
        @disabled = empty_disabled
        @enabled = []
      end

      def read
        return self unless File.exist?(@path)

        data = YAML.safe_load(File.read(@path))
        return self unless data.is_a?(Hash)

        @document = data
        claude_md = data["claude_md"]
        @claude_md_state = claude_md["state"] if claude_md.is_a?(Hash)
        @disabled = parse_disabled(data["disabled"])
        @enabled = parse_enabled(data["enabled"])
        Array(data["files"]).each do |raw|
          next unless raw.is_a?(Hash)
          entry = build_entry(raw)
          @files[entry.path] = entry if entry.path
        end
        self
      rescue Psych::SyntaxError
        self
      end

      def entry(file_path)
        @files[file_path.to_s]
      end

      def guideline_paths
        @files.values.select { |e| e.kind == "guideline" }.map(&:path)
      end

      def each_entry(&block)
        @files.values.each(&block)
      end

      def disabled?(type, name)
        Array(@disabled[type.to_sym]).include?(name.to_s)
      end

      # Hand-editable list of gems the app opts into as companions.
      def enabled_gems
        @enabled
      end

      # Adopt the state that is not derived from installed content, so
      # rewriting the file preserves it.
      def carry_settings(other)
        @document = other.document.dup
        @disabled = other.disabled_lists.dup
        @enabled = other.enabled_gems.dup
        self
      end

      def upsert(path:, kind:, source_gem:, source_version:, source_sha:, installed_at:)
        @files[path.to_s] = Entry.new(
          path: path.to_s,
          kind: kind.to_s,
          source_gem: source_gem.to_s,
          source_version: source_version.to_s,
          source_sha: source_sha.to_s,
          installed_at: installed_at.to_s
        )
      end

      def carry(entry)
        return unless entry && entry.path
        @files[entry.path] = entry
      end

      def to_yaml
        carried = @document["claude_md"]
        carried = {} unless carried.is_a?(Hash)

        document = @document.merge(
          "version"   => SCHEMA_VERSION,
          "claude_md" => carried.merge("state" => @claude_md_state),
          "disabled"  => DISABLED_KEYS.each_with_object({}) { |(type, key), h| h[key] = @disabled[type] },
          "enabled"   => @enabled,
          "files"     => @files.values.sort_by(&:path).map { |e| serialize_entry(e) }
        )
        # A nil state means no import line is being managed. Recording one anyway
        # would make the next run read the absent line as a deletion the user
        # made, and never add it back.
        document.delete("claude_md") if @claude_md_state.nil?
        document.to_yaml
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

      def parse_enabled(raw)
        return [] unless raw.is_a?(Array)

        raw.map { |name| name.to_s.strip }.reject(&:empty?).uniq
      end

      def build_entry(raw)
        source_gem, source_version = split_source(raw["source"])
        Entry.new(
          path: raw["path"],
          kind: raw["artifact"],
          source_gem: source_gem,
          source_version: source_version,
          source_sha: raw["source_sha"],
          installed_at: raw["installed_at"]
        )
      end

      # A source with no "@" (hand-edited) keeps its whole value as the gem
      # part with a nil version, so serialization re-emits it unchanged.
      def split_source(source)
        return [nil, nil] if source.nil?
        source = source.to_s
        idx = source.index("@")
        idx ? [source[0...idx], source[(idx + 1)..]] : [source, nil]
      end

      def serialize_entry(entry)
        {
          "path"         => entry.path,
          "artifact"     => entry.kind,
          "source"       => entry.source_label,
          "source_sha"   => entry.source_sha,
          "installed_at" => entry.installed_at
        }
      end
    end
  end
end
