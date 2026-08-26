require "spec_helper"
require "rails/hyperdrive/install_layout"

RSpec.describe Rails::Hyperdrive::InstallLayout do
  describe "the kind registry" do
    it "keys every kind by its lock artifact string" do
      expect(described_class::ARTIFACT_TYPES).to eq(
        "skill" => :skill, "skill_support" => :skill_support, "guideline" => :guideline,
        "agent" => :agent, "command" => :command
      )
    end

    it "lists only the kinds a companion ships, in install order" do
      expect(described_class.content_kinds.map(&:type)).to eq(%i[skill guideline agent command])
    end

    it "reports each kind's manifest directory override key" do
      expect(described_class.dir_keys).to eq(%w[skills_dir agents_dir commands_dir])
    end

    it "reports the roots the target tool reads artifacts from" do
      expect(described_class.dest_roots)
        .to eq([".claude/skills", ".claude/hyperdrive", ".claude/agents", ".claude/commands"])
    end

    it "marks only the directory-shaped kinds as carrying supporting files" do
      expect(described_class.kind(:skill).dir_shaped?).to be(true)
      expect(described_class.kind(:guideline).dir_shaped?).to be(false)
    end

    it "resolves each kind's convention roots against the gem name" do
      expect(described_class.kind(:skill).roots_for("some_gem"))
        .to eq(["lib/some_gem/hyperdrive/skills", "skills"])
      expect(described_class.kind(:guideline).roots_for("some_gem"))
        .to eq(["lib/some_gem/hyperdrive/guidelines"])
    end
  end

  describe ".dest_for" do
    it "places a skill's SKILL.md under its own directory" do
      expect(described_class.dest_for(:skill, "jobs")).to eq(".claude/skills/jobs/SKILL.md")
    end

    it "places a guideline as a flat markdown file" do
      expect(described_class.dest_for(:guideline, "auth")).to eq(".claude/hyperdrive/guidelines/auth.md")
    end

    it "places an agent and a command as flat markdown files" do
      expect(described_class.dest_for(:agent, "reviewer")).to eq(".claude/agents/reviewer.md")
      expect(described_class.dest_for(:command, "analyze")).to eq(".claude/commands/analyze.md")
    end

    it "resolves through the (kind, target) table" do
      expect(described_class.dest_for(:skill, "jobs", target: :claude)).to eq(".claude/skills/jobs/SKILL.md")
      expect(described_class.dest_for(:skill, "jobs", target: :nowhere)).to be_nil
    end

    it "is nil for a kind that is never planned on its own" do
      expect(described_class.dest_for(:skill_support, "jobs")).to be_nil
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

    it "reads an agent's and a command's name from its basename" do
      expect(described_class.installed_name(:agent, ".claude/agents/reviewer.md")).to eq("reviewer")
      expect(described_class.installed_name(:command, ".claude/commands/analyze.md")).to eq("analyze")
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
