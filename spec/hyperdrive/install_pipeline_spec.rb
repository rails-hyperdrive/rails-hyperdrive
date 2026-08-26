require "spec_helper"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::InstallPipeline do
  Artifact = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact unless defined?(Artifact)

  let(:root) { Dir.mktmpdir("hyperdrive-pipeline") }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def guideline(name:, source: "rails-hyperdrive-x", body: nil, version: "1.0.0")
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: version
    )
  end

  def skill(name:, source: "rails-hyperdrive-x", support_files: [], version: "1.0.0")
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name}\n",
      spec_version: version, support_files: support_files
    )
  end

  def agent(name:, source: "rails-hyperdrive-x", body: nil, version: "1.0.0")
    Artifact.new(
      name: name, description: "d", target_gem: "*", versions: "*",
      artifact_type: :agent, source_gem: source, path: "/x/agents/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n",
      spec_version: version
    )
  end

  def command(name:, source: "rails-hyperdrive-x", body: nil, version: "1.0.0")
    Artifact.new(
      name: name, description: nil, target_gem: "*", versions: "*",
      artifact_type: :command, source_gem: source, path: "/x/commands/#{name}.md",
      body: body || "# #{name}\n\nDo the thing.\n",
      spec_version: version
    )
  end

  def discovery_report(notices: [], warnings: [], skips: [], bundled_gems: [], skipped_gems: [])
    Rails::Hyperdrive::BundlerArtifactDiscovery::Report.new(
      notices: notices, warnings: warnings + skips, skips: skips,
      bundled_gems: bundled_gems, skipped_gems: skipped_gems
    )
  end

  def run(mode: :preserve, artifacts: [], bundled_gems: [], skipped_gems: [])
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root),
      artifacts: artifacts,
      mode: mode,
      report: discovery_report(bundled_gems: bundled_gems, skipped_gems: skipped_gems)
    ).call
  end

  def run_reporting(mode: :preserve, artifacts: [], notices: [], warnings: [], skips: [],
                    bundled_gems: [], skipped_gems: [])
    io = StringIO.new
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root, io: io),
      artifacts: artifacts,
      mode: mode,
      report: discovery_report(notices: notices, warnings: warnings, skips: skips,
        bundled_gems: bundled_gems, skipped_gems: skipped_gems)
    ).call
    io.string
  end

  def read(rel) = File.read(File.join(root, rel))
  def exist?(rel) = File.exist?(File.join(root, rel))

  describe "running without a booted Rails application" do
    before { allow(::Rails).to receive(:root).and_return(nil) }

    it "installs a full content set into the given root" do
      run(artifacts: [guideline(name: "auth-pundit"), skill(name: "jobs-sidekiq")])

      expect(exist?(".claude/skills/jobs-sidekiq/SKILL.md")).to be true
      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to start_with("# auth-pundit")
      expect(read(".claude/hyperdrive/index.md")).to include("@guidelines/auth-pundit.md")
      expect(read("CLAUDE.md")).to include("@.claude/hyperdrive/index.md")
      expect(read(".hyperdrive/lock.yml")).to include("artifact: guideline")
    end

    it "reports what it wrote" do
      result = run(artifacts: [guideline(name: "auth-pundit")])
      expect(result.installed).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
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
      File.write(File.join(root, ".claude/hyperdrive/index.md"), "")

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

    it "installs the supporting tree byte-identical" do
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

  describe "skill ancestry relpaths" do
    let(:locator) { Rails::Hyperdrive::AncestorLocator }

    def skill_at(path:, source_root: "/gem", support_root: nil, version: "1.0.0", edition: "",
                 support_relpath: nil)
      Artifact.new(
        name: "jobs", description: "d", target_gem: "*", versions: "*",
        artifact_type: :skill, source_gem: "rails-hyperdrive-x", path: path,
        body: "---\nname: jobs\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# jobs\n#{edition}",
        spec_version: version, source_root: source_root, support_root: support_root,
        support_files: [
          { path: "references/deep.md", body: "deep #{edition}\n", source_relpath: support_relpath }
        ]
      )
    end

    def edit_installed_and_merge(v1, v2)
      run(artifacts: [v1])
      File.write(File.join(root, ".claude/skills/jobs/SKILL.md"), "edited\n")
      File.write(File.join(root, ".claude/skills/jobs/references/deep.md"), "edited\n")
      allow(locator).to receive(:locate).and_return(nil)
      run(mode: :merge, artifacts: [v2])
    end

    it "locates a paired skill's ancestor template-side, its supporting files content-side" do
      v1 = skill_at(path: "/gem/lib/x/hyperdrive/skills/jobs/SKILL.md.erb", support_root: "/gem/skills/jobs")
      v2 = skill_at(path: "/gem/lib/x/hyperdrive/skills/jobs/SKILL.md.erb", support_root: "/gem/skills/jobs",
        version: "2.0.0", edition: "v2")

      edit_installed_and_merge(v1, v2)

      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "skill", relpath: "lib/x/hyperdrive/skills/jobs/SKILL.md"))
      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "skill_support", relpath: "skills/jobs/references/deep.md"))
    end

    it "locates a template-origin supporting file at the relpath discovery recorded" do
      relpath = "lib/x/hyperdrive/skills/jobs/references/deep.md"
      v1 = skill_at(path: "/gem/lib/x/hyperdrive/skills/jobs/SKILL.md.erb", support_root: "/gem/skills/jobs",
        support_relpath: relpath)
      v2 = skill_at(path: "/gem/lib/x/hyperdrive/skills/jobs/SKILL.md.erb", support_root: "/gem/skills/jobs",
        version: "2.0.0", edition: "v2", support_relpath: relpath)

      edit_installed_and_merge(v1, v2)

      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "skill_support", relpath: relpath))
    end

    it "keeps today's relpaths for an unpaired artifact" do
      path = "/gem/lib/x/hyperdrive/skills/jobs/SKILL.md"
      v1 = skill_at(path: path, support_root: "/gem/lib/x/hyperdrive/skills/jobs")
      v2 = skill_at(path: path, support_root: "/gem/lib/x/hyperdrive/skills/jobs", version: "2.0.0", edition: "v2")

      edit_installed_and_merge(v1, v2)

      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "skill", relpath: "lib/x/hyperdrive/skills/jobs/SKILL.md"))
      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "skill_support", relpath: "lib/x/hyperdrive/skills/jobs/references/deep.md"))
    end

    it "falls back to the definition file's directory when support_root is absent" do
      path = "/gem/lib/x/hyperdrive/skills/jobs/SKILL.md"
      edit_installed_and_merge(skill_at(path: path), skill_at(path: path, version: "2.0.0", edition: "v2"))

      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "skill_support", relpath: "lib/x/hyperdrive/skills/jobs/references/deep.md"))
    end
  end

  describe "flat ERB ancestry relpaths" do
    let(:locator) { Rails::Hyperdrive::AncestorLocator }

    def templated_guideline(version:, edition: "")
      Artifact.new(
        name: "jobs", description: "d", target_gem: "*", versions: "*",
        artifact_type: :guideline, source_gem: "rails-hyperdrive-x",
        path: "/gem/lib/x/hyperdrive/guidelines/jobs.md.erb",
        body: "---\nname: jobs\ndescription: d\n---\n\n# jobs\n#{edition}",
        spec_version: version, source_root: "/gem"
      )
    end

    it "looks the ancestor up at the .erb-normalized relpath" do
      run(artifacts: [templated_guideline(version: "1.0.0")])
      File.write(File.join(root, ".claude/hyperdrive/guidelines/jobs.md"), "edited\n")
      allow(locator).to receive(:locate).and_return(nil)

      run(mode: :merge, artifacts: [templated_guideline(version: "2.0.0", edition: "v2")])

      expect(locator).to have_received(:locate)
        .with(hash_including(kind: "guideline", relpath: "lib/x/hyperdrive/guidelines/jobs.md"))
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

    describe "one listed after it was already installed" do
      before { run(artifacts: [skill(name: "jobs")]) }

      it "removes the pristine file and the sidecar that belonged to it" do
        File.write(File.join(root, ".claude/skills/jobs/SKILL.md.new"), read(".claude/skills/jobs/SKILL.md"))
        disable("skills", "jobs")

        result = run(artifacts: [skill(name: "jobs")])

        expect(exist?(".claude/skills/jobs")).to be false
        expect(result.removed).to include(".claude/skills/jobs/SKILL.md", ".claude/skills/jobs/SKILL.md.new")
      end

      it "warns about an edited copy, leaves it, and carries its lock entry" do
        File.write(File.join(root, ".claude/skills/jobs/SKILL.md"), "mine\n")
        disable("skills", "jobs")

        out = run_reporting(artifacts: [skill(name: "jobs")])

        expect(read(".claude/skills/jobs/SKILL.md")).to eq("mine\n")
        expect(out).to include(".claude/skills/jobs/SKILL.md (disabled but locally modified; delete it by hand)")
        expect(read(".hyperdrive/lock.yml")).to include(".claude/skills/jobs/SKILL.md")
      end
    end
  end

  describe "agents and commands" do
    def lock_yaml = YAML.safe_load(read(".hyperdrive/lock.yml"))

    it "installs both as flat files with their own lock kinds" do
      run(artifacts: [agent(name: "reviewer"), command(name: "analyze")])

      expect(read(".claude/agents/reviewer.md")).to include("name: reviewer")
      expect(read(".claude/commands/analyze.md")).to eq("# analyze\n\nDo the thing.\n")
      expect(lock_yaml["files"].map { |f| f["artifact"] }).to contain_exactly("agent", "command")
    end

    it "arms no eager chain" do
      run(artifacts: [agent(name: "reviewer"), command(name: "analyze")])

      expect(exist?(".claude/hyperdrive/index.md")).to be false
      expect(exist?("CLAUDE.md")).to be false
    end

    it "leaves an unchanged install alone, rewrites an upgraded one, and reinstalls a deleted one" do
      run(artifacts: [command(name: "analyze")])
      expect(run(artifacts: [command(name: "analyze")]).unchanged).to eq([".claude/commands/analyze.md"])

      result = run(artifacts: [command(name: "analyze", body: "# analyze v2\n", version: "2.0.0")])
      expect(result.updated).to eq([".claude/commands/analyze.md"])
      expect(read(".claude/commands/analyze.md")).to eq("# analyze v2\n")

      FileUtils.rm(File.join(root, ".claude/commands/analyze.md"))
      run(artifacts: [command(name: "analyze", body: "# analyze v2\n", version: "2.0.0")])
      expect(read(".claude/commands/analyze.md")).to eq("# analyze v2\n")
    end

    it "preserves a locally-modified agent, and overwrites it only when asked" do
      run(artifacts: [agent(name: "reviewer")])
      File.write(File.join(root, ".claude/agents/reviewer.md"), "mine\n")
      upgraded = agent(name: "reviewer", body: "---\nname: reviewer\ndescription: new\n---\n", version: "2.0.0")

      expect(run(artifacts: [upgraded]).skipped).to eq([".claude/agents/reviewer.md"])
      expect(read(".claude/agents/reviewer.md")).to eq("mine\n")

      run(mode: :overwrite, artifacts: [upgraded])
      expect(read(".claude/agents/reviewer.md")).to include("description: new")
    end

    it "delivers an upgrade to a sidecar in sidecar mode" do
      run(artifacts: [agent(name: "reviewer")])
      File.write(File.join(root, ".claude/agents/reviewer.md"), "mine\n")
      upgraded = agent(name: "reviewer", body: "---\nname: reviewer\ndescription: new\n---\n", version: "2.0.0")

      expect(run(mode: :sidecar, artifacts: [upgraded]).sidecars).to eq([".claude/agents/reviewer.md"])
      expect(read(".claude/agents/reviewer.md")).to eq("mine\n")
      expect(read(".claude/agents/reviewer.md.new")).to include("description: new")
    end

    it "merges an upgrade into a locally-modified command" do
      v1 = command(name: "analyze", body: "# analyze\n\nline a\nline b\nline c\nline d\n")
      run(artifacts: [v1])
      File.write(File.join(root, ".claude/commands/analyze.md"), v1.body.sub("line a", "line a (mine)"))
      allow(Rails::Hyperdrive::AncestorLocator).to receive(:locate).and_return(v1.body)

      v2 = command(name: "analyze", version: "2.0.0", body: v1.body.sub("line d", "line d (upstream)"))
      expect(run(mode: :merge, artifacts: [v2]).merged).to eq([".claude/commands/analyze.md"])
      expect(read(".claude/commands/analyze.md")).to include("line a (mine)", "line d (upstream)")
    end

    it "sweeps a destination the plan no longer claims" do
      run(artifacts: [command(name: "analyze")], bundled_gems: ["rails-hyperdrive-x"])

      result = run(artifacts: [command(name: "review")], bundled_gems: ["rails-hyperdrive-x"])

      expect(result.removed).to include(".claude/commands/analyze.md")
      expect(exist?(".claude/commands/analyze.md")).to be false
      expect(exist?(".claude/commands/review.md")).to be true
    end

    it "removes a disabled agent only while it still matches the lock" do
      run(artifacts: [agent(name: "reviewer")])
      lock = File.join(root, ".hyperdrive/lock.yml")
      data = YAML.safe_load(File.read(lock))
      data["disabled"]["agents"] = ["reviewer"]
      File.write(lock, data.to_yaml)

      expect(run(artifacts: [agent(name: "reviewer")]).removed).to include(".claude/agents/reviewer.md")

      run(artifacts: [agent(name: "reviewer")])
      File.write(File.join(root, ".claude/agents/reviewer.md"), "mine\n")
      data["disabled"]["agents"] = ["reviewer"]
      File.write(lock, data.to_yaml)
      run(artifacts: [agent(name: "reviewer")])
      expect(read(".claude/agents/reviewer.md")).to eq("mine\n")
    end
  end

  describe "gitignored install destination" do
    before { system("git", "init", "--quiet", root, out: File::NULL, err: File::NULL) }

    it "warns when the destinations are ignored" do
      File.write(File.join(root, ".gitignore"), ".claude/\n")

      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to include(".claude/skills", ".claude/hyperdrive", ".claude/agents", ".claude/commands")
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
        .to eq("@guidelines/auth-pundit.md\n@guidelines/jobs-sidekiq.md\n")
      expect(read("CLAUDE.md")).to eq(
        "<!-- AI instructions for this project. Managed content lives in .claude/hyperdrive/. -->\n\n" \
        "@.claude/hyperdrive/index.md\n"
      )
    end

    it "prints the eager footprint" do
      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to match(/eager\s+1 guideline\(s\), ~\d+ tokens always in context/)
    end

    it "leaves index.md alone on a re-run" do
      run(artifacts: [guideline(name: "auth-pundit")])
      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(out).to match(%r{unchanged\s+\.claude/hyperdrive/index\.md})
    end
  end

  describe "the companion-driven eager chain" do
    def lock_yaml = YAML.safe_load(read(".hyperdrive/lock.yml"))

    it "writes nothing into the context window when no companion ships a guideline" do
      out = run_reporting(artifacts: [skill(name: "jobs")])

      expect(exist?(".claude/hyperdrive/index.md")).to be false
      expect(exist?("CLAUDE.md")).to be false
      expect(lock_yaml).not_to have_key("claude_md")
      expect(out).not_to include("always in context")
    end

    it "arms the chain on the first run that lands a guideline" do
      run(artifacts: [])

      out = run_reporting(artifacts: [guideline(name: "auth-pundit")])

      expect(read(".claude/hyperdrive/index.md")).to eq("@guidelines/auth-pundit.md\n")
      expect(read("CLAUDE.md")).to include("@.claude/hyperdrive/index.md")
      expect(lock_yaml["claude_md"]).to eq("state" => "present")
      expect(out).not_to include("won't re-add")
    end

    it "tears the chain down when the last companion leaves the bundle" do
      run(artifacts: [guideline(name: "auth-pundit")])

      result = run(artifacts: [])

      expect(exist?(".claude/hyperdrive/index.md")).to be false
      expect(result.removed).to include(".claude/hyperdrive/index.md")
      expect(exist?("CLAUDE.md")).to be false
      expect(exist?(".claude/hyperdrive/guidelines/auth-pundit.md")).to be true
      expect(result.orphaned).to include(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(lock_yaml).not_to have_key("claude_md")
    end

    it "keeps every user byte of a CLAUDE.md it did not write, minus the import line" do
      run(artifacts: [guideline(name: "auth-pundit")])
      File.write(File.join(root, "CLAUDE.md"), "# My notes\n\n@.claude/hyperdrive/index.md\n\nMore of mine.\n")

      run(artifacts: [])

      expect(read("CLAUDE.md")).to eq("# My notes\n\n\nMore of mine.\n")
    end

    it "leaves exactly one trailing newline when the import line was last" do
      run(artifacts: [guideline(name: "auth-pundit")])
      File.write(File.join(root, "CLAUDE.md"), "# My notes\n\n@.claude/hyperdrive/index.md\n")

      run(artifacts: [])

      expect(read("CLAUDE.md")).to eq("# My notes\n")
    end

    it "keeps an emptied index.md while a guideline is still planned" do
      run(artifacts: [guideline(name: "auth-pundit")])
      File.write(File.join(root, ".claude/hyperdrive/index.md"), "")

      run(artifacts: [guideline(name: "auth-pundit")])

      expect(read(".claude/hyperdrive/index.md")).to eq("")
      expect(read("CLAUDE.md")).to include("@.claude/hyperdrive/index.md")
    end

    it "never tears down in additive mode" do
      run(artifacts: [guideline(name: "auth-pundit")])
      claude_md = read("CLAUDE.md")

      result = run(mode: :additive, artifacts: [])

      expect(exist?(".claude/hyperdrive/index.md")).to be true
      expect(read("CLAUDE.md")).to eq(claude_md)
      expect(result.removed).to be_empty
      expect(lock_yaml["claude_md"]).to eq("state" => "present")
    end
  end

  it "rejects an unknown mode" do
    expect {
      described_class.new(root: root, shell: nil, artifacts: [], mode: :clobber)
    }.to raise_error(ArgumentError, /clobber/)
  end

  it "accepts the sidecar and merge modes" do
    %i[sidecar merge].each do |mode|
      expect { described_class.new(root: root, shell: nil, artifacts: [], mode: mode) }.not_to raise_error
    end
  end

  describe "sidecar mode" do
    let(:gpath) { ".claude/hyperdrive/guidelines/auth-pundit.md" }
    let(:sidecar) { "#{gpath}.new" }
    let(:v2_body) { "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# auth-pundit\n\nUPGRADED rule.\n" }
    let(:v2) { guideline(name: "auth-pundit", body: v2_body, version: "2.0.0") }

    def lock_source(rel)
      lock = YAML.safe_load(read(".hyperdrive/lock.yml"))
      lock["files"].find { |f| f["path"] == rel }&.fetch("source")
    end

    before do
      run(artifacts: [guideline(name: "auth-pundit")])
      File.write(File.join(root, gpath), read(gpath) + "\nMY LOCAL EDIT\n")
    end

    it "delivers a new upstream as <dest>.new, bumps the lock, and leaves the live file untouched" do
      live_before = read(gpath)

      result = run(mode: :sidecar, artifacts: [v2])

      expect(read(gpath)).to eq(live_before)
      expect(read(sidecar)).to start_with("# auth-pundit")
      expect(read(sidecar)).to include("UPGRADED rule.")
      expect(result.sidecars).to eq([gpath])
      expect(lock_source(gpath)).to eq("rails-hyperdrive-x@2.0.0")
    end

    it "writes the sidecar byte-identical to what a live install would write, so mv = accept upstream" do
      run(mode: :sidecar, artifacts: [v2])
      FileUtils.mv(File.join(root, sidecar), File.join(root, gpath))

      result = run(artifacts: [v2])

      expect(result.unchanged).to include(gpath)
      expect(read(gpath)).to include("UPGRADED rule.")
    end

    it "skips like preserve mode when nothing new is offered" do
      out = run_reporting(mode: :sidecar, artifacts: [guideline(name: "auth-pundit")])

      expect(out).to include("locally modified; run hyperdrive:sync with --merge, --sidecar, or --overwrite")
      expect(exist?(sidecar)).to be false
      expect(lock_source(gpath)).to eq("rails-hyperdrive-x@1.0.0")
    end

    it "reminds about an unresolved sidecar when nothing new is offered" do
      run(mode: :sidecar, artifacts: [v2])

      out = run_reporting(mode: :sidecar, artifacts: [v2])

      expect(out).to include("unresolved sidecar")
      expect(read(sidecar)).to include("UPGRADED rule.")
    end

    it "refreshes a machine-pristine sidecar when a newer upstream arrives" do
      run(mode: :sidecar, artifacts: [v2])
      v3 = guideline(
        name: "auth-pundit", version: "3.0.0",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# auth-pundit\n\nV3 rule.\n"
      )

      run(mode: :sidecar, artifacts: [v3])

      expect(read(sidecar)).to include("V3 rule.")
      expect(lock_source(gpath)).to eq("rails-hyperdrive-x@3.0.0")
    end

    it "leaves an edited sidecar alone and keeps the lock so the upstream is re-offered" do
      run(mode: :sidecar, artifacts: [v2])
      File.write(File.join(root, sidecar), "my half-finished reconcile\n")
      v3 = guideline(name: "auth-pundit", version: "3.0.0", body: v2_body.sub("UPGRADED", "V3"))

      out = run_reporting(mode: :sidecar, artifacts: [v3])

      expect(out).to include("sidecar locally modified; resolve or delete it")
      expect(read(sidecar)).to eq("my half-finished reconcile\n")
      expect(lock_source(gpath)).to eq("rails-hyperdrive-x@2.0.0")
    end

    it "adopts a hand-written file with no lock entry: sidecar delivered, lock entry created, live file untouched" do
      hand = ".claude/hyperdrive/guidelines/hand-made.md"
      FileUtils.mkdir_p(File.dirname(File.join(root, hand)))
      File.write(File.join(root, hand), "my own notes\n")

      result = run(mode: :sidecar, artifacts: [guideline(name: "auth-pundit"), guideline(name: "hand-made", version: "2.0.0")])

      expect(read(hand)).to eq("my own notes\n")
      expect(read("#{hand}.new")).to include("# hand-made")
      expect(result.sidecars).to include(hand)
      expect(lock_source(hand)).to eq("rails-hyperdrive-x@2.0.0")
    end

    it "delivers a skill_support sidecar as raw bytes" do
      s = skill(name: "jobs", support_files: [{ path: "references/deep.md", body: "# Deep v1\n" }])
      run(artifacts: [s])
      File.write(File.join(root, ".claude/skills/jobs/references/deep.md"), "my rewrite\n")

      s2 = skill(name: "jobs", version: "2.0.0", support_files: [{ path: "references/deep.md", body: "# Deep v2\n" }])
      result = run(mode: :sidecar, artifacts: [s2])

      expect(read(".claude/skills/jobs/references/deep.md.new")).to eq("# Deep v2\n")
      expect(result.sidecars).to include(".claude/skills/jobs/references/deep.md")
    end
  end

  describe "sidecar sweep on live writes" do
    let(:gpath) { ".claude/hyperdrive/guidelines/auth-pundit.md" }
    let(:sidecar) { "#{gpath}.new" }
    let(:v1) { guideline(name: "auth-pundit") }

    before { run(artifacts: [v1]) }

    def plant_pristine_sidecar
      # Byte-identical to the recorded install-ready body, so it hashes to
      # source_sha.
      File.write(File.join(root, sidecar), v1.body.split("---\n").last.sub(/\A\n+/, ""))
    end

    it "removes a pristine leftover sidecar when the live file reads current" do
      plant_pristine_sidecar

      result = run(artifacts: [v1])

      expect(exist?(sidecar)).to be false
      expect(result.removed).to include(sidecar)
    end

    it "removes a pristine leftover sidecar on an upgrade rewrite" do
      plant_pristine_sidecar
      v2 = guideline(name: "auth-pundit", version: "2.0.0", body: v1.body + "\nMore.\n")

      run(artifacts: [v2])

      expect(exist?(sidecar)).to be false
      expect(read(gpath)).to include("More.")
    end

    it "removes a pristine leftover sidecar on a missing-file reinstall" do
      plant_pristine_sidecar
      File.delete(File.join(root, gpath))

      run(artifacts: [v1])

      expect(exist?(sidecar)).to be false
      expect(exist?(gpath)).to be true
    end

    it "removes a pristine leftover sidecar on overwrite" do
      File.write(File.join(root, gpath), "edited\n")
      plant_pristine_sidecar

      run(mode: :overwrite, artifacts: [v1])

      expect(exist?(sidecar)).to be false
      expect(read(gpath)).to include("rule.")
    end

    it "warns about and leaves an edited sidecar" do
      File.write(File.join(root, sidecar), "my notes\n")

      out = run_reporting(artifacts: [v1])

      expect(out).to include("sidecar locally modified; resolve or delete it")
      expect(read(sidecar)).to eq("my notes\n")
    end

    it "never sweeps in additive mode" do
      plant_pristine_sidecar

      run(mode: :additive, artifacts: [v1])

      expect(exist?(sidecar)).to be true
    end
  end

  describe "merge mode" do
    let(:gpath) { ".claude/hyperdrive/guidelines/auth-pundit.md" }
    let(:v1_ready) { "# auth-pundit\n\nline a\nline b\nline c\nline d\n" }
    let(:v1) do
      guideline(name: "auth-pundit",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n#{v1_ready}")
    end
    let(:v2) do
      guideline(name: "auth-pundit", version: "2.0.0",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n#{v1_ready.sub("line d", "line d (upstream)")}")
    end

    before do
      run(artifacts: [v1])
      File.write(File.join(root, gpath), read(gpath).sub("line a", "line a (mine)"))
    end

    it "writes a clean merge to the live file, re-locks the delivered upstream, and reports it" do
      allow(Rails::Hyperdrive::AncestorLocator).to receive(:locate).and_return(v1_ready)

      result = run(mode: :merge, artifacts: [v2])

      live = read(gpath)
      expect(live).to start_with("# auth-pundit")
      expect(live).to include("line a (mine)")
      expect(live).to include("line d (upstream)")
      expect(live).not_to include("<<<<<<<")
      expect(result.merged).to eq([gpath])
      lock = YAML.safe_load(read(".hyperdrive/lock.yml"))
      entry = lock["files"].find { |f| f["path"] == gpath }
      expect(entry["source"]).to eq("rails-hyperdrive-x@2.0.0")
      expect(entry["source_sha"]).to eq(Digest::SHA256.hexdigest(v1_ready.sub("line d", "line d (upstream)")))
    end

    it "degrades to a sidecar when no ancestor is available" do
      out = run_reporting(mode: :merge, artifacts: [v2])

      expect(out).to include("not found in installed gems")
      expect(read(gpath)).to include("line a (mine)")
      expect(read("#{gpath}.new")).to include("line d (upstream)")
    end

    it "degrades to a sidecar on conflicting edits, never writing markers" do
      conflicting = guideline(name: "auth-pundit", version: "2.0.0",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n#{v1_ready.sub("line a", "line a (upstream)")}")
      allow(Rails::Hyperdrive::AncestorLocator).to receive(:locate).and_return(v1_ready)

      out = run_reporting(mode: :merge, artifacts: [conflicting])

      expect(out).to include("conflicting edits")
      expect(read(gpath)).to include("line a (mine)")
      expect(read(gpath)).not_to include("<<<<<<<")
      expect(read("#{gpath}.new")).to include("line a (upstream)")
    end

    it "degrades to a sidecar on binary content without invoking git" do
      allow(Rails::Hyperdrive::AncestorLocator).to receive(:locate).and_return("a\0b")
      expect(Open3).not_to receive(:capture3)

      out = run_reporting(mode: :merge, artifacts: [v2])

      expect(out).to include("binary content")
      expect(read(gpath)).to include("line a (mine)")
      expect(read("#{gpath}.new")).to include("line d (upstream)")
    end

    it "refreshes the sidecar instead of merging while a previous delivery is unresolved" do
      run(mode: :sidecar, artifacts: [v2])
      v3 = guideline(name: "auth-pundit", version: "3.0.0",
        body: "---\nname: auth-pundit\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n" \
              "#{v1_ready.sub("line d", "line d (upstream)").sub("line b", "line b (v3)")}")
      expect(Rails::Hyperdrive::AncestorLocator).not_to receive(:locate)

      out = run_reporting(mode: :merge, artifacts: [v3])

      expect(out).to include("previous delivery still unresolved")
      live = read(gpath)
      expect(live).to include("line a (mine)")
      expect(live).not_to include("(upstream)")
      sidecar = read("#{gpath}.new")
      expect(sidecar).to include("line d (upstream)")
      expect(sidecar).to include("line b (v3)")
      lock = YAML.safe_load(read(".hyperdrive/lock.yml"))
      expect(lock["files"].find { |f| f["path"] == gpath }["source"]).to eq("rails-hyperdrive-x@3.0.0")
    end

    it "degrades to a sidecar when git is unavailable" do
      allow(Rails::Hyperdrive::AncestorLocator).to receive(:locate).and_return(v1_ready)
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "git")

      out = run_reporting(mode: :merge, artifacts: [v2])

      expect(out).to include("git merge-file unavailable")
      expect(exist?("#{gpath}.new")).to be true
    end
  end

  describe "an artifact discovery stopped offering" do
    let(:fence_warning) do
      "guideline 'auth-pundit' (from rails-hyperdrive-x) requires rails-hyperdrive >= 99 (this is 0.6.0); " \
        "upgrade rails-hyperdrive to install it"
    end

    before { run(artifacts: [guideline(name: "auth-pundit")]) }

    it "leaves the installed file alone and prints the reason alongside the orphan line" do
      before_body = read(".claude/hyperdrive/guidelines/auth-pundit.md")

      out = run_reporting(artifacts: [], skips: [fence_warning])

      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to eq(before_body)
      expect(out).to include("no longer shipped by rails-hyperdrive-x")
      expect(out).to include("discovery skipped 1 item(s):").and include(fence_warning)
    end

    it "still prints the reason in additive mode" do
      before_body = read(".claude/hyperdrive/guidelines/auth-pundit.md")

      out = run_reporting(mode: :additive, artifacts: [], skips: [fence_warning])

      expect(read(".claude/hyperdrive/guidelines/auth-pundit.md")).to eq(before_body)
      expect(out).to include(fence_warning)
    end
  end

  describe "a lock written by a newer installer" do
    let(:source) { "rails-hyperdrive-x" }

    before do
      run(artifacts: [guideline(name: "auth-pundit")], bundled_gems: [source])
      lock = File.join(root, ".hyperdrive/lock.yml")
      data = YAML.safe_load(File.read(lock))
      data["version"] = 3
      File.write(lock, data.to_yaml)
    end

    %i[preserve overwrite additive].each do |mode|
      it "writes nothing and rewrites no lock in #{mode} mode" do
        before_lock = read(".hyperdrive/lock.yml")

        result = run(mode: mode, artifacts: [guideline(name: "jobs-sidekiq", source: source)], bundled_gems: [source])

        expect(exist?(".claude/hyperdrive/guidelines/jobs-sidekiq.md")).to be false
        expect(read(".hyperdrive/lock.yml")).to eq(before_lock)
        expect(result.installed).to be_empty
      end
    end

    it "says why once" do
      out = run_reporting(artifacts: [guideline(name: "auth-pundit")], bundled_gems: [source])

      expect(out.scan("was written by a newer rails-hyperdrive").size).to eq(1)
      expect(out).to include("lock schema 3, this installer supports 2")
    end
  end

  describe "a destination the plan no longer claims" do
    let(:source) { "rails-hyperdrive-x" }
    let(:support) { [{ path: "references/deep.md", body: "deep\n" }] }

    def converged(artifacts, mode: :preserve)
      run(mode: mode, artifacts: artifacts, bundled_gems: [source, "other-gem"])
    end

    describe "left behind by a renamed skill" do
      before { converged([skill(name: "jobs", source: source, support_files: support)]) }

      it "removes the pristine directory whole and installs the new one" do
        result = converged([skill(name: "tasks", source: source, support_files: support)])

        expect(exist?(".claude/skills/jobs")).to be false
        expect(exist?(".claude/skills/tasks/references/deep.md")).to be true
        expect(result.removed).to include(".claude/skills/jobs/SKILL.md", ".claude/skills/jobs/references/deep.md")
        expect(read(".hyperdrive/lock.yml")).not_to include("skills/jobs/")
      end

      it "warns about an edited copy, leaves it, and carries its lock entry" do
        File.write(File.join(root, ".claude/skills/jobs/SKILL.md"), "mine\n")

        out = run_reporting(artifacts: [skill(name: "tasks", source: source, support_files: support)],
          bundled_gems: [source])

        expect(read(".claude/skills/jobs/SKILL.md")).to eq("mine\n")
        expect(out).to include("#{source} no longer installs this path but it is locally modified")
        expect(read(".hyperdrive/lock.yml")).to include(".claude/skills/jobs/SKILL.md")
      end

      it "removes a pristine file while an edited sibling keeps the directory alive" do
        File.write(File.join(root, ".claude/skills/jobs/references/deep.md"), "mine\n")

        result = converged([skill(name: "tasks", source: source, support_files: support)])

        expect(exist?(".claude/skills/jobs/SKILL.md")).to be false
        expect(read(".claude/skills/jobs/references/deep.md")).to eq("mine\n")
        expect(result.removed).to eq([".claude/skills/jobs/SKILL.md"])
      end

      it "removes nothing in additive mode" do
        result = converged([skill(name: "tasks", source: source)], mode: :additive)

        expect(exist?(".claude/skills/jobs/SKILL.md")).to be true
        expect(result.removed).to be_empty
      end

      it "sweeps the pristine sidecar of a removed dest, so the directory can empty" do
        installed = read(".claude/skills/jobs/SKILL.md")
        File.write(File.join(root, ".claude/skills/jobs/SKILL.md.new"), installed)
        File.write(File.join(root, ".claude/skills/jobs/references/deep.md.new"),
          read(".claude/skills/jobs/references/deep.md"))

        result = converged([skill(name: "tasks", source: source, support_files: support)])

        expect(exist?(".claude/skills/jobs")).to be false
        expect(result.removed).to include(".claude/skills/jobs/SKILL.md.new")
      end

      it "warns about an edited sidecar of a removed dest and leaves it" do
        File.write(File.join(root, ".claude/skills/jobs/SKILL.md.new"), "my draft\n")

        out = run_reporting(artifacts: [skill(name: "tasks", source: source, support_files: support)],
          bundled_gems: [source])

        expect(read(".claude/skills/jobs/SKILL.md.new")).to eq("my draft\n")
        expect(out).to include(".claude/skills/jobs/SKILL.md.new (sidecar locally modified")
      end
    end

    it "removes the canonical copy when a second source makes the name collide" do
      converged([skill(name: "jobs", source: source)])

      converged([skill(name: "jobs", source: source), skill(name: "jobs", source: "other-gem")])

      expect(exist?(".claude/skills/jobs")).to be false
      expect(exist?(".claude/skills/jobs--#{source}/SKILL.md")).to be true
      expect(exist?(".claude/skills/jobs--other-gem/SKILL.md")).to be true
    end

    it "removes the postfixed copies when the collision resolves" do
      converged([skill(name: "jobs", source: source), skill(name: "jobs", source: "other-gem")])

      converged([skill(name: "jobs", source: source)])

      expect(exist?(".claude/skills/jobs--#{source}")).to be false
      expect(exist?(".claude/skills/jobs--other-gem")).to be false
      expect(exist?(".claude/skills/jobs/SKILL.md")).to be true
    end

    it "drops a renamed guideline's @-line along with the file" do
      converged([guideline(name: "auth-pundit", source: source)])

      converged([guideline(name: "authorization", source: source)])

      expect(exist?(".claude/hyperdrive/guidelines/auth-pundit.md")).to be false
      expect(read(".claude/hyperdrive/index.md")).not_to include("@guidelines/auth-pundit.md")
      expect(read(".claude/hyperdrive/index.md")).to include("@guidelines/authorization.md")
    end

    it "converges silently when the file is already gone" do
      converged([skill(name: "jobs", source: source)])
      FileUtils.rm_rf(File.join(root, ".claude/skills/jobs"))

      result = converged([skill(name: "tasks", source: source)])

      expect(result.orphaned).to be_empty
      expect(read(".hyperdrive/lock.yml")).not_to include("skills/jobs/")
    end

    describe "held because the source gem lost an artifact to a discovery skip" do
      before { converged([skill(name: "jobs", source: source)]) }

      it "deletes nothing and says the gem is still bundled" do
        out = run_reporting(artifacts: [], bundled_gems: [source], skipped_gems: [source])

        expect(exist?(".claude/skills/jobs/SKILL.md")).to be true
        expect(out).to include("#{source} is still bundled but did not offer this file")
        expect(out).not_to include("no longer shipped")
      end

      it "keeps the gem-gone wording when the source left the bundle" do
        out = run_reporting(artifacts: [], bundled_gems: ["other-gem"])

        expect(exist?(".claude/skills/jobs/SKILL.md")).to be true
        expect(out).to include("no longer shipped by #{source}@1.0.0")
      end

      it "deletes nothing when no caller reports the bundle" do
        result = run(artifacts: [])

        expect(exist?(".claude/skills/jobs/SKILL.md")).to be true
        expect(result.removed).to be_empty
      end
    end
  end

  describe "discovery warnings" do
    let(:skip_line) { "skip /x/SKILL.md: missing or malformed frontmatter" }
    let(:advisory)  { "source_gem: manifest entry for 'a': gem: and gems: are aliases; reading gems:" }

    it "counts only real skips under the skipped header" do
      out = run_reporting(skips: [skip_line], warnings: [advisory])

      expect(out).to include("discovery skipped 1 item(s):").and include("    - #{skip_line}")
      expect(out).to include("discovery reported 1 advisory warning(s):").and include("    - #{advisory}")
    end

    it "prints no skipped header when nothing was dropped" do
      out = run_reporting(warnings: [advisory])

      expect(out).not_to include("discovery skipped")
      expect(out).to include("discovery reported 1 advisory warning(s):")
    end

    it "prints no advisory header when every warning is a skip" do
      out = run_reporting(skips: [skip_line])

      expect(out).to include("discovery skipped 1 item(s):")
      expect(out).not_to include("advisory warning")
    end
  end

  describe "discovery notices" do
    let(:notice) { "gem 'foo' ships 2 skills.sh skill(s); add \"foo\" to enabled: in .hyperdrive/lock.yml" }

    it "prints each notice in preserve mode" do
      out = run_reporting(notices: [notice])
      expect(out).to include(notice)
    end

    it "prints nothing when there are no notices" do
      out = run_reporting(notices: [])
      expect(out).not_to include("skills.sh")
    end

    it "stays silent in additive mode" do
      out = run_reporting(mode: :additive, notices: [notice])
      expect(out).not_to include("skills.sh")
    end
  end
end
