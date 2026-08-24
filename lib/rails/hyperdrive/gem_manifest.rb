require "yaml"

module Rails
  module Hyperdrive
    # A companion gem's root manifest (hyperdrive.yml) declares artifact
    # gating: top-level gem:/gems: defaults for the whole gem,
    # per-skill entries keyed by the skill dir's relative path from its skills
    # root, per-guideline entries keyed by filename. Fail-open at every level:
    # malformed input warns and resolves to an ungated install — an artifact is
    # never skipped because its gating could not be read, and nothing raises.
    class GemManifest
      FILE_NAME = "hyperdrive.yml"
      METADATA_KEY = "hyperdrive_manifest"

      UNGATED = ["*"].freeze
      MATCH_MODES = %w[any all].freeze
      GEM_FORMS = "a gem, a comma-separated list, a YAML list of names and name: requirement " \
                  "pairs, or an any:/all: map (gems: is an alias)".freeze
      VERSIONS_REMOVED = "versions: is no longer supported; version constraints ignored — " \
                         "put the requirement on the gem: member, e.g. `- name: \">= 1.0\"`".freeze

      Gate = Struct.new(:targets, :versions, :hyperdrive_version, :conditional, :match_mode,
        keyword_init: true)

      # `warning`, when set, is phrased for the caller to prefix with its own
      # context — the parser has no idea which entry it is reading.
      TargetSpec = Struct.new(:targets, :match_mode, :versions, :warning, keyword_init: true)

      GemKey = Struct.new(:value, :present, :conflict, :warning, keyword_init: true)

      class << self
        def load(spec, warnings: [])
          new(spec, warnings: warnings)
        end

        # gems: and gem: are exact aliases. A map carrying both is a stylistic
        # slip, not malformed input: picking a winner keeps the gate intact
        # where failing open would silently widen it.
        def gem_key(map)
          both = map.key?("gem") && map.key?("gems")
          GemKey.new(
            value: map.key?("gems") ? map["gems"] : map["gem"],
            present: map.key?("gem") || map.key?("gems"),
            conflict: both,
            warning: ("gem: and gems: are aliases; reading gems: and ignoring gem:" if both)
          )
        end

        # ".." segments are rejected (silent fallback to the conventional path)
        # to prevent escaping the gem root.
        def manifest_relpath(spec)
          return FILE_NAME unless spec.respond_to?(:metadata)
          raw = spec.metadata && spec.metadata[METADATA_KEY]
          return FILE_NAME if raw.nil? || raw.to_s.strip.empty?
          return FILE_NAME if raw.to_s.split(%r{[/\\]}).include?("..")
          raw.to_s
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
          parse_target_names(raw)
        end

        # A version requirement is optional everywhere; nil means unconstrained.
        def malformed_requirements?(versions)
          requirements = versions.is_a?(Hash) ? versions.values : [versions]
          requirements.compact.any? do |req|
            begin
              Gem::Requirement.new(*requirement_parts(req))
              false
            rescue ArgumentError
              true
            end
          end
        end

        # The fence names one requirement against one version, so a per-gem
        # requirement map is meaningless here.
        def malformed_fence?(value)
          return true if value.is_a?(Hash)
          malformed_requirements?(value)
        end

        def requirement_parts(req)
          Array(req).flat_map { |s| s.is_a?(String) ? s.split(",").map(&:strip) : s }
        end

        # Returns [root map or nil, failure reason or nil]. An absent or empty
        # file is a valid empty manifest; the caller phrases the failure and
        # decides whether to fall open on it.
        def read_root(path)
          return [{}, nil] unless File.file?(path)

          data = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
          return [{}, nil] if data.nil?
          return [data.transform_keys(&:to_s), nil] if data.is_a?(Hash)

          [nil, "root must be a YAML map"]
        rescue Psych::SyntaxError => e
          [nil, "malformed YAML (#{e.message})"]
        rescue StandardError => e
          [nil, "unreadable (#{e.message})"]
        end

        private

        # A list member is either a bare gem name (unconstrained, comma-split
        # for the inline multi-name spelling) or a single-pair map carrying
        # that member's own version requirement.
        def parse_target_names(raw)
          entries = raw.is_a?(Array) ? raw : [raw]
          names = []
          requirements = {}
          dropped_star = false

          entries.each do |entry|
            case entry
            when Hash
              name, requirement = pair_member(entry)
              return nil unless name
              if name == "*"
                dropped_star = true
                next
              end
              names << name
              requirements[name] = requirement if requirement
            when nil, Array
              return nil
            else
              names.concat(entry.to_s.split(",").map(&:strip).reject(&:empty?))
            end
          end

          names = UNGATED.dup if names.empty? && dropped_star
          TargetSpec.new(
            targets: names,
            match_mode: :any,
            versions: requirements.empty? ? nil : requirements,
            warning: ("a version requirement on '*' is meaningless; ignoring that member" if dropped_star)
          )
        end

        # nil signals a malformed member. A "*" key is kept for the caller to
        # drop — its requirement is meaningless, not unreadable.
        def pair_member(entry)
          return nil unless entry.size == 1

          name, requirement = entry.first
          name = name.to_s.strip
          return nil if name.empty?
          return [name, nil] if name == "*"
          return nil if requirement.is_a?(Hash)
          return [name, nil] if requirement.nil? || requirement == "*"
          return nil if malformed_requirements?(requirement)

          [name, requirement]
        end

        def parse_target_map(raw)
          keys = raw.keys.map(&:to_s)
          return nil unless keys.size == 1 && MATCH_MODES.include?(keys.first)

          # The list is the only container a mode key accepts. Reading a bare
          # map as a one-member pair would make `{sidekiq: ">= 7"}` gate while
          # its two-gem sibling falls open to ungated.
          return nil if raw.values.first.is_a?(Hash)

          spec = parse_target_names(raw.values.first)
          return nil if spec.nil?
          return spec if keys.first == "any"

          all_target_spec(spec)
        end

        # "*" is satisfied by definition, so dropping it leaves the remaining
        # targets gating; a list of nothing else has no targets left to gate on.
        def all_target_spec(spec)
          kept = spec.targets.reject { |n| n == "*" }
          dropped = kept.size != spec.targets.size

          TargetSpec.new(
            targets: dropped && kept.empty? ? UNGATED : kept,
            match_mode: :all,
            versions: spec.versions,
            warning: [spec.warning, ("'*' in all: is always satisfied; ignoring it" if dropped)]
              .compact.join("; ").then { |w| w.empty? ? nil : w }
          )
        end
      end

      def initialize(spec, warnings:)
        @spec = spec
        @warnings = warnings
        root = load_root
        @skills = section(root, "skills", "skill relpath")
        @guidelines = section(root, "guidelines", "guideline filename")
        @default_spec, @default_fence = defaults(root)
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

      def manifest_relpath
        self.class.manifest_relpath(@spec)
      end

      # Gating that cannot be read must never keep content out, so a failure
      # here resolves to an absent manifest.
      def load_root
        root, failure = self.class.read_root(File.join(@spec.full_gem_path, manifest_relpath))
        return root if root

        report("ignoring manifest #{manifest_relpath}: #{failure}")
        {}
      end

      def section(root, key, key_label)
        value = root[key]
        return {} if value.nil?
        unless value.is_a?(Hash)
          report("manifest #{key}: must be a map of #{key_label} to a gating map; ignoring the section")
          return {}
        end
        value.transform_keys(&:to_s)
      end

      # Independent axes: an unusable gem: must not silence a parseable fence,
      # the one gate that keeps content out of an installer too old to read it.
      def defaults(root)
        report("manifest top-level #{VERSIONS_REMOVED}") if root.key?("versions")
        [default_target_spec(root), default_fence(root)]
      end

      def default_target_spec(root)
        gem_key = self.class.gem_key(root)
        report("manifest top-level #{gem_key.warning}") if gem_key.warning
        return nil unless gem_key.present

        parsed = self.class.parse_targets(gem_key.value)
        if parsed.nil? || parsed.targets.empty?
          report("manifest top-level gem: default is unusable; ignoring it")
          return nil
        end
        report("manifest top-level gem: #{parsed.warning}") if parsed.warning
        parsed
      end

      def default_fence(root)
        return root["hyperdrive_version"] unless self.class.malformed_fence?(root["hyperdrive_version"])

        report("manifest top-level hyperdrive_version: default is unusable; ignoring it")
        nil
      end

      def default_gate
        build_gate(@default_spec, hyperdrive_version: @default_fence)
      end

      def ungated(hyperdrive_version: nil)
        build_gate(nil, hyperdrive_version: hyperdrive_version)
      end

      def build_gate(target_spec, hyperdrive_version: nil, conditional: nil)
        Gate.new(
          targets: target_spec ? target_spec.targets : UNGATED,
          versions: target_spec&.versions,
          hyperdrive_version: hyperdrive_version,
          conditional: conditional,
          match_mode: target_spec ? target_spec.match_mode : :any
        )
      end

      # Gating that cannot be read must not skip the artifact, so a malformed
      # entry installs ungated, gem-wide gem: default and all. The fence is
      # resolved first and rides those fall-throughs — except where it is
      # itself the unparsable part, since the gem-wide default would then apply
      # a constraint this entry never asked for.
      def entry_gate(entry, key, with_conditional:)
        unless entry.is_a?(Hash)
          report("manifest entry for '#{key}' must be a map with gem:; installing ungated unless fenced out")
          return ungated(hyperdrive_version: @default_fence)
        end

        entry = entry.transform_keys(&:to_s)
        if self.class.malformed_fence?(entry["hyperdrive_version"])
          report("manifest entry for '#{key}' has an unparsable hyperdrive_version: requirement; " \
                 "installing ungated and unfenced")
          return ungated
        end
        fence = entry.key?("hyperdrive_version") ? entry["hyperdrive_version"] : @default_fence

        gem_key = self.class.gem_key(entry)
        report("manifest entry for '#{key}': #{gem_key.warning}") if gem_key.warning
        parsed = gem_key.present ? self.class.parse_targets(gem_key.value) : nil
        if gem_key.present && (parsed.nil? || parsed.targets.empty?)
          report("manifest entry for '#{key}': gem: must name #{GEM_FORMS}; installing ungated unless fenced out")
          return ungated(hyperdrive_version: fence)
        end
        report("manifest entry for '#{key}': #{VERSIONS_REMOVED}") if entry.key?("versions")
        report("manifest entry for '#{key}' gem: #{parsed.warning}") if parsed&.warning

        build_gate(
          parsed || @default_spec,
          hyperdrive_version: fence,
          conditional: with_conditional ? entry["conditional"] : nil
        )
      end
    end
  end
end
