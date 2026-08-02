require "spec_helper"
require "rails/hyperdrive/claude_md_import"
require "rails/hyperdrive/lock_file"

RSpec.describe Rails::Hyperdrive::ClaudeMdImport do
  present = Rails::Hyperdrive::LockFile::STATE_PRESENT
  removed = Rails::Hyperdrive::LockFile::STATE_REMOVED

  line = "@.claude/hyperdrive/index.md"
  with_line = "# notes\n\n#{line}\n"
  without_line = "# notes\n"
  created = "<!-- AI instructions for this project. Managed content lives in .claude/hyperdrive/. -->\n\n#{line}\n"
  warning = "you removed #{line} from CLAUDE.md; leaving it out (won't re-add)"

  cases = [
    { desc: "creates the file when nothing is recorded and none exists",
      content: nil, state: nil, mode: :preserve,
      action: :create, body: created, new_state: present, warning: nil },
    { desc: "appends the line to a file the user already has",
      content: without_line, state: nil, mode: :preserve,
      action: :append, body: "\n#{line}\n", new_state: present, warning: nil },
    { desc: "adopts a file that already carries the line",
      content: with_line, state: nil, mode: :preserve,
      action: :none, body: nil, new_state: present, warning: nil },
    { desc: "records the opt-out and warns when the user deletes the line",
      content: without_line, state: present, mode: :preserve,
      action: :none, body: nil, new_state: removed, warning: warning },
    { desc: "records the opt-out when the user deletes the whole file",
      content: nil, state: present, mode: :preserve,
      action: :none, body: nil, new_state: removed, warning: warning },
    { desc: "leaves an already-present line alone",
      content: with_line, state: present, mode: :preserve,
      action: :none, body: nil, new_state: present, warning: nil },
    { desc: "flips back to present when the user re-adds the line",
      content: with_line, state: removed, mode: :preserve,
      action: :none, body: nil, new_state: present, warning: nil },
    { desc: "never re-adds a line the user opted out of",
      content: without_line, state: removed, mode: :preserve,
      action: :none, body: nil, new_state: removed, warning: nil },
    { desc: "appends in overwrite mode just as in preserve mode",
      content: without_line, state: nil, mode: :overwrite,
      action: :append, body: "\n#{line}\n", new_state: present, warning: nil },
    { desc: "writes nothing in additive mode with no recorded state",
      content: without_line, state: nil, mode: :additive,
      action: :none, body: nil, new_state: nil, warning: nil },
    { desc: "carries a present state through additive mode",
      content: without_line, state: present, mode: :additive,
      action: :none, body: nil, new_state: present, warning: nil },
    { desc: "carries an opt-out through additive mode without warning",
      content: without_line, state: removed, mode: :additive,
      action: :none, body: nil, new_state: removed, warning: nil },
    { desc: "carries an unrecognized hand-edited state through untouched",
      content: without_line, state: "weird", mode: :preserve,
      action: :none, body: nil, new_state: "weird", warning: nil }
  ].freeze

  cases.each do |c|
    it c[:desc] do
      decision = described_class.decide(content: c[:content], state: c[:state], mode: c[:mode])

      expect(decision.action).to eq(c[:action])
      expect(decision.body).to eq(c[:body])
      expect(decision.state).to eq(c[:new_state])
      expect(decision.warning).to eq(c[:warning])
    end
  end

  describe ".teardown" do
    it "deletes a CLAUDE.md byte-identical to the one it created" do
      decision = described_class.teardown(content: created, state: present)

      expect(decision.action).to eq(:delete)
      expect(decision.state).to be_nil
    end

    it "strips only its own line out of a file the user also writes in" do
      decision = described_class.teardown(content: "# notes\n\n#{line}\n\ntail\n", state: present)

      expect(decision.action).to eq(:rewrite)
      expect(decision.body).to eq("# notes\n\n\ntail\n")
      expect(decision.state).to be_nil
    end

    it "leaves exactly one trailing newline when its line was last" do
      decision = described_class.teardown(content: "# notes\n\n#{line}\n", state: present)

      expect(decision.body).to eq("# notes\n")
    end

    it "does nothing when the file is absent" do
      decision = described_class.teardown(content: nil, state: present)

      expect(decision.action).to eq(:none)
      expect(decision.state).to be_nil
    end

    it "does nothing when the line is not there" do
      decision = described_class.teardown(content: without_line, state: present)

      expect(decision.action).to eq(:none)
      expect(decision.state).to be_nil
    end

    it "keeps an opt-out the user made by hand, so no later run re-adds the line" do
      decision = described_class.teardown(content: created, state: removed)

      expect(decision.action).to eq(:none)
      expect(decision.state).to eq(removed)
    end
  end
end
