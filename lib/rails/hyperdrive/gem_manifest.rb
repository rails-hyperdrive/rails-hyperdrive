require "yaml"

module Rails
  module Hyperdrive
    # A companion gem's root manifest (hyperdrive.yml) declares artifact
    # gating: top-level gem:/versions: defaults for the whole gem,
    # per-skill entries keyed by the skill dir's relative path from its skills
    # root, per-guideline entries keyed by filename. Fail-open at every level:
    # malformed input warns and resolves to an ungated install — an artifact is
    # never skipped because its gating could not be read, and nothing raises.
    class GemManifest
      FILE_NAME = "hyperdrive.yml"
      METADATA_KEY = "rails_hyperdrive_manifest"

      UNGATED = ["*"].freeze
      MATCH_MODES = %w[any all].freeze

      Gate = Struct.new(:targets, :versions, :conditional, :match_mode, keyword_init: true)

      # `warning`, when set, is phrased for the caller to prefix with its own
      # context — the parser has no idea which entry it is reading.
      TargetSpec = Struct.new(:targets, :match_mode, :warning, keyword_init: true)

      class << self
        def load(spec, warnings: [])
          new(spec, warnings: warnings)
        end

        # The metadata key counts even when its value is unusable — declaring
        # it at all signals companion intent.
        def opt_in?(spec)
          return true if File.file?(File.join(spec.full_gem_path, FILE_NAME))
          return false unless spec.respond_to?(:metadata)

          raw = spec.metadata && spec.metadata[METADATA_KEY]
          !raw.to_s.strip.empty?
        end

        # nil signals malformed; the caller decides how to fail open.
        def parse_targets(raw)
          return parse_target_map(raw) if raw.is_a?(Hash)
          names = parse_target_names(raw)
          names && TargetSpec.new(targets: names, match_mode: :any)
        end

        # versions: is optional everywhere; nil means unconstrained.
        def malformed_requirements?(versions)
          requirements = versions.is_a?(Hash) ? versions.values : [versions]
          requirements.compact.any? do |req|
            parts = Array(req).flat_map { |s| s.is_a?(String) ? s.split(",").map(&:strip) : s }
            begin
              Gem::Requirement.new(*parts)
              false
            rescue ArgumentError
              true
            end
          end
        end

        private

        def parse_target_names(raw)
          entries = raw.is_a?(Array) ? raw : [raw]
          return nil if entries.any? { |e| e.nil? || e.is_a?(Array) || e.is_a?(Hash) }
          entries.flat_map { |e| e.to_s.split(",") }.map(&:strip).reject(&:empty?)
        end

        def parse_target_map(raw)
          keys = raw.keys.map(&:to_s)
          return nil unless keys.size == 1 && MATCH_MODES.include?(keys.first)

          names = parse_target_names(raw.values.first)
          return nil if names.nil?
          return TargetSpec.new(targets: names, match_mode: :any) if keys.first == "any"

          all_target_spec(names)
        end

        # "*" is satisfied by definition, so dropping it leaves the remaining
        # targets gating; a list of nothing else has no targets left to gate on.
        def all_target_spec(names)
          kept = names.reject { |n| n == "*" }
          return TargetSpec.new(targets: names, match_mode: :all) if kept.size == names.size

          TargetSpec.new(
            targets: kept.empty? ? UNGATED : kept,
            match_mode: :all,
            warning: "'*' in all: is always satisfied; ignoring it"
          )
        end
      end

      def initialize(spec, warnings:)
        @spec = spec
        @warnings = warnings
        root = load_root
        @skills = section(root, "skills", "skill relpath")
        @guidelines = section(root, "guidelines", "guideline filename")
        @default_spec, @default_versions = defaults(root)
      end

      def skill_gate(rel)
        return default_gate unless @skills.key?(rel)
        entry_gate(@skills[rel], rel, with_conditional: true)
      end

      def guideline_gate(filename)
        return default_gate unless @guidelines.key?(filename)
        entry_gate(@guidelines[filename], filename, with_conditional: false)
      end

      def skill_keys
        @skills.keys
      end

      def guideline_keys
        @guidelines.keys
      end

      private

      def report(message)
        @warnings << "#{@spec.name}: #{message}"
      end

      # ".." segments are rejected (silent fallback to the conventional path)
      # to prevent escaping the gem root.
      def manifest_relpath
        return FILE_NAME unless @spec.respond_to?(:metadata)
        raw = @spec.metadata && @spec.metadata[METADATA_KEY]
        return FILE_NAME if raw.nil? || raw.to_s.strip.empty?
        return FILE_NAME if raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end

      # An empty file is a valid manifest (nothing gated); only content that
      # cannot be read as a YAML map warns.
      def load_root
        path = File.join(@spec.full_gem_path, manifest_relpath)
        return {} unless File.file?(path)

        data = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
        return {} if data.nil?
        unless data.is_a?(Hash)
          report("ignoring manifest #{manifest_relpath}: root must be a YAML map")
          return {}
        end
        data.transform_keys(&:to_s)
      rescue Psych::SyntaxError
        report("ignoring manifest #{manifest_relpath}: malformed YAML")
        {}
      rescue StandardError => e
        report("ignoring manifest #{manifest_relpath}: unreadable (#{e.message})")
        {}
      end

      def section(root, key, key_label)
        value = root[key]
        return {} if value.nil?
        unless value.is_a?(Hash)
          report("manifest #{key}: must be a map of #{key_label} to {gem:, versions:}; ignoring the section")
          return {}
        end
        value.transform_keys(&:to_s)
      end

      def defaults(root)
        parsed = root.key?("gem") ? self.class.parse_targets(root["gem"]) : nil
        bad_targets = root.key?("gem") && (parsed.nil? || parsed.targets.empty?)
        if bad_targets || self.class.malformed_requirements?(root["versions"])
          report("manifest top-level gem:/versions: defaults are unusable; ignoring them")
          return [nil, nil]
        end
        report("manifest top-level gem: #{parsed.warning}") if parsed&.warning
        [parsed, root["versions"]]
      end

      def default_gate
        build_gate(@default_spec, versions: @default_versions)
      end

      def ungated
        build_gate(nil)
      end

      def build_gate(target_spec, versions: nil, conditional: nil)
        Gate.new(
          targets: target_spec ? target_spec.targets : UNGATED,
          versions: versions,
          conditional: conditional,
          match_mode: target_spec ? target_spec.match_mode : :any
        )
      end

      # A malformed entry drops the gem-wide defaults too: gating that cannot
      # be read must not skip the artifact, so it installs ungated.
      def entry_gate(entry, key, with_conditional:)
        unless entry.is_a?(Hash)
          report("manifest entry for '#{key}' must be a map with gem:/versions:; installing ungated")
          return ungated
        end

        entry = entry.transform_keys(&:to_s)
        parsed = entry.key?("gem") ? self.class.parse_targets(entry["gem"]) : nil
        if entry.key?("gem") && (parsed.nil? || parsed.targets.empty?)
          report("manifest entry for '#{key}': gem: must name a gem, a comma-separated list, " \
                 "a YAML list, or an any:/all: map; installing ungated")
          return ungated
        end
        if self.class.malformed_requirements?(entry["versions"])
          report("manifest entry for '#{key}' has an unparsable versions: requirement; installing ungated")
          return ungated
        end
        report("manifest entry for '#{key}' gem: #{parsed.warning}") if parsed&.warning

        build_gate(
          parsed || @default_spec,
          versions: entry.key?("versions") ? entry["versions"] : @default_versions,
          conditional: with_conditional ? entry["conditional"] : nil
        )
      end
    end
  end
end
