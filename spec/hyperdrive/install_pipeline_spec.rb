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

  def run(mode: :preserve, artifacts: [])
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root),
      artifacts: artifacts,
      mode: mode
    ).call
  end

  def run_reporting(mode: :preserve, artifacts: [])
    io = StringIO.new
    described_class.new(
      root: root,
      shell: Rails::Hyperdrive::InstallShell.new(root: root, io: io),
      artifacts: artifacts,
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
end
