require "rails/hyperdrive/config_file"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/install_plan"
require "rails/hyperdrive/lock_file"

module Rails
  module Hyperdrive
    # The comparison is against the lock manifest alone — installed files are
    # never read, so an edited or deleted file does not change a verdict.
    class ArtifactStatus
      STATES = %i[installed missing outdated orphaned].freeze

      Entry = Struct.new(:path, :state, :artifact, :locked_source, :bundle_source, :source_gem, :source_bundled,
        keyword_init: true) do
        def to_s
          case state
          when :missing  then "#{path} (from #{bundle_source})"
          when :outdated then "#{path} (#{locked_source} → #{bundle_source})"
          when :orphaned then "#{path} (#{orphan_reason})"
          else path
          end
        end

        private

        def orphan_reason
          LockFile.orphan_reason(source_label: locked_source, source_gem: source_gem, bundled: source_bundled)
        end
      end

      def self.compare(root:, artifacts:, bundled_gems: [], config: nil)
        new(root: root, artifacts: artifacts, bundled_gems: bundled_gems, config: config).tap(&:compare)
      end

      attr_reader :entries

      def initialize(root:, artifacts:, bundled_gems: [], config: nil)
        @root = File.expand_path(root.to_s)
        @artifacts = artifacts
        @bundled_gems = Array(bundled_gems).map(&:to_s)
        @config = config
        @entries = []
      end

      def compare
        lock = LockFile.load(File.join(@root, InstallLayout::LOCK_PATH))
        offered = {}

        InstallPlan.build(@artifacts, config: config).entries.each do |plan_entry|
          offered[plan_entry.dest] = [DriftVerdict.body_sha(plan_entry.install_ready_body), plan_entry.source_label, plan_entry.type]
          plan_entry.support_files.each do |file|
            offered[file[:dest]] = [DriftVerdict.body_sha(file[:body]), plan_entry.source_label, :skill_support]
          end
        end

        offered.each do |path, (gem_sha, source_label, type)|
          locked = lock.entry(path)
          state =
            if locked.nil? then :missing
            elsif locked.source_sha == gem_sha then :installed
            else :outdated
            end
          @entries << Entry.new(
            path: path, state: state, artifact: type,
            locked_source: locked&.source_label, bundle_source: source_label
          )
        end

        lock.each_entry do |locked|
          next if offered.key?(locked.path)

          # A disabled artifact left on disk was reported at install time; the
          # bundle still ships it, so it is not an orphan.
          type = InstallLayout::ARTIFACT_TYPES[locked.kind]
          next if type && InstallPlan.disabled_dest?(config, type, locked.path, source_gem: locked.source_gem)

          @entries << Entry.new(
            path: locked.path, state: :orphaned, artifact: locked.kind&.to_sym,
            locked_source: locked.source_label, bundle_source: nil,
            source_gem: locked.source_gem, source_bundled: @bundled_gems.include?(locked.source_gem.to_s)
          )
        end

        self
      end

      STATES.each do |state|
        define_method(state) { @entries.select { |e| e.state == state } }
      end

      def stale?
        !missing.empty? || !outdated.empty? || !orphaned.empty?
      end

      private

      def config
        @config ||= ConfigFile.load(File.join(@root, InstallLayout::CONFIG_PATH))
      end
    end
  end
end
