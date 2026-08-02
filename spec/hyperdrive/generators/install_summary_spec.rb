require "spec_helper"
require "generators/hyperdrive/install_summary"
require "rails/hyperdrive/lock_file"

RSpec.describe Rails::Generators::Hyperdrive::InstallSummary do
  def entry(path:, kind:, source_gem:, source_version: "1.0.0")
    Rails::Hyperdrive::LockFile::Entry.new(
      path: path, kind: kind, source_gem: source_gem, source_version: source_version,
      source_sha: "sha", installed_at: "2026-01-01T00:00:00Z"
    )
  end

  def skill(name, source:, version: "1.0.0")
    entry(path: ".claude/skills/#{name}/SKILL.md", kind: "skill", source_gem: source, source_version: version)
  end

  def skill_support(name, relpath, source:, version: "1.0.0")
    entry(path: ".claude/skills/#{name}/#{relpath}", kind: "skill_support", source_gem: source, source_version: version)
  end

  def guideline(name, source:, version: "1.0.0")
    entry(path: ".claude/hyperdrive/guidelines/#{name}.md", kind: "guideline", source_gem: source, source_version: version)
  end

  def internal_guideline(name, version: "0.9.9")
    entry(path: ".claude/hyperdrive/guidelines/#{name}.md", kind: "guideline", source_gem: "internal", source_version: version)
  end

  it "returns nothing for an empty lock" do
    expect(described_class.lines([])).to eq([])
  end

  describe "grouping" do
    it "groups each artifact under its source, skills before guidelines" do
      lines = described_class.lines([
        guideline("jobs-sidekiq", source: "rails-hyperdrive-sidekiq"),
        skill("sidekiq-idempotency", source: "rails-hyperdrive-sidekiq"),
        skill("component-authoring", source: "rails-hyperdrive-view-component")
      ])

      expect(lines).to include("    rails-hyperdrive-sidekiq@1.0.0")
      expect(lines).to include("    rails-hyperdrive-view-component@1.0.0")
      expect(lines.index("      skill      sidekiq-idempotency"))
        .to be < lines.index("      guideline  jobs-sidekiq")
    end

    it "puts the internal group last regardless of alphabetical order" do
      lines = described_class.lines([
        skill("z1", source: "zeta-gem"),
        internal_guideline("legacy"),
        skill("a1", source: "alpha-gem")
      ])

      sources = lines.grep(/\A {4}\S/)
      expect(sources).to eq(["    alpha-gem@1.0.0", "    zeta-gem@1.0.0", "    internal@0.9.9"])
    end

    it "lists both variants of a cross-source collision under their own sources" do
      lines = described_class.lines([
        skill("dup--rails-hyperdrive-a", source: "rails-hyperdrive-a"),
        skill("dup--rails-hyperdrive-b", source: "rails-hyperdrive-b")
      ])

      expect(lines).to eq([
        "  Installed 2 skills, 0 guidelines",
        "",
        "    rails-hyperdrive-a@1.0.0",
        "      skill      dup--rails-hyperdrive-a",
        "    rails-hyperdrive-b@1.0.0",
        "      skill      dup--rails-hyperdrive-b"
      ])
    end

    it "lists entries the pipeline skipped or carried as orphans all the same" do
      lines = described_class.lines([
        guideline("locally-edited", source: "rails-hyperdrive-a"),
        skill("orphaned", source: "rails-hyperdrive-gone", version: "0.4.0")
      ])

      expect(lines).to include("      guideline  locally-edited")
      expect(lines).to include("    rails-hyperdrive-gone@0.4.0")
      expect(lines).to include("      skill      orphaned")
    end
  end

  describe "supporting files" do
    it "collapses them into a (+N files) suffix on the owning skill" do
      lines = described_class.lines([
        skill("sk", source: "rails-hyperdrive-a"),
        skill_support("sk", "ref/a.md", source: "rails-hyperdrive-a"),
        skill_support("sk", "nested/deep/b.txt", source: "rails-hyperdrive-a")
      ])

      expect(lines).to eq([
        "  Installed 1 skill, 0 guidelines",
        "",
        "    rails-hyperdrive-a@1.0.0",
        "      skill      sk (+2 files)"
      ])
    end

    it "singularizes a lone supporting file" do
      lines = described_class.lines([
        skill("sk", source: "rails-hyperdrive-a"),
        skill_support("sk", "ref/a.md", source: "rails-hyperdrive-a")
      ])

      expect(lines).to include("      skill      sk (+1 file)")
    end

    it "counts them against the installed directory even when SKILL.md records an older source" do
      lines = described_class.lines([
        skill("sk", source: "rails-hyperdrive-a", version: "1.0.0"),
        skill_support("sk", "ref/a.md", source: "rails-hyperdrive-a", version: "2.0.0")
      ])

      expect(lines).to include("      skill      sk (+1 file)")
    end
  end

  describe "the counts line" do
    it "singularizes and pluralizes each noun" do
      expect(described_class.lines([skill("sk", source: "a")]).first)
        .to eq("  Installed 1 skill, 0 guidelines")
      expect(described_class.lines([guideline("g1", source: "a"), guideline("g2", source: "a")]).first)
        .to eq("  Installed 0 skills, 2 guidelines")
    end
  end

  it "degrades an unknown kind from a hand-edited lock to the filename, listed last" do
    lines = described_class.lines([
      skill("sk", source: "rails-hyperdrive-a"),
      entry(path: ".claude/hyperdrive/notes/whatever.md", kind: "mystery", source_gem: "rails-hyperdrive-a")
    ])

    expect(lines.last).to eq("      mystery    whatever")
  end

  it "matches the recorded multi-source output byte for byte" do
    entries = [
      skill("sidekiq-idempotency", source: "rails-hyperdrive-sidekiq"),
      skill_support("sidekiq-idempotency", "ref/a.md", source: "rails-hyperdrive-sidekiq"),
      skill_support("sidekiq-idempotency", "ref/b.md", source: "rails-hyperdrive-sidekiq"),
      guideline("jobs-sidekiq", source: "rails-hyperdrive-sidekiq"),
      skill("component-authoring", source: "rails-hyperdrive-view-component", version: "2.1.0")
    ]
    fixture = File.expand_path("../../fixtures/install_summary/multi_source.txt", __dir__)

    expect(described_class.lines(entries).join("\n") + "\n").to eq(File.read(fixture))
  end
end
