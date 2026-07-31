require "spec_helper"
require "rails/hyperdrive/install_layout"

RSpec.describe Rails::Hyperdrive::InstallLayout do
  describe ".dest_for" do
    it "places a skill's SKILL.md under its own directory" do
      expect(described_class.dest_for(:skill, "jobs")).to eq(".claude/skills/jobs/SKILL.md")
    end

    it "places a guideline as a flat markdown file" do
      expect(described_class.dest_for(:guideline, "auth")).to eq(".claude/hyperdrive/guidelines/auth.md")
    end
  end

  describe ".installed_name" do
    it "reads a skill's name from its directory" do
      expect(described_class.installed_name(:skill, ".claude/skills/jobs/SKILL.md")).to eq("jobs")
    end

    it "reads a supporting file's owning skill from the path" do
      expect(described_class.installed_name(:skill_support, ".claude/skills/jobs/references/deep.md")).to eq("jobs")
    end

    it "reads a guideline's name from its basename" do
      expect(described_class.installed_name(:guideline, ".claude/hyperdrive/guidelines/auth.md")).to eq("auth")
    end
  end

  describe ".skill_dir_of" do
    it "resolves a deep supporting-file path to its skill directory" do
      expect(described_class.skill_dir_of(".claude/skills/jobs/references/deep.md")).to eq(".claude/skills/jobs")
    end
  end

  describe "collision postfix" do
    it "joins name and source gem" do
      expect(described_class.postfixed_name("jobs", "gem_a")).to eq("jobs--gem_a")
    end

    it "round-trips back to the shipped name" do
      expect(described_class.base_name(described_class.postfixed_name("jobs", "gem_a"))).to eq("jobs")
    end

    it "leaves a non-postfixed name unchanged" do
      expect(described_class.base_name("jobs")).to eq("jobs")
    end
  end
end
