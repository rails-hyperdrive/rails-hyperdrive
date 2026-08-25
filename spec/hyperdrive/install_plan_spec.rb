require "spec_helper"
require "rails/hyperdrive/install_plan"

RSpec.describe Rails::Hyperdrive::InstallPlan do
  def skill(name:, source:, support_files: [])
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :skill, source_gem: source, path: "/x/#{source}/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n",
      spec_version: "1.0.0", support_files: support_files
    )
  end

  def guideline(name:, source:)
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{source}/#{name}.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  def agent(name:, source:)
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :agent, source_gem: source, path: "/x/#{source}/agents/#{name}.md",
      body: "---\nname: #{name}\ndescription: d\ntools: Read\n---\n\n# #{name}\n",
      spec_version: "1.0.0"
    )
  end

  def command(name:, source:, body: nil)
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: nil, target_gem: "*", versions: "*",
      artifact_type: :command, source_gem: source, path: "/x/#{source}/commands/#{name}.md",
      body: body || "# #{name}\n\nDo the thing.\n",
      spec_version: "1.0.0"
    )
  end

  it "places a uniquely-named artifact at its canonical path" do
    entry = described_class.build([skill(name: "jobs", source: "gem_a")]).entries.first

    expect(entry.dest).to eq(".claude/skills/jobs/SKILL.md")
    expect(entry.collision).to be false
  end

  it "postfixes every variant when several sources ship the same name" do
    plan = described_class.build([skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")]).entries

    expect(plan.map(&:dest)).to contain_exactly(
      ".claude/skills/jobs--gem_a/SKILL.md",
      ".claude/skills/jobs--gem_b/SKILL.md"
    )
  end

  it "keeps a skill's display name in step with its postfixed directory" do
    plan = described_class.build([skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")]).entries

    expect(plan.first.install_ready_body).to include("name: jobs--gem_a")
  end

  it "installs the skill body verbatim, frontmatter included" do
    entry = described_class.build([skill(name: "jobs", source: "gem_a")]).entries.first

    expect(entry.install_ready_body).to eq(entry.artifact.body)
    expect(entry.install_ready_body).to include("name: jobs")
  end

  it "does not collide a skill with a guideline of the same name" do
    plan = described_class.build([skill(name: "jobs", source: "gem_a"), guideline(name: "jobs", source: "gem_b")]).entries

    expect(plan.map(&:collision)).to all(be false)
  end

  it "strips a guideline's frontmatter from the install-ready body" do
    entry = described_class.build([guideline(name: "jobs", source: "gem_a")]).entries.first

    expect(entry.install_ready_body).to start_with("# jobs")
    expect(entry.source_label).to eq("gem_a@1.0.0")
  end

  describe "agents" do
    it "installs as a flat file with the body verbatim, frontmatter kept" do
      entry = described_class.build([agent(name: "reviewer", source: "gem_a")]).entries.first

      expect(entry.dest).to eq(".claude/agents/reviewer.md")
      expect(entry.install_ready_body).to eq(entry.artifact.body)
      expect(entry.support_files).to eq([])
    end

    it "postfixes the filename and the frontmatter name on a cross-source collision" do
      plan = described_class.build([agent(name: "reviewer", source: "gem_a"), agent(name: "reviewer", source: "gem_b")]).entries

      expect(plan.map(&:dest)).to contain_exactly(".claude/agents/reviewer--gem_a.md", ".claude/agents/reviewer--gem_b.md")
      expect(plan.find { |e| e.source_gem == "gem_a" }.install_ready_body).to include("name: reviewer--gem_a")
    end
  end

  describe "commands" do
    it "installs as a flat file with the body byte-identical" do
      entry = described_class.build([command(name: "analyze", source: "gem_a")]).entries.first

      expect(entry.dest).to eq(".claude/commands/analyze.md")
      expect(entry.install_ready_body).to eq(entry.artifact.body)
    end

    it "keeps frontmatter, never rewriting it on a collision" do
      body = "---\ndescription: d\n---\n\n# analyze\n"
      plan = described_class.build([
        command(name: "analyze", source: "gem_a", body: body),
        command(name: "analyze", source: "gem_b", body: body)
      ]).entries

      expect(plan.map(&:dest)).to contain_exactly(".claude/commands/analyze--gem_a.md", ".claude/commands/analyze--gem_b.md")
      expect(plan.map(&:install_ready_body)).to all(eq(body))
    end
  end

  describe "supporting files" do
    let(:support) do
      [
        { path: "references/deep.md", body: "raw reference bytes\n" },
        { path: "examples/sample.rb", body: "puts 1\n" }
      ]
    end

    it "re-roots each file under the skill's directory, preserving relative layout" do
      entry = described_class.build([skill(name: "jobs", source: "gem_a", support_files: support)]).entries.first

      expect(entry.support_files.map { |f| f[:dest] }).to contain_exactly(
        ".claude/skills/jobs/references/deep.md",
        ".claude/skills/jobs/examples/sample.rb"
      )
    end

    it "passes bodies through byte-identical" do
      entry = described_class.build([skill(name: "jobs", source: "gem_a", support_files: support)]).entries.first

      expect(entry.support_files.map { |f| f[:body] }).to eq(["raw reference bytes\n", "puts 1\n"])
    end

    it "lands under the postfixed directory on a cross-source collision" do
      plan = described_class.build([
        skill(name: "jobs", source: "gem_a", support_files: support),
        skill(name: "jobs", source: "gem_b")
      ]).entries

      entry = plan.find { |e| e.source_gem == "gem_a" }
      expect(entry.support_files.map { |f| f[:dest] }).to include(".claude/skills/jobs--gem_a/references/deep.md")
    end

    it "is empty for a guideline and for an artifact discovered without any" do
      expect(described_class.build([guideline(name: "jobs", source: "gem_a")]).entries.first.support_files).to eq([])
      expect(described_class.build([skill(name: "jobs", source: "gem_a")]).entries.first.support_files).to eq([])
    end
  end

  describe "a disabled name" do
    def lock(skills: [], guidelines: [], agents: [], commands: [])
      lists = { skill: skills, guideline: guidelines, agent: agents, command: commands }
      instance_double(Rails::Hyperdrive::LockFile).tap do |double|
        allow(double).to receive(:disabled?) { |type, name| lists.fetch(type, []).include?(name) }
      end
    end

    it "is left out of the plan and reported as disabled at its canonical path" do
      result = described_class.build(
        [skill(name: "jobs", source: "gem_a"), guideline(name: "auth", source: "gem_a")],
        lock: lock(skills: ["jobs"])
      )

      expect(result.entries.map(&:final_name)).to eq(["auth"])
      expect(result.disabled.map(&:final_name)).to eq(["jobs"])
      expect(result.disabled.map(&:dest)).to eq([".claude/skills/jobs/SKILL.md"])
    end

    it "only disables the artifact type it is listed under" do
      result = described_class.build([skill(name: "jobs", source: "gem_a")], lock: lock(guidelines: ["jobs"]))

      expect(result.entries.map(&:final_name)).to eq(["jobs"])
      expect(result.disabled).to be_empty
    end

    it "drops every variant of a collision, postfixed, when the shipped name is listed" do
      result = described_class.build(
        [skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")],
        lock: lock(skills: ["jobs"])
      )

      expect(result.entries).to be_empty
      expect(result.disabled.map(&:final_name)).to contain_exactly("jobs--gem_a", "jobs--gem_b")
    end

    it "drops one variant of a collision when the postfixed name is listed" do
      result = described_class.build(
        [skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")],
        lock: lock(skills: ["jobs--gem_a"])
      )

      expect(result.entries.map(&:dest)).to eq([".claude/skills/jobs--gem_b/SKILL.md"])
      expect(result.disabled.map(&:final_name)).to eq(["jobs--gem_a"])
    end

    it "drops the named source's artifact when the postfixed name outlives the collision" do
      result = described_class.build([skill(name: "jobs", source: "gem_a")], lock: lock(skills: ["jobs--gem_a"]))

      expect(result.entries).to be_empty
      expect(result.disabled.map(&:dest)).to eq([".claude/skills/jobs/SKILL.md"])
    end

    it "leaves another source's artifact of the same name alone" do
      result = described_class.build([skill(name: "jobs", source: "gem_b")], lock: lock(skills: ["jobs--gem_a"]))

      expect(result.entries.map(&:dest)).to eq([".claude/skills/jobs/SKILL.md"])
      expect(result.disabled).to be_empty
    end

    it "reports no casualties when no lock is given" do
      result = described_class.build([skill(name: "jobs", source: "gem_a")])

      expect(result.disabled).to be_empty
    end

    it "matches an installed path back to the name that disables it" do
      disabled = lock(skills: ["jobs"], guidelines: ["auth"])

      expect(described_class.disabled_dest?(disabled, :skill, ".claude/skills/jobs/SKILL.md")).to be true
      expect(described_class.disabled_dest?(disabled, :skill, ".claude/skills/jobs--gem_a/SKILL.md")).to be true
      expect(described_class.disabled_dest?(disabled, :guideline, ".claude/hyperdrive/guidelines/auth.md")).to be true
      expect(described_class.disabled_dest?(disabled, :skill, ".claude/skills/other/SKILL.md")).to be false
    end

    it "matches a canonical dest against the postfixed name once the installing gem is known" do
      disabled = lock(skills: ["jobs--gem_a"])
      dest = ".claude/skills/jobs/SKILL.md"

      expect(described_class.disabled_dest?(disabled, :skill, dest)).to be false
      expect(described_class.disabled_dest?(disabled, :skill, dest, source_gem: "gem_a")).to be true
      expect(described_class.disabled_dest?(disabled, :skill, dest, source_gem: "gem_b")).to be false
      expect(
        described_class.disabled_dest?(disabled, :skill_support, ".claude/skills/jobs/references/deep.md", source_gem: "gem_a")
      ).to be true
    end

    it "honors the base and the postfixed name for agents and commands alike" do
      result = described_class.build(
        [agent(name: "reviewer", source: "gem_a"), command(name: "analyze", source: "gem_a")],
        lock: lock(agents: ["reviewer"], commands: ["analyze--gem_a"])
      )

      expect(result.entries).to be_empty
      expect(result.disabled.map(&:dest))
        .to contain_exactly(".claude/agents/reviewer.md", ".claude/commands/analyze.md")
    end

    it "matches an installed agent or command path back to the name that disables it" do
      disabled = lock(agents: ["reviewer"], commands: ["analyze--gem_a"])

      expect(described_class.disabled_dest?(disabled, :agent, ".claude/agents/reviewer.md")).to be true
      expect(described_class.disabled_dest?(disabled, :agent, ".claude/agents/reviewer--gem_b.md")).to be true
      expect(described_class.disabled_dest?(disabled, :command, ".claude/commands/analyze.md")).to be false
      expect(
        described_class.disabled_dest?(disabled, :command, ".claude/commands/analyze.md", source_gem: "gem_a")
      ).to be true
    end

    it "disables a supporting file through its owning skill's name" do
      disabled = lock(skills: ["jobs"])

      expect(described_class.disabled_dest?(disabled, :skill_support, ".claude/skills/jobs/references/deep.md")).to be true
      expect(described_class.disabled_dest?(disabled, :skill_support, ".claude/skills/jobs--gem_a/references/deep.md")).to be true
      expect(described_class.disabled_dest?(disabled, :skill_support, ".claude/skills/other/references/deep.md")).to be false
    end
  end
end
