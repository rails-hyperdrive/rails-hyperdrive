require "spec_helper"
require "rails/hyperdrive/eager_footprint"

RSpec.describe Rails::Hyperdrive::EagerFootprint do
  def entry(name, tokens)
    { name: name, body: "x" * (tokens * 4) }
  end

  describe ".approx_tokens" do
    it "rounds a quarter of the character count up" do
      expect(described_class.approx_tokens("x" * 400)).to eq(100)
      expect(described_class.approx_tokens("xxxxx")).to eq(2)
    end

    it "treats a nil body as empty" do
      expect(described_class.approx_tokens(nil)).to eq(0)
    end
  end

  describe ".lines" do
    it "reports the count and total under the budget" do
      lines = described_class.lines(
        guidelines: [entry("a.md", 100), entry("b.md", 50)], stack_body: "x" * 40
      )

      expect(lines.size).to eq(1)
      expect(lines.first.status).to eq(:eager)
      expect(lines.first.color).to eq(:cyan)
      expect(lines.first.message).to eq("2 guideline(s) + stack.md, ~160 tokens always in context")
    end

    it "warns and names only the two largest contributors over the budget" do
      lines = described_class.lines(
        guidelines: [entry("huge.md", 9_000), entry("big.md", 2_000), entry("tiny.md", 10)],
        stack_body: nil
      )

      expect(lines.size).to eq(2)
      expect(lines.last.status).to eq(:warn)
      expect(lines.last.color).to eq(:yellow)
      expect(lines.last.message).to eq(
        "eager context is over the ~10000 token budget (largest: huge.md ~9000, big.md ~2000); " \
        "trim them, or drop a line from .claude/hyperdrive/index.md to opt one out"
      )
    end

    it "counts no stack tokens when there is no stack body" do
      lines = described_class.lines(guidelines: [entry("a.md", 100)], stack_body: nil)

      expect(lines.first.message).to eq("1 guideline(s) + stack.md, ~100 tokens always in context")
    end

    it "reports a stack-only footprint" do
      lines = described_class.lines(guidelines: [], stack_body: "x" * 400)

      expect(lines.first.message).to eq("0 guideline(s) + stack.md, ~100 tokens always in context")
    end

    it "names stack.md among the largest when it dominates" do
      lines = described_class.lines(
        guidelines: [entry("a.md", 3_000), entry("tiny.md", 10)], stack_body: "x" * (9_000 * 4)
      )

      expect(lines.last.message).to include("largest: stack.md ~9000, a.md ~3000")
    end
  end
end
