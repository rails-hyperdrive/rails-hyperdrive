require "spec_helper"
require "rails/hyperdrive/install_plan"

RSpec.describe Rails::Hyperdrive::InstallPlan do
  def skill(name:, source:)
    Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :skill, source_gem: source, path: "/x/#{source}/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n",
      spec_version: "1.0.0"
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

  it "places a uniquely-named artifact at its canonical path" do
    entry = described_class.build([skill(name: "jobs", source: "gem_a")]).first

    expect(entry.dest).to eq(".claude/skills/jobs/SKILL.md")
    expect(entry.collision).to be false
  end

  it "postfixes every variant when several sources ship the same name" do
    plan = described_class.build([skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")])

    expect(plan.map(&:dest)).to contain_exactly(
      ".claude/skills/jobs--gem_a/SKILL.md",
      ".claude/skills/jobs--gem_b/SKILL.md"
    )
  end

  it "keeps a skill's display name in step with its postfixed directory" do
    plan = described_class.build([skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")])

    expect(plan.first.install_ready_body).to include("name: jobs--gem_a")
  end

  it "does not collide a skill with a guideline of the same name" do
    plan = described_class.build([skill(name: "jobs", source: "gem_a"), guideline(name: "jobs", source: "gem_b")])

    expect(plan.map(&:collision)).to all(be false)
  end

  it "strips a guideline's frontmatter from the install-ready body" do
    entry = described_class.build([guideline(name: "jobs", source: "gem_a")]).first

    expect(entry.install_ready_body).to start_with("# jobs")
    expect(entry.source_label).to eq("gem_a@1.0.0")
  end
end
