require "spec_helper"
require "rails/hyperdrive/skill_template"

RSpec.describe Rails::Hyperdrive::SkillTemplate do
  let(:resolved) do
    {
      "alba"    => Gem::Version.new("2.4.1"),
      "sidekiq" => Gem::Version.new("7.3.0")
    }
  end

  def render(source)
    described_class.render(source, resolved: resolved)
  end

  describe "gem?" do
    it "is true for a bundled gem and false for an absent one" do
      expect(render(%(<%= gem?("alba") %> <%= gem?("view_component") %>))).to eq("true false")
    end

    it "matches an optional requirement against the resolved version" do
      expect(render(%(<%= gem?("alba", ">= 2") %>))).to eq("true")
      expect(render(%(<%= gem?("alba", ">= 3") %>))).to eq("false")
      expect(render(%(<%= gem?("alba", ">= 2, < 3") %>))).to eq("true")
    end

    it "is false with a requirement when the gem is absent" do
      expect(render(%(<%= gem?("view_component", ">= 0") %>))).to eq("false")
    end
  end

  describe "any_gem?" do
    it "is true when any named gem is bundled" do
      expect(render(%(<%= any_gem?("view_component", "sidekiq") %>))).to eq("true")
      expect(render(%(<%= any_gem?("view_component", "rubanok") %>))).to eq("false")
    end
  end

  describe "gem_version" do
    it "returns the version as a String, or nil" do
      expect(render(%(<%= gem_version("alba").class %>))).to eq("String")
      expect(render(%(<%= gem_version("alba") %>))).to eq("2.4.1")
      expect(render(%(<%= gem_version("view_component").nil? %>))).to eq("true")
    end
  end

  describe "canonical_render?" do
    it "is false in the install binding" do
      expect(render(%(<%= canonical_render? %>))).to eq("false")
    end

    it "is true in the canonical binding" do
      expect(described_class.render_canonical(%(<%= canonical_render? %>))).to eq("true")
    end

    it "renders one source two ways" do
      source = "<%- if canonical_render? -%>A<%- else -%>B<%- end -%>"
      expect(render(source)).to eq("B")
      expect(described_class.render_canonical(source)).to eq("A")
    end
  end

  describe "sealed binding" do
    it "exposes only the four helpers — no stray lookup surface" do
      expect { render("<%= resolved %>") }.to raise_error(NameError)
      expect { render("<%= config %>") }.to raise_error(NameError)
      expect { render("<%= app_root %>") }.to raise_error(NameError)
    end
  end

  describe "trim mode" do
    it "leaves no blank lines behind <%- -%> control flow" do
      source = "a\n<%- if gem?(\"alba\") -%>\nalba\n<%- end -%>\nb\n"
      expect(render(source)).to eq("a\nalba\nb\n")
    end
  end

  describe ".render_canonical" do
    def canonical(source)
      described_class.render_canonical(source)
    end

    it "treats every gem as present, requirement or not" do
      expect(canonical(%(<%= gem?("view_component") %> <%= gem?("view_component", ">= 99") %>)))
        .to eq("true true")
      expect(canonical(%(<%= any_gem?("nope", "also_nope") %>))).to eq("true")
    end

    it "resolves no versions: gem_version is nil" do
      expect(canonical(%(<%= gem_version("alba").nil? %>))).to eq("true")
      expect(canonical(%(<%= gem_version("alba") || "(any version)" %>))).to eq("(any version)")
    end

    it "includes every conditional branch" do
      source = "a\n<%- if gem?(\"alba\") -%>\nalba\n<%- end -%>\n<%- if gem?(\"nope\") -%>\nnope\n<%- end -%>\nb\n"
      expect(canonical(source)).to eq("a\nalba\nnope\nb\n")
    end
  end

  describe "errors" do
    it "propagates a compile error" do
      expect { render("<% if %>") }.to raise_error(SyntaxError)
    end

    it "propagates a runtime error" do
      expect { render("<% raise ArgumentError, 'boom' %>") }.to raise_error(ArgumentError, "boom")
    end
  end
end
