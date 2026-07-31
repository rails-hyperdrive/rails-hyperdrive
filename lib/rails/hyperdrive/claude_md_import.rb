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

      # action is :none, :create, or :append; body is the file content for
      # :create and the appended fragment for :append, nil otherwise.
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
    end
  end
end
