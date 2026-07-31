require "spec_helper"
require "rails/hyperdrive/index_document"

RSpec.describe Rails::Hyperdrive::IndexDocument do
  def g(base, body = "body of #{base}")
    { base: base, body: body }
  end

  describe ".render" do
    it "includes every guideline and sorts the lines under @stack.md when no index exists" do
      rendered = described_class.render(
        guidelines: [g("b.md"), g("a.md")], existing: nil, previously_installed: []
      )

      expect(rendered.content).to eq("@stack.md\n@guidelines/a.md\n@guidelines/b.md\n")
      expect(rendered.guidelines).to eq([{ name: "b.md", body: "body of b.md" }, { name: "a.md", body: "body of a.md" }])
    end

    it "renders @stack.md alone for an empty guideline list" do
      rendered = described_class.render(guidelines: [], existing: nil, previously_installed: [])

      expect(rendered.content).to eq("@stack.md\n")
      expect(rendered.guidelines).to eq([])
    end

    it "drops a previously installed guideline whose line the user deleted" do
      rendered = described_class.render(
        guidelines: [g("a.md"), g("b.md")],
        existing: "@stack.md\n@guidelines/a.md\n",
        previously_installed: ["a.md", "b.md"]
      )

      expect(rendered.content).to eq("@stack.md\n@guidelines/a.md\n")
      expect(rendered.guidelines).to eq([{ name: "a.md", body: "body of a.md" }])
    end

    it "adds a newly discovered guideline the lock does not record yet" do
      rendered = described_class.render(
        guidelines: [g("a.md"), g("new.md")],
        existing: "@stack.md\n@guidelines/a.md\n",
        previously_installed: ["a.md"]
      )

      expect(rendered.content).to eq("@stack.md\n@guidelines/a.md\n@guidelines/new.md\n")
      expect(rendered.guidelines.map { |x| x[:name] }).to eq(["a.md", "new.md"])
    end

    it "keeps a previously installed guideline whose line is still there" do
      rendered = described_class.render(
        guidelines: [g("a.md")],
        existing: "@stack.md\n@guidelines/a.md\n",
        previously_installed: ["a.md"]
      )

      expect(rendered.content).to eq("@stack.md\n@guidelines/a.md\n")
    end
  end

  describe ".amend" do
    it "returns nil when there is no index to amend" do
      expect(described_class.amend(existing: nil, added: ["a.md"])).to be_nil
    end

    it "returns nil when nothing was added" do
      expect(described_class.amend(existing: "@stack.md\n", added: [])).to be_nil
    end

    it "returns nil when every added line is already present" do
      expect(described_class.amend(existing: "@stack.md\n@guidelines/a.md\n", added: ["a.md"])).to be_nil
    end

    it "adds the new line, keeps orphan lines, and keeps @stack.md first" do
      content = described_class.amend(
        existing: "@stack.md\n@guidelines/gone.md\n@guidelines/a.md\n", added: ["a.md", "b.md"]
      )

      expect(content).to eq("@stack.md\n@guidelines/a.md\n@guidelines/b.md\n@guidelines/gone.md\n")
    end

    it "does not introduce @stack.md into an index that lacks it" do
      content = described_class.amend(existing: "@guidelines/a.md\n", added: ["b.md"])

      expect(content).to eq("@guidelines/a.md\n@guidelines/b.md\n")
    end

    it "normalizes blank lines and surrounding whitespace away" do
      content = described_class.amend(existing: "@stack.md\n\n  @guidelines/a.md  \n\n", added: ["b.md"])

      expect(content).to eq("@stack.md\n@guidelines/a.md\n@guidelines/b.md\n")
    end
  end
end
