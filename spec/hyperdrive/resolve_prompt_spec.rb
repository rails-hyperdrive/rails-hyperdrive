require "spec_helper"
require "rails/hyperdrive/resolve_prompt"

RSpec.describe Rails::Hyperdrive::ResolvePrompt do
  def knobs(**overrides)
    {
      local: "app/local.md", remote: "/gems/new/remote.md", base: "/tmp/base.md",
      merged: "app/local.md", source: "rails-hyperdrive-x@2.0.0",
      previous_source: "rails-hyperdrive-x@1.0.0", kind: "guideline"
    }.merge(overrides)
  end

  describe "the binding" do
    it "binds every knob as a lower-case local" do
      values = described_class::KNOBS.each_with_index.to_h { |knob, i| [knob, "value-#{i}"] }
      template = described_class::KNOBS.map { |knob| "<%= #{knob} %>" }.join("|")

      expect(described_class.render(template, **values)).to eq(values.values.join("|"))
    end

    it "raises on a local the template names that is not a knob" do
      expect { described_class.render("<%= nope %>", **knobs) }.to raise_error(NameError)
    end

    it "refuses a knob the context does not define" do
      expect { described_class.render("x", **knobs, extra: 1) }.to raise_error(ArgumentError)
    end
  end

  describe "the shipped template" do
    def render(**overrides)
      described_class.render(described_class.default_template, **knobs(**overrides))
    end

    it "names the ancestor path and explains it when a base is available" do
      out = render(base: "/tmp/base.md")

      expect(out).to include("BASE:   /tmp/base.md")
      expect(out).to include("The common ancestor")
    end

    it "says the ancestor is unavailable when there is no base" do
      out = render(base: nil)

      expect(out).to include("BASE:   not available")
      expect(out).not_to include("The common ancestor")
    end

    it "names the previously received version when one is recorded" do
      expect(render(previous_source: "rails-hyperdrive-x@1.0.0"))
        .to include("last received came from rails-hyperdrive-x@1.0.0")
    end

    it "omits the previously received version when none is recorded" do
      expect(render(previous_source: nil)).not_to include("last received came from")
    end

    %w[skill agent].each do |kind|
      it "states the name: frontmatter rule for a #{kind}" do
        expect(render(kind: kind)).to include("leave the `name:` line exactly as REMOTE")
      end
    end

    it "omits the name: frontmatter rule for a guideline" do
      expect(render(kind: "guideline")).not_to include("leave the `name:` line exactly as REMOTE")
    end
  end
end
