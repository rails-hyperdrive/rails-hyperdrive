require "yaml"
require "rails/hyperdrive/install_layout"

module Rails
  module Hyperdrive
    # installed_at is volatile metadata, never an input to any comparison.
    class LockFile
      SCHEMA_VERSION = 3
      STATE_PRESENT  = "present".freeze
      STATE_REMOVED  = "removed-by-user".freeze

      # In-memory form of one files: entry. On disk, source_gem and
      # source_version are a single "gem@version" string; the split/join lives
      # in this file only.
      Entry = Struct.new(
        :path, :kind, :source_gem, :source_version, :source_sha, :installed_at,
        :ancestor_gem, :ancestor_version, :ancestor_sha, :ancestor_relpath,
        keyword_init: true
      ) do
        def source_label
          source_version ? "#{source_gem}@#{source_version}" : source_gem
        end

        # The upstream the live file's edits descend from, recorded only while
        # a sidecar delivery is pending.
        def ancestor_label
          return nil unless ancestor_gem
          ancestor_version ? "#{ancestor_gem}@#{ancestor_version}" : ancestor_gem
        end

        def ancestor?
          !ancestor_gem.nil? && !ancestor_sha.nil?
        end
      end

      attr_reader :path, :schema_version
      attr_accessor :claude_md_state

      # Load existing lock state from disk (absent file → empty lock).
      def self.load(path)
        new(path).tap(&:read)
      end

      # Every surface reporting an orphan must name the same two cases, or a
      # sync and a bundle install would disagree about why a file is stranded.
      def self.orphan_reason(source_label:, source_gem:, bundled:)
        return "no longer shipped by #{source_label}" unless bundled
        "#{source_gem} is still bundled but did not offer this file"
      end

      def initialize(path)
        @path = path.to_s
        @claude_md_state = nil # nil = no lock has been written yet
        @files = {}            # path(String) => Entry
        @document = {}         # raw parsed YAML, kept so unknown keys survive
        @legacy_settings = false
        @schema_version = nil
      end

      def read
        return self unless File.exist?(@path)

        data = YAML.safe_load(File.read(@path))
        return self unless data.is_a?(Hash)

        @document = data
        @schema_version = data["version"]
        claude_md = data["claude_md"]
        @claude_md_state = claude_md["state"] if claude_md.is_a?(Hash)
        @legacy_settings = data.key?("disabled") || data.key?("enabled")
        Array(data["files"]).each do |raw|
          next unless raw.is_a?(Hash)
          entry = build_entry(raw)
          @files[entry.path] = entry if entry.path
        end
        self
      rescue Psych::SyntaxError
        self
      end

      # A lock written by a newer installer holds state this one cannot read,
      # so rewriting it would silently drop the user's settings. A missing or
      # non-numeric version reads as not ahead: every lock ever written carries
      # an integer version, and a hand-broken one must not block a sync.
      def schema_ahead?
        @schema_version.is_a?(Numeric) && @schema_version > SCHEMA_VERSION
      end

      def schema_ahead_message(display_path)
        "#{display_path} was written by a newer rails-hyperdrive (lock schema #{@schema_version}, " \
          "this installer supports #{SCHEMA_VERSION}); upgrade rails-hyperdrive"
      end

      def legacy_settings?
        @legacy_settings
      end

      def legacy_settings_message(display_path)
        "#{display_path} carries disabled:/enabled:; those settings now live in " \
          "#{InstallLayout::CONFIG_PATH} and are ignored here"
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

      # Adopt the state that is not derived from installed content, so
      # rewriting the file preserves it.
      def carry_document(other)
        @document = other.document.dup
        self
      end

      def upsert(path:, kind:, source_gem:, source_version:, source_sha:, installed_at:,
                 ancestor_gem: nil, ancestor_version: nil, ancestor_sha: nil, ancestor_relpath: nil)
        @files[path.to_s] = Entry.new(
          path: path.to_s,
          kind: kind.to_s,
          source_gem: source_gem.to_s,
          source_version: source_version.to_s,
          source_sha: source_sha.to_s,
          installed_at: installed_at.to_s,
          ancestor_gem: ancestor_gem,
          ancestor_version: ancestor_version,
          ancestor_sha: ancestor_sha,
          ancestor_relpath: ancestor_relpath
        )
      end

      # Replaces the entry rather than mutating it, so an entry carried from a
      # lock read earlier in the run keeps the values that run compared against.
      def clear_ancestor(file_path)
        entry = @files[file_path.to_s]
        return unless entry&.ancestor_gem || entry&.ancestor_sha || entry&.ancestor_relpath

        @files[entry.path] = entry.dup.tap do |cleared|
          cleared.ancestor_gem = nil
          cleared.ancestor_version = nil
          cleared.ancestor_sha = nil
          cleared.ancestor_relpath = nil
        end
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
          "files"     => @files.values.sort_by(&:path).map { |e| serialize_entry(e) }
        )
        # A nil state means no import line is being managed. Recording one anyway
        # would make the next run read the absent line as a deletion the user
        # made, and never add it back.
        document.delete("claude_md") if @claude_md_state.nil?
        # Every other unknown key round-trips; these two must not, or a lock
        # would keep asserting settings nothing reads.
        document.delete("disabled")
        document.delete("enabled")
        document.to_yaml
      end

      protected

      def document
        @document
      end

      private

      def build_entry(raw)
        source_gem, source_version = split_source(raw["source"])
        ancestor_gem, ancestor_version = split_source(raw["ancestor_source"])
        Entry.new(
          path: raw["path"],
          kind: raw["artifact"],
          source_gem: source_gem,
          source_version: source_version,
          source_sha: raw["source_sha"],
          installed_at: raw["installed_at"],
          ancestor_gem: ancestor_gem,
          ancestor_version: ancestor_version,
          ancestor_sha: raw["ancestor_sha"],
          ancestor_relpath: raw["ancestor_relpath"]
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
        raw = {
          "path"         => entry.path,
          "artifact"     => entry.kind,
          "source"       => entry.source_label,
          "source_sha"   => entry.source_sha
        }
        # installed_at is re-added after the optional keys so their absence
        # leaves an entry's key order untouched.
        raw["ancestor_source"] = entry.ancestor_label if entry.ancestor_label
        raw["ancestor_sha"] = entry.ancestor_sha if entry.ancestor_sha
        raw["ancestor_relpath"] = entry.ancestor_relpath if entry.ancestor_relpath
        raw["installed_at"] = entry.installed_at
        raw
      end
    end
  end
end
