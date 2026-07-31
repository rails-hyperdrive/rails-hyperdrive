require "rails/hyperdrive/version"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/install_plan"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/lock_file"
require "rails/hyperdrive/stack_document"

module Rails
  module Hyperdrive
    # The comparison is against the lock manifest alone — installed files are
    # never read, so an edited or deleted file does not change a verdict.
    class ArtifactStatus
      STATES = %i[installed missing outdated orphaned].freeze

      Entry = Struct.new(:path, :state, :artifact, :locked_source, :bundle_source, keyword_init: true) do
        def to_s
          case state
          when :missing  then "#{path} (from #{bundle_source})"
          when :outdated then "#{path} (#{locked_source} → #{bundle_source})"
          when :orphaned then "#{path} (source #{locked_source} no longer in bundle)"
          else path
          end
        end
      end

      def self.compare(root:, artifacts:, stack:)
        new(root: root, artifacts: artifacts, stack: stack).tap(&:compare)
      end

      attr_reader :entries

      def initialize(root:, artifacts:, stack:)
        @root = File.expand_path(root.to_s)
        @artifacts = artifacts
        @stack = stack
        @entries = []
      end

      def compare
        lock = LockFile.load(File.join(@root, InstallPipeline::LOCK_PATH))
        offered = {}

        InstallPlan.build(@artifacts, lock: lock).each do |plan_entry|
          offered[plan_entry.dest] = [DriftVerdict.body_sha(plan_entry.install_ready_body), plan_entry.source_label, plan_entry.type]
          plan_entry.support_files.each do |file|
            offered[file[:dest]] = [DriftVerdict.body_sha(file[:body]), plan_entry.source_label, :skill_support]
          end
        end
        offered[InstallPipeline::STACK_PATH] =
          [DriftVerdict.body_sha(StackDocument.render(@stack)), "internal@#{VERSION}", :stack]

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
          type = InstallPipeline::ARTIFACT_TYPES[locked.kind]
          next if type && InstallPlan.disabled_dest?(lock, type, locked.path)

          @entries << Entry.new(
            path: locked.path, state: :orphaned, artifact: locked.kind&.to_sym,
            locked_source: locked.source_label, bundle_source: nil
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
    end
  end
end
