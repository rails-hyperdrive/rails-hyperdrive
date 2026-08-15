require "spec_helper"
require "rails/hyperdrive/ancestor_locator"
require "rails/hyperdrive/lock_file"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::AncestorLocator do
  let(:home) { Dir.mktmpdir("hyperdrive-gem-home") }

  after { FileUtils.remove_entry(home) if File.directory?(home) }

  def ship(relpath, body, gem_name: "rails-hyperdrive-x", version: "1.0.0")
    file = File.join(home, "gems", "#{gem_name}-#{version}", relpath)
    FileUtils.mkdir_p(File.dirname(file))
    File.binwrite(file, body)
  end

  def lock_entry(kind:, sha:, gem_name: "rails-hyperdrive-x", version: "1.0.0")
    Rails::Hyperdrive::LockFile::Entry.new(
      path: "irrelevant", kind: kind, source_gem: gem_name, source_version: version,
      source_sha: sha, installed_at: "2026-01-01T00:00:00Z"
    )
  end

  def sha(body) = Rails::Hyperdrive::DriftVerdict.body_sha(body)

  let(:guideline_relpath) { "lib/rails-hyperdrive-x/hyperdrive/guidelines/auth.md" }
  let(:guideline_shipped) { "---\nname: auth\ngem: \"*\"\nversions: \"*\"\n---\n\n# Auth\n\nrule.\n" }
  let(:guideline_ready)   { "# Auth\n\nrule.\n" }

  it "reconstructs a guideline's install-ready body when the sha gate passes" do
    ship(guideline_relpath, guideline_shipped)

    body = described_class.locate(
      kind: "guideline", relpath: guideline_relpath,
      lock_entry: lock_entry(kind: "guideline", sha: sha(guideline_ready)),
      gem_paths: [home]
    )

    expect(body).to eq(guideline_ready)
  end

  it "returns nil when the rebuilt body fails the sha gate" do
    ship(guideline_relpath, guideline_shipped)

    body = described_class.locate(
      kind: "guideline", relpath: guideline_relpath,
      lock_entry: lock_entry(kind: "guideline", sha: sha("something else entirely")),
      gem_paths: [home]
    )

    expect(body).to be_nil
  end

  it "returns nil when the locked version's gem directory is absent" do
    body = described_class.locate(
      kind: "guideline", relpath: guideline_relpath,
      lock_entry: lock_entry(kind: "guideline", sha: sha(guideline_ready), version: "9.9.9"),
      gem_paths: [home]
    )

    expect(body).to be_nil
  end

  it "scans later gem-path entries when an earlier one fails the gate" do
    other = Dir.mktmpdir("hyperdrive-gem-home-2")
    begin
      file = File.join(other, "gems", "rails-hyperdrive-x-1.0.0", guideline_relpath)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "drifted content\n")
      ship(guideline_relpath, guideline_shipped)

      body = described_class.locate(
        kind: "guideline", relpath: guideline_relpath,
        lock_entry: lock_entry(kind: "guideline", sha: sha(guideline_ready)),
        gem_paths: [other, home]
      )

      expect(body).to eq(guideline_ready)
    ensure
      FileUtils.remove_entry(other)
    end
  end

  it "renders and gates the .md.erb twin when the plain file is absent" do
    relpath = "lib/rails-hyperdrive-x/hyperdrive/skills/jobs/references/notes.md"
    ship("#{relpath}.erb", "sidekiq <%= gem_version('sidekiq') %>\n")
    rendered = "sidekiq 7.2.0\n"

    body = described_class.locate(
      kind: "skill_support", relpath: relpath,
      lock_entry: lock_entry(kind: "skill_support", sha: sha(rendered)),
      gem_paths: [home], resolved: { "sidekiq" => Gem::Version.new("7.2.0") }
    )

    expect(body).to eq(rendered)
  end

  it "reconstructs a template-paired skill's ancestor from the SKILL.md.erb twin" do
    relpath = "lib/rails-hyperdrive-x/hyperdrive/skills/jobs/SKILL.md"
    ship("#{relpath}.erb",
      "---\nname: jobs\ndescription: d\n---\n\n# jobs <%= gem_version('sidekiq') %>\n")
    installed = "---\nname: jobs\ndescription: d\n---\n\n# jobs 7.2.0\n"

    body = described_class.locate(
      kind: "skill", relpath: relpath,
      lock_entry: lock_entry(kind: "skill", sha: sha(installed)),
      gem_paths: [home], resolved: { "sidekiq" => Gem::Version.new("7.2.0") }
    )

    expect(body).to eq(installed)
  end

  it "rebuilds a collision-postfixed skill: name: rewritten to the final name" do
    relpath = "lib/rails-hyperdrive-x/hyperdrive/skills/jobs/SKILL.md"
    shipped = "---\nname: jobs\ndescription: d\n---\n\n# jobs\n"
    installed = "---\nname: jobs--rails-hyperdrive-x\ndescription: d\n---\n\n# jobs\n"
    ship(relpath, shipped)

    body = described_class.locate(
      kind: "skill", relpath: relpath, final_name: "jobs--rails-hyperdrive-x",
      lock_entry: lock_entry(kind: "skill", sha: sha(installed)),
      gem_paths: [home]
    )

    expect(body).to eq(installed)
  end

  it "reads a supporting file as raw bytes" do
    relpath = "lib/rails-hyperdrive-x/hyperdrive/skills/jobs/examples/blob.bin"
    raw = (+"\x00\x01\xffbytes").force_encoding(Encoding::BINARY)
    ship(relpath, raw)

    body = described_class.locate(
      kind: "skill_support", relpath: relpath,
      lock_entry: lock_entry(kind: "skill_support", sha: sha(raw)),
      gem_paths: [home]
    )

    expect(body.b).to eq(raw)
  end

  it "returns nil for a nil or incomplete lock entry" do
    expect(described_class.locate(kind: "guideline", relpath: guideline_relpath, lock_entry: nil, gem_paths: [home]))
      .to be_nil
    expect(described_class.locate(
      kind: "guideline", relpath: guideline_relpath,
      lock_entry: lock_entry(kind: "guideline", sha: sha(guideline_ready), version: nil),
      gem_paths: [home]
    )).to be_nil
  end

  it "returns nil instead of raising when anything blows up" do
    ship(guideline_relpath, guideline_shipped)
    allow(Rails::Hyperdrive::DriftVerdict).to receive(:body_sha).and_raise(RuntimeError, "boom")

    expect(described_class.locate(
      kind: "guideline", relpath: guideline_relpath,
      lock_entry: lock_entry(kind: "guideline", sha: "whatever"),
      gem_paths: [home]
    )).to be_nil
  end
end
