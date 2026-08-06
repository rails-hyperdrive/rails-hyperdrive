require "spec_helper"
require "rails/hyperdrive/three_way_merge"

RSpec.describe Rails::Hyperdrive::ThreeWayMerge do
  let(:base) { "line one\nline two\nline three\nline four\nline five\n" }

  it "merges non-overlapping edits cleanly" do
    ours   = base.sub("line one", "line one (mine)")
    theirs = base.sub("line five", "line five (upstream)")

    outcome = described_class.merge(ours: ours, base: base, theirs: theirs)

    expect(outcome.status).to eq(:clean)
    expect(outcome).to be_clean
    expect(outcome.body).to include("line one (mine)")
    expect(outcome.body).to include("line five (upstream)")
  end

  it "reports overlapping edits as conflicted and discards the output" do
    ours   = base.sub("line three", "line three (mine)")
    theirs = base.sub("line three", "line three (upstream)")

    outcome = described_class.merge(ours: ours, base: base, theirs: theirs)

    expect(outcome.status).to eq(:conflicted)
    expect(outcome).not_to be_clean
    expect(outcome.body).to be_nil
  end

  it "reports :unavailable when git is missing" do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "git")

    outcome = described_class.merge(ours: base, base: base, theirs: base)

    expect(outcome.status).to eq(:unavailable)
  end

  it "rejects binary input without invoking git" do
    expect(Open3).not_to receive(:capture3)

    outcome = described_class.merge(ours: "a\0b", base: base, theirs: base)

    expect(outcome.status).to eq(:unavailable)
  end

  it "rejects invalid UTF-8 input" do
    outcome = described_class.merge(ours: base, base: (+"\xff\xfe").force_encoding(Encoding::UTF_8), theirs: base)

    expect(outcome.status).to eq(:unavailable)
  end

  describe ".binary?" do
    it "detects NUL bytes and invalid UTF-8, and accepts plain text" do
      expect(described_class.binary?("a\0b")).to be true
      expect(described_class.binary?((+"\xff").force_encoding(Encoding::UTF_8))).to be true
      expect(described_class.binary?("héllo\n")).to be false
    end
  end
end
