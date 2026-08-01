require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/lock_file"

module Rails
  module Hyperdrive
    # The persistent opt-out state machine for the single import line in
    # CLAUDE.md, as a pure function of the file's content, the recorded state,
    # and the install mode. The caller reads, writes, and prints.
    module ClaudeMdImport
      PATH = "CLAUDE.md".freeze
      INDEX_LINE = "@#{InstallLayout::INDEX_PATH}".freeze

      NEW_FILE = "<!-- AI instructions for this project. Managed content lives in " \
        "#{InstallLayout::HYPERDRIVE_DIR}/. -->\n\n#{INDEX_LINE}\n".freeze
      APPENDED = "\n#{INDEX_LINE}\n".freeze

      REMOVED_WARNING = "you removed #{INDEX_LINE} from #{PATH}; leaving it out (won't re-add)".freeze

      # action is :none, :create, :append, :delete, or :rewrite; body is the
      # file content for :create and :rewrite and the appended fragment for
      # :append, nil otherwise.
      Decision = Struct.new(:action, :body, :state, :warning, keyword_init: true)

      module_function

      # content is the current CLAUDE.md text, or nil when the file is absent.
      def decide(content:, state:, mode:)
        # CLAUDE.md is the user's own file; only a generator they ran edits it.
        return Decision.new(action: :none, state: state) if mode == :additive

        present = !content.nil? && content.include?(INDEX_LINE)

        if state.nil?
          return Decision.new(action: :create, body: NEW_FILE, state: LockFile::STATE_PRESENT) if content.nil?
          return Decision.new(action: :none, state: LockFile::STATE_PRESENT) if present

          Decision.new(action: :append, body: APPENDED, state: LockFile::STATE_PRESENT)
        elsif state == LockFile::STATE_PRESENT && !present
          Decision.new(action: :none, state: LockFile::STATE_REMOVED, warning: REMOVED_WARNING)
        elsif state == LockFile::STATE_REMOVED && present
          Decision.new(action: :none, state: LockFile::STATE_PRESENT)
        else
          Decision.new(action: :none, state: state)
        end
      end

      # Retracts the import line once nothing is left for it to pull in. A nil
      # state means the machine is disarmed, so a later guideline-bearing run
      # adds the line back.
      def teardown(content:, state:)
        # An opt-out the user made by hand outlives the line it removed.
        return Decision.new(action: :none, state: LockFile::STATE_REMOVED) if state == LockFile::STATE_REMOVED
        return Decision.new(action: :none, state: nil) if content.nil?
        return Decision.new(action: :none, state: nil) unless content.include?(INDEX_LINE)
        # Byte-identical to what we wrote proves nobody else owns the file.
        return Decision.new(action: :delete, state: nil) if content == NEW_FILE

        Decision.new(action: :rewrite, body: strip_index_line(content), state: nil)
      end

      def strip_index_line(content)
        kept = content.lines.reject { |line| line.strip == INDEX_LINE }.join
        kept.sub(/\n\n+\z/, "\n")
      end

      private_class_method :strip_index_line
    end
  end
end
