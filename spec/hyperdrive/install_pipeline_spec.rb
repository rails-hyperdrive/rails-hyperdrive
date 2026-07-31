require "spec_helper"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::InstallPipeline do
  Artifact = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact unless defined?(Artifact)

  let(:root) { Dir.mktmpdir("hyperdrive-pipeline") }
  let(:stack) { { rails: { version: "8.0.0", major: 8 }, ruby: { version: "3.3.0" }, database: { adapter: "sqlite3" } } }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def guideline(name:, source: "rails-hyperdrive-x", body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  def skill(name:, source: "rails-hyperdrive-x", support_files: [])
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n",
      spec_version: "1.0.0", support_files: support_files
    )
  end

  def run(mode: :preserve, artifacts: [])
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root),
      artifacts: artifacts,
      stack: stack,
      mode: mode
    ).call
  end

  def run_reporting(mode: :preserve, artifacts: [])
    io = StringIO.new
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root, io: io),
      artifacts: artifacts,
      stack: stack,
      mode: mode
    ).call
    io.string
  end

  def read(rel) = File.read(File.join(root, rel))
  def exist?(rel) = File.exist?(File.join(root, rel))

  describe "running without a booted Rails application" do
    before { allow(::Rails).to receive(:root).and_return(nil) }

    it "installs a full content set into the given root" do
      run(artifacts: [guideline(name: "auth-pundit"), skill(name: "jobs-sidekiq")])

      expect(exist?(".claude/hyperdrive/stack.md")).to be true
      expect(exist?(".claude/skills/jobs-sidekiq/SKILL.md")).to be true
      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to start_with("<!-- hyperdrive: source=rails-hyperdrive-x@1.0.0")
      expect(read(".claude/hyperdrive/index.md")).to include("@guidelines/auth-pundit.md")
      expect(read("CLAUDE.md")).to include("@.claude/hyperdrive/index.md")
      expect(read(".hyperdrive/lock.yml")).to include("artifact: guideline")
    end

    it "reports what it wrote" do
      result = run(artifacts: [guideline(name: "auth-pundit")])
      expect(result.installed).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(result.installed).to include(".claude/hyperdrive/stack.md")
    end
  end

  describe "additive mode" do
    let(:existing) { guideline(name: "auth-pundit") }

    before { run(artifacts: [existing]) }

    it "installs an artifact the lockfile does not record yet" do
      result = run(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      expect(exist?(".claude/hyperdrive/guidelines/jobs-sidekiq.md")).to be true
      expect(result.installed).to eq([".claude/hyperdrive/guidelines/jobs-sidekiq.md"])
    end

    it "adds the new guideline to index.md so it is actually loaded" do
      run(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      index = read(".claude/hyperdrive/index.md")
      expect(index).to include("@guidelines/jobs-sidekiq.md")
      expect(index).to include("@guidelines/auth-pundit.md")
      expect(index.lines.first.strip).to eq("@stack.md")
    end

    it "leaves a locally-edited file alone" do
      path = ".claude/hyperdrive/guidelines/auth-pundit.md"
      File.write(File.join(root, path), read(path) + "\nMY LOCAL EDIT\n")

      result = run(mode: :additive, artifacts: [existing])

      expect(read(path)).to include("MY LOCAL EDIT")
      expect(result.installed).to be_empty
    end

    it "leaves an upgraded artifact alone rather than overwriting it" do
      upgraded = guideline(
        name: "auth-pundit",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# auth-pundit\n\nUPGRADED.\n"
      )

      result = run(mode: :additive, artifacts: [upgraded])

      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to include("rule.")
      expect(result.installed).to be_empty
      expect(result.skipped).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
    end

    it "does not resurrect a tracked file the user deleted" do
      path = ".claude/hyperdrive/guidelines/auth-pundit.md"
      File.delete(File.join(root, path))

      run(mode: :additive, artifacts: [existing])

      expect(exist?(path)).to be false
    end

    it "does not re-add an index.md line the user removed" do
      File.write(File.join(root, ".claude/hyperdrive/index.md"), "@stack.md\n")

      run(mode: :additive, artifacts: [existing])

      expect(read(".claude/hyperdrive/index.md")).not_to include("@guidelines/auth-pundit.md")
    end

    it "prints no eager footprint" do
      out = run_reporting(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      expect(out).not_to include("always in context")
    end

    it "does not touch CLAUDE.md" do
      File.write(File.join(root, "CLAUDE.md"), "# mine only\n")

      run(mode: :additive, artifacts: [existing, guideline(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])

      expect(read("CLAUDE.md")).to eq("# mine only\n")
    end

    it "keeps carrying entries whose source gem left the bundle" do
      run(mode: :additive, artifacts: [])

      expect(exist?(".claude/hyperdrive/guidelines/auth-pundit.md")).to be true
      expect(read(".hyperdrive/lock.yml")).to include("auth-pundit")
    end
  end

  describe "multi-file skills" do
    let(:support) do
      [
        { path: "references/deep.md", body: "# Deep\n\nraw bytes, no header.\n" },
        { path: "examples/sample.rb", body: "puts 1\n" }
      ]
    end
    let(:multi) { skill(name: "jobs", support_files: support) }

    it "installs the supporting tree byte-identical, with no audit header" do
      run(artifacts: [multi])

      expect(read(".claude/skills/jobs/references/deep.md")).to eq("# Deep\n\nraw bytes, no header.\n")
      expect(read(".claude/skills/jobs/examples/sample.rb")).to eq("puts 1\n")
    end

    it "locks each supporting file under the skill_support kind with its own sha" do
      run(artifacts: [multi])

      lock = YAML.safe_load(read(".hyperdrive/lock.yml"))
      entries = lock["files"].select { |e| e["artifact"] == "skill_support" }
      expect(entries.map { |e| e["path"] }).to contain_exactly(
        ".claude/skills/jobs/references/deep.md",
        ".claude/skills/jobs/examples/sample.rb"
      )
      deep = entries.find { |e| e["path"].end_with?("deep.md") }
      expect(deep["source_sha"]).to eq(Digest::SHA256.hexdigest("# Deep\n\nraw bytes, no header.\n"))
      expect(deep["source"]).to eq("rails-hyperdrive-x@1.0.0")
    end

    describe "gated delete of a dropped supporting file" do
      before { run(artifacts: [multi]) }

      let(:upgraded) { skill(name: "jobs", support_files: support.first(1)) }

      it "removes an unedited copy and prunes the emptied subdirectory" do
        result = run(artifacts: [upgraded])

        expect(exist?(".claude/skills/jobs/examples/sample.rb")).to be false
        expect(exist?(".claude/skills/jobs/examples")).to be false
        expect(exist?(".claude/skills/jobs/references/deep.md")).to be true
        expect(result.removed).to include(".claude/skills/jobs/examples/sample.rb")
        expect(read(".hyperdrive/lock.yml")).not_to include("examples/sample.rb")
      end

      it "warns and leaves an edited copy, carrying its lock entry" do
        File.write(File.join(root, ".claude/skills/jobs/examples/sample.rb"), "puts 2 # mine\n")

        result = run(artifacts: [upgraded])

        expect(read(".claude/skills/jobs/examples/sample.rb")).to eq("puts 2 # mine\n")
        expect(result.skipped).to include(".claude/skills/jobs/examples/sample.rb")
        expect(read(".hyperdrive/lock.yml")).to include("examples/sample.rb")
      end

      it "never removes anything in additive mode" do
        result = run(mode: :additive, artifacts: [upgraded])

        expect(exist?(".claude/skills/jobs/examples/sample.rb")).to be true
        expect(result.removed).to be_empty
      end
    end

    describe "additive mode" do
      before { run(artifacts: [multi]) }

      it "installs a supporting file the lock does not record yet" do
        grown = skill(name: "jobs", support_files: support + [{ path: "references/new.md", body: "new\n" }])

        result = run(mode: :additive, artifacts: [grown])

        expect(read(".claude/skills/jobs/references/new.md")).to eq("new\n")
        expect(result.installed).to eq([".claude/skills/jobs/references/new.md"])
      end

      it "does not resurrect a lock-tracked supporting file the user deleted" do
        File.delete(File.join(root, ".claude/skills/jobs/examples/sample.rb"))

        run(mode: :additive, artifacts: [multi])

        expect(exist?(".claude/skills/jobs/examples/sample.rb")).to be false
      end
    end

    it "carries a supporting file as an orphan when the whole source gem is gone" do
      run(artifacts: [multi])

      result = run(artifacts: [])

      expect(result.orphaned).to include(".claude/skills/jobs/references/deep.md")
      expect(exist?(".claude/skills/jobs/references/deep.md")).to be true
      expect(read(".hyperdrive/lock.yml")).to include("references/deep.md")
    end
  end

  describe "artifacts dropped by the disabled list" do
    def disable(key, *names)
      lock = File.join(root, ".hyperdrive/lock.yml")
      FileUtils.mkdir_p(File.dirname(lock))
      data = File.exist?(lock) ? YAML.safe_load(File.read(lock)) : {}
      (data["disabled"] ||= {})[key] = names
      File.write(lock, data.to_yaml)
    end

    it "reports each one against the file that lists it" do
      disable("skills", "jobs")

      out = run_reporting(artifacts: [skill(name: "jobs"), guideline(name: "auth-pundit")])

      expect(out).to include("skill 'jobs' (listed in .hyperdrive/lock.yml)")
      expect(exist?(".claude/skills/jobs/SKILL.md")).to be false
      expect(exist?(".claude/hyperdrive/guidelines/auth-pundit.md")).to be true
    end

    it "names both variants of a collision by their postfixed names" do
      disable("skills", "jobs")

      out = run_reporting(artifacts: [skill(name: "jobs", source: "gem_a"), skill(name: "jobs", source: "gem_b")])

      expect(out).to include("skill 'jobs--gem_a'", "skill 'jobs--gem_b'")
    end

    it "stays quiet when nothing is listed" do
      expect(run_reporting(artifacts: [skill(name: "jobs")])).not_to include("disabled")
    end
  end

  describe "gitignored install destination" do
    before { system("git", "init", "--quiet", root, out: File::NULL, err: File::NULL) }

    it "warns when the destinations are ignored" do
      File.write(File.join(root, ".gitignore"), ".claude/\n")

      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to include(".claude/skills", ".claude/hyperdrive")
      expect(out).to match(/gitignored/)
      expect(out).to match(/unreviewed/)
    end

    it "stays quiet when they are tracked" do
      expect(run_reporting(artifacts: [guideline(name: "auth-pundit")])).not_to match(/gitignored/)
    end

    it "stays quiet in additive mode" do
      File.write(File.join(root, ".gitignore"), ".claude/\n")
      run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(run_reporting(mode: :additive, artifacts: [])).not_to match(/gitignored/)
    end
  end

  describe "generated output" do
    it "writes index.md and CLAUDE.md byte-for-byte" do
      run(artifacts: [guideline(name: "jobs-sidekiq"), guideline(name: "auth-pundit"), skill(name: "s1")])

      expect(read(".claude/hyperdrive/index.md"))
        .to eq("@stack.md\n@guidelines/auth-pundit.md\n@guidelines/jobs-sidekiq.md\n")
      expect(read("CLAUDE.md")).to eq(
        "<!-- AI instructions for this project. Managed content lives in .claude/hyperdrive/. -->\n\n" \
        "@.claude/hyperdrive/index.md\n"
      )
    end

    it "prints the eager footprint" do
      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to match(/eager\s+1 guideline\(s\) \+ stack\.md, ~\d+ tokens always in context/)
    end

    it "leaves index.md alone on a re-run" do
      run(artifacts: [guideline(name: "auth-pundit")])
      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to match(%r{unchanged\s+\.claude/hyperdrive/index\.md})
    end
  end

  it "rejects an unknown mode" do
    expect {
      described_class.new(root: root, shell: nil, artifacts: [], stack: stack, mode: :clobber)
    }.to raise_error(ArgumentError, /clobber/)
  end
end
