require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "generators/hyperdrive/install/install_generator"
require "rails/hyperdrive/bundler_artifact_discovery"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Generators::Hyperdrive::InstallGenerator do
  include Rails::Generators::Testing::Behavior
  include FileUtils

  destination File.expand_path("../../tmp/install_generator", __dir__)
  tests described_class

  Artifact = Rails::Hyperdrive::BundlerArtifactDiscovery::Artifact

  def stub_rails_root(path)
    allow(::Rails).to receive(:root).and_return(Pathname.new(path))
  end

  def stub_discovery(artifacts)
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery)
      .to receive(:discover).and_return(artifacts)
  end

  def skill_artifact(name:, source:, body: nil, support_files: [])
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: body || "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n",
      spec_version: "1.0.0", support_files: support_files
    )
  end

  def guideline_artifact(name:, source:, body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :guideline, source_gem: source, path: "/x/#{name}.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# #{name}\n\nrule.\n",
      spec_version: "1.0.0"
    )
  end

  before do
    prepare_destination
    @app_dir = destination_root
    # spec/tmp/ is gitignored by this repo, so without its own repository the
    # destination inherits that ignore and every run trips the gitignore warning.
    system("git", "init", "--quiet", @app_dir, out: File::NULL, err: File::NULL)
    FileUtils.mkdir_p(File.join(@app_dir, "config"))
    File.write(File.join(@app_dir, "config", "routes.rb"), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(@app_dir, "Gemfile.lock"), File.read(File.expand_path("../../fixtures/gemfile_lock/standard.lock", __dir__)))
    stub_rails_root(@app_dir)
    stub_discovery([])
  end

  def path(rel) = File.join(@app_dir, rel)

  describe ".mcp.json + engine mount (unchanged surface)" do
    it "writes .mcp.json with the mount path" do
      run_generator([])
      expect(File.read(path(".mcp.json"))).to include("/_hyperdrive/mcp")
    end

    it "mounts the engine in config/routes.rb" do
      run_generator([])
      routes = File.read(path("config/routes.rb"))
      expect(routes).to include("Rails::Hyperdrive::Engine")
      expect(routes).to include("/_hyperdrive")
    end

    it "is idempotent — re-running does not duplicate the mount" do
      run_generator([])
      run_generator([])
      expect(File.read(path("config/routes.rb")).scan("Rails::Hyperdrive::Engine").length).to eq(1)
    end
  end

  describe ".mcp.json merging" do
    def write_mcp_json(content)
      File.write(path(".mcp.json"), content)
    end

    def mcp_json = JSON.parse(File.read(path(".mcp.json")))

    let(:other_server) do
      <<~JSON
        {
          "mcpServers": {
            "my-other-server": {
              "command": "npx",
              "args": ["-y", "@acme/mcp"]
            }
          }
        }
      JSON
    end

    it "creates the file when none exists" do
      run_generator([])
      expect(mcp_json.dig("mcpServers", "rails-hyperdrive")).to eq(
        "url" => "http://localhost:3000/_hyperdrive/mcp", "type" => "http"
      )
    end

    it "keeps an existing server alongside ours" do
      write_mcp_json(other_server)
      run_generator([])
      expect(mcp_json["mcpServers"].keys).to contain_exactly("my-other-server", "rails-hyperdrive")
      expect(mcp_json.dig("mcpServers", "my-other-server", "command")).to eq("npx")
    end

    it "preserves sibling top-level keys" do
      write_mcp_json('{"mcpServers":{},"someOtherKey":{"a":1},"list":[1,2]}')
      run_generator([])
      expect(mcp_json["someOtherKey"]).to eq("a" => 1)
      expect(mcp_json["list"]).to eq([1, 2])
    end

    it "adds mcpServers when the existing document has no such key" do
      write_mcp_json('{"someOtherKey":true}')
      run_generator([])
      expect(mcp_json.dig("mcpServers", "rails-hyperdrive", "type")).to eq("http")
      expect(mcp_json["someOtherKey"]).to be(true)
    end

    it "replaces a stale rails-hyperdrive entry rather than duplicating it" do
      write_mcp_json('{"mcpServers":{"rails-hyperdrive":{"url":"http://localhost:3000/old/mcp","type":"http"}}}')
      run_generator([])
      expect(mcp_json["mcpServers"].keys).to eq(["rails-hyperdrive"])
      expect(mcp_json.dig("mcpServers", "rails-hyperdrive", "url")).to eq("http://localhost:3000/_hyperdrive/mcp")
    end

    it "preserves other servers under --skip-content" do
      write_mcp_json(other_server)
      run_generator(["--skip-content"])
      expect(mcp_json["mcpServers"]).to have_key("my-other-server")
    end

    it "never prompts on conflict" do
      write_mcp_json(other_server)
      out = run_generator([])
      expect(out).not_to include("conflict")
      expect(out).not_to match(/Overwrite/i)
    end

    it "writes nothing on a re-run when the entry already matches" do
      run_generator([])
      before = File.read(path(".mcp.json"))
      out = run_generator([])
      expect(File.read(path(".mcp.json"))).to eq(before)
      expect(out).to match(/unchanged\s+\.mcp\.json/)
      expect(out).not_to match(/force\s+\.mcp\.json/)
    end

    it "emits 2-space-indented JSON with a trailing newline" do
      write_mcp_json(other_server)
      run_generator([])
      body = File.read(path(".mcp.json"))
      expect(body).to end_with("}\n")
      expect(body).to include(%(\n  "mcpServers": {\n))
      expect(body).to include(%(\n    "rails-hyperdrive": {\n))
    end

    context "when the existing file cannot be merged into" do
      it "leaves malformed JSON untouched, warns, and completes the install" do
        write_mcp_json("{ this is not json")
        out = run_generator([])
        expect(File.read(path(".mcp.json"))).to eq("{ this is not json")
        expect(out).to match(/warn\s+\.mcp\.json left unchanged/)
        expect(File).to exist(path(".hyperdrive/lock.yml"))
        expect(File.read(path("config/routes.rb"))).to include("Rails::Hyperdrive::Engine")
      end

      it "leaves a non-object document untouched" do
        write_mcp_json("[1, 2, 3]\n")
        out = run_generator([])
        expect(File.read(path(".mcp.json"))).to eq("[1, 2, 3]\n")
        expect(out).to match(/top-level value is not a JSON object/)
      end

      it "leaves a non-object mcpServers untouched" do
        write_mcp_json('{"mcpServers":[]}')
        out = run_generator([])
        expect(File.read(path(".mcp.json"))).to eq('{"mcpServers":[]}')
        expect(out).to match(/"mcpServers" is not a JSON object/)
      end
    end

    describe "--dry-run" do
      it "writes no file when none exists" do
        run_generator(["--dry-run"])
        expect(File).not_to exist(path(".mcp.json"))
      end

      it "leaves an existing file untouched" do
        write_mcp_json(other_server)
        run_generator(["--dry-run"])
        expect(File.read(path(".mcp.json"))).to eq(other_server)
      end
    end
  end

  describe "zero-companion install (no companions)" do
    it "writes the bootstrap artifacts and the lockfile" do
      run_generator([])
      expect(File).to exist(path(".mcp.json"))
      expect(File).to exist(path(".hyperdrive/lock.yml"))
      expect(File.read(path(".gitignore"))).to include(".hyperdrive/discover_cache.json")
      expect(File.read(path("config/routes.rb"))).to include("Rails::Hyperdrive::Engine")
    end

    it "puts nothing into the agent's context window" do
      run_generator([])
      expect(File).not_to exist(path(".claude/hyperdrive/index.md"))
      expect(File).not_to exist(path("CLAUDE.md"))
      expect(File).not_to exist(path(".claude/skills"))
      expect(YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))).not_to have_key("claude_md")
    end
  end

  describe "discover-cache .gitignore rule" do
    it "ignores the specific cache file, not the .hyperdrive/ directory" do
      run_generator([])
      lines = File.read(path(".gitignore")).split("\n").map(&:strip)
      expect(lines).to include(".hyperdrive/discover_cache.json")
      expect(lines).not_to include(".hyperdrive/", ".hyperdrive")
    end

    it "is idempotent across re-runs" do
      run_generator([])
      run_generator([])
      occurrences = File.read(path(".gitignore")).scan(".hyperdrive/discover_cache.json").length
      expect(occurrences).to eq(1)
    end
  end

  describe "bundler plugin Gemfile directive" do
    def gemfile = path("Gemfile")

    it "appends the plugin directive to a fresh Gemfile" do
      File.write(gemfile, %(source "https://rubygems.org"\n\ngem "rails"\n))
      run_generator([])
      expect(File.read(gemfile)).to end_with(%(gem "rails"\nplugin "bundler-hyperdrive"\n))
    end

    it "is idempotent — re-running appends exactly one directive" do
      File.write(gemfile, %(source "https://rubygems.org"\n))
      run_generator([])
      run_generator([])
      expect(File.read(gemfile).scan('plugin "bundler-hyperdrive"').length).to eq(1)
    end

    it "leaves an existing path-sourced directive byte-identical" do
      body = %(source "https://rubygems.org"\nplugin "bundler-hyperdrive", path: "../bundler-hyperdrive"\n)
      File.write(gemfile, body)
      out = run_generator([])
      expect(File.read(gemfile)).to eq(body)
      expect(out).to match(/identical\s+Gemfile/)
    end

    it "skips with a status when there is no Gemfile" do
      out = run_generator([])
      expect(out).to match(/skip\s+no Gemfile found/)
      expect(File).not_to exist(gemfile)
    end

    it "appends on its own line when the Gemfile lacks a trailing newline" do
      File.write(gemfile, %(gem "rails"))
      run_generator([])
      expect(File.read(gemfile)).to end_with(%(gem "rails"\nplugin "bundler-hyperdrive"\n))
    end

    it "still writes the directive under --skip-content" do
      File.write(gemfile, %(source "https://rubygems.org"\n))
      run_generator(["--skip-content"])
      expect(File.read(gemfile)).to include(%(plugin "bundler-hyperdrive"\n))
    end

    it "writes nothing under --dry-run" do
      body = %(source "https://rubygems.org"\n)
      File.write(gemfile, body)
      run_generator(["--dry-run"])
      expect(File.read(gemfile)).to eq(body)
    end
  end

  describe "skill install (body verbatim)" do
    before { stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")]) }

    it "installs the skill body verbatim, frontmatter included" do
      run_generator([])
      body = File.read(path(".claude/skills/jobs-sidekiq/SKILL.md"))
      expect(body).to eq("---\nname: jobs-sidekiq\ndescription: d\n---\n\n# jobs-sidekiq\n")
      expect(body).not_to include("hyperdrive:")
    end
  end

  describe "multi-file skill install (supporting files)" do
    let(:support) do
      [
        { path: "references/deep.md", body: "# Deep\n\nraw supporting bytes.\n" },
        { path: "examples/sample.rb", body: "puts 1\n" }
      ]
    end

    def stub_multi(files = support)
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq", support_files: files)])
    end

    it "installs the tree under the skill dir, byte-identical" do
      stub_multi
      run_generator([])

      expect(File.read(path(".claude/skills/jobs-sidekiq/references/deep.md"))).to eq("# Deep\n\nraw supporting bytes.\n")
      expect(File.read(path(".claude/skills/jobs-sidekiq/examples/sample.rb"))).to eq("puts 1\n")
    end

    it "locks each supporting file as skill_support with a per-file sha" do
      stub_multi
      run_generator([])

      lock = YAML.safe_load(File.read(path(".hyperdrive/lock.yml")))
      entries = lock["files"].select { |e| e["artifact"] == "skill_support" }
      expect(entries.map { |e| e["path"] }).to contain_exactly(
        ".claude/skills/jobs-sidekiq/references/deep.md",
        ".claude/skills/jobs-sidekiq/examples/sample.rb"
      )
      expect(entries.map { |e| e["source_sha"] }.uniq.size).to eq(2)
    end

    it "rewrites an unedited supporting file when the gem ships new content" do
      stub_multi
      run_generator([])

      stub_multi([{ path: "references/deep.md", body: "# Deep v2\n" }, support.last])
      run_generator([])
      expect(File.read(path(".claude/skills/jobs-sidekiq/references/deep.md"))).to eq("# Deep v2\n")
    end

    it "skips a user-edited supporting file (skip + warn)" do
      stub_multi
      run_generator([])
      spath = path(".claude/skills/jobs-sidekiq/references/deep.md")
      File.write(spath, "my rewrite\n")

      out = run_generator([])
      expect(File.read(spath)).to eq("my rewrite\n")
      expect(out).to include("locally modified")
    end

    it "reinstalls a deleted supporting file" do
      stub_multi
      run_generator([])
      File.delete(path(".claude/skills/jobs-sidekiq/examples/sample.rb"))

      run_generator([])
      expect(File.read(path(".claude/skills/jobs-sidekiq/examples/sample.rb"))).to eq("puts 1\n")
    end

    describe "gated delete of a dropped supporting file" do
      before do
        stub_multi
        run_generator([])
        stub_multi(support.first(1)) # the gem stops shipping examples/sample.rb
      end

      it "removes an unedited copy and prunes the emptied subdirectory" do
        run_generator([])
        expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/examples/sample.rb"))
        expect(Dir).not_to exist(path(".claude/skills/jobs-sidekiq/examples"))
        expect(File).to exist(path(".claude/skills/jobs-sidekiq/references/deep.md"))
        expect(File.read(path(".hyperdrive/lock.yml"))).not_to include("examples/sample.rb")
      end

      it "warns and leaves an edited copy, carrying its lock entry" do
        File.write(path(".claude/skills/jobs-sidekiq/examples/sample.rb"), "puts 2 # mine\n")

        out = run_generator([])
        expect(File.read(path(".claude/skills/jobs-sidekiq/examples/sample.rb"))).to eq("puts 2 # mine\n")
        expect(out).to include("no longer shipped")
        expect(File.read(path(".hyperdrive/lock.yml"))).to include("examples/sample.rb")
      end
    end

    describe "disabling the owning skill" do
      def disable_skill
        File.write(path(".hyperdrive/config.yml"), { "disabled" => { "skills" => ["jobs-sidekiq"] } }.to_yaml)
      end

      before do
        stub_multi
        run_generator([])
        disable_skill
      end

      it "removes unedited supporting files along with SKILL.md, directory and all" do
        run_generator([])
        expect(Dir).not_to exist(path(".claude/skills/jobs-sidekiq"))
      end

      it "keeps a user-created file not in the lock, and the directory with it" do
        File.write(path(".claude/skills/jobs-sidekiq/NOTES.md"), "mine\n")

        run_generator([])
        expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
        expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/references/deep.md"))
        expect(File.read(path(".claude/skills/jobs-sidekiq/NOTES.md"))).to eq("mine\n")
      end
    end

    it "summarizes supporting files as a count on the skill's line" do
      stub_multi
      out = run_generator([])

      expect(out).to include("Installed 1 skill, 0 guidelines")
      expect(out).to match(/skill\s+jobs-sidekiq \(\+2 files\)/)
      expect(out).not_to match(/skill_support/)
      expect(out.scan("references/deep.md").size).to eq(1) # the create line only, no summary line
    end
  end

  describe "guideline install (frontmatter stripped)" do
    before { stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")]) }

    it "installs the guideline frontmatter-stripped, body verbatim" do
      run_generator([])
      body = File.read(path(".claude/hyperdrive/guidelines/auth-pundit.md"))
      expect(body).to start_with("# auth-pundit")
      expect(body).not_to include("name: auth-pundit")
      expect(body).not_to include("hyperdrive:")
    end

    it "adds the guideline to index.md" do
      run_generator([])
      expect(File.read(path(".claude/hyperdrive/index.md"))).to include("@guidelines/auth-pundit.md")
    end

    it "adds a newly-discovered guideline to a pre-existing index.md" do
      run_generator([])
      stub_discovery([
        guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit"),
        guideline_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")
      ])
      run_generator([])
      index = File.read(path(".claude/hyperdrive/index.md"))
      expect(index).to include("@guidelines/auth-pundit.md")
      expect(index).to include("@guidelines/jobs-sidekiq.md")
    end

    it "does not re-add a guideline whose index.md line the user deleted (opt-out)" do
      stub_discovery([
        guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit"),
        guideline_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")
      ])
      run_generator([])
      index = path(".claude/hyperdrive/index.md")
      File.write(index, "@guidelines/jobs-sidekiq.md\n")
      run_generator([])
      expect(File.read(index)).to eq("@guidelines/jobs-sidekiq.md\n")
    end
  end

  describe "cross-source conflict (install both, postfixed)" do
    before do
      stub_discovery([
        skill_artifact(name: "dummy-skill", source: "dummy_gem"),
        skill_artifact(name: "dummy-skill", source: "companion_gem")
      ])
    end

    it "installs both variants postfixed by source gem" do
      run_generator([])
      expect(File).to exist(path(".claude/skills/dummy-skill--dummy_gem/SKILL.md"))
      expect(File).to exist(path(".claude/skills/dummy-skill--companion_gem/SKILL.md"))
    end

    it "renames the display name: in the postfixed skill body" do
      run_generator([])
      body = File.read(path(".claude/skills/dummy-skill--companion_gem/SKILL.md"))
      expect(body).to include("name: dummy-skill--companion_gem")
    end
  end

  describe "idempotency + drift" do
    before { stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")]) }

    it "does not rewrite an unchanged file on re-run (installed_at preserved)" do
      run_generator([])
      first = File.read(path(".hyperdrive/lock.yml"))
      run_generator([])
      second = File.read(path(".hyperdrive/lock.yml"))
      expect(second).to eq(first)
    end

    it "skips a user-edited file on init (skip + warn)" do
      run_generator([])
      gpath = path(".claude/hyperdrive/guidelines/auth-pundit.md")
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")
      run_generator([])
      expect(File.read(gpath)).to include("MY LOCAL EDIT")
    end

    it "rewrites an unedited file when the gem ships new content" do
      run_generator([])
      gpath = path(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(File.read(gpath)).to include("rule.")

      upgraded = "---\nname: auth-pundit\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# auth-pundit\n\nUPGRADED rule.\n"
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit", body: upgraded)])
      run_generator([])
      expect(File.read(gpath)).to include("UPGRADED rule.")
    end
  end

  describe "orphan handling (source gem removed, file remains)" do
    it "leaves the file in place, warns, and carries the lock entry" do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      run_generator([])
      gpath = path(".claude/hyperdrive/guidelines/auth-pundit.md")
      expect(File).to exist(gpath)

      stub_discovery([]) # source gem no longer in the bundle
      out = run_generator([])
      expect(out).to include("orphan")
      expect(File).to exist(gpath)
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("auth-pundit")
    end
  end

  describe "a lock written by a newer installer" do
    it "still bootstraps, but refuses the content sync and leaves the lock byte-identical" do
      FileUtils.mkdir_p(path(".hyperdrive"))
      File.write(path(".hyperdrive/lock.yml"), "version: 4\nfiles: []\n")
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])

      err = capture(:stderr) { run_generator([]) }

      expect(err).to include("was written by a newer rails-hyperdrive")
      expect(File.read(path(".hyperdrive/lock.yml"))).to eq("version: 4\nfiles: []\n")
      expect(File).not_to exist(path(".claude/hyperdrive/guidelines/auth-pundit.md"))
      expect(File).to exist(path(".mcp.json"))
      expect(File.read(path("config/routes.rb"))).to include("Rails::Hyperdrive::Engine")
    end
  end

  describe "per-artifact opt-out (disabled: in config.yml)" do
    def lock_path = path(".hyperdrive/lock.yml")
    def config_path = path(".hyperdrive/config.yml")

    def disable(key, *names)
      FileUtils.mkdir_p(File.dirname(config_path))
      data = File.exist?(config_path) ? YAML.safe_load(File.read(config_path)) : {}
      data = {} unless data.is_a?(Hash)
      (data["disabled"] ||= {})[key] = names
      File.write(config_path, data.to_yaml)
    end

    it "never installs a skill disabled before the first run" do
      disable("skills", "jobs-sidekiq")
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      out = run_generator([])
      expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
      expect(out).to include("disabled")
    end

    it "removes an already-installed skill once disabled, directory and all" do
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])
      expect(File).to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))

      disable("skills", "jobs-sidekiq")
      run_generator([])
      expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
      expect(Dir).not_to exist(path(".claude/skills/jobs-sidekiq"))
      expect(File.read(lock_path)).not_to include("jobs-sidekiq/SKILL.md")
    end

    it "keeps a user's own files in a disabled skill's directory" do
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])
      File.write(path(".claude/skills/jobs-sidekiq/NOTES.md"), "mine\n")

      disable("skills", "jobs-sidekiq")
      run_generator([])
      expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
      expect(File.read(path(".claude/skills/jobs-sidekiq/NOTES.md"))).to eq("mine\n")
    end

    it "leaves a locally-modified disabled artifact in place and warns" do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      run_generator([])
      gpath = path(".claude/hyperdrive/guidelines/auth-pundit.md")
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")

      disable("guidelines", "auth-pundit")
      out = run_generator([])
      expect(File.read(gpath)).to include("MY LOCAL EDIT")
      expect(out).to include("locally modified")
      expect(File.read(lock_path)).to include("auth-pundit")
    end

    it "does not force-remove a locally-modified disabled artifact on update" do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      run_generator([])
      gpath = path(".claude/hyperdrive/guidelines/auth-pundit.md")
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")

      disable("guidelines", "auth-pundit")
      run_generator(["--update"])
      expect(File.read(gpath)).to include("MY LOCAL EDIT")
    end

    it "drops a disabled guideline from index.md" do
      stub_discovery([
        guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit"),
        guideline_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")
      ])
      run_generator([])
      expect(File.read(path(".claude/hyperdrive/index.md"))).to include("@guidelines/auth-pundit.md")

      disable("guidelines", "auth-pundit")
      run_generator([])
      index = File.read(path(".claude/hyperdrive/index.md"))
      expect(index).not_to include("@guidelines/auth-pundit.md")
      expect(index).to include("@guidelines/jobs-sidekiq.md")
      expect(File).not_to exist(path(".claude/hyperdrive/guidelines/auth-pundit.md"))
    end

    it "disables every variant of a cross-source collision by its shipped name" do
      stub_discovery([
        skill_artifact(name: "dummy-skill", source: "dummy_gem"),
        skill_artifact(name: "dummy-skill", source: "companion_gem")
      ])
      run_generator([])
      expect(File).to exist(path(".claude/skills/dummy-skill--dummy_gem/SKILL.md"))

      disable("skills", "dummy-skill")
      run_generator([])
      expect(Dir).not_to exist(path(".claude/skills/dummy-skill--dummy_gem"))
      expect(Dir).not_to exist(path(".claude/skills/dummy-skill--companion_gem"))
    end

    it "disables a single variant of a collision by its postfixed name" do
      stub_discovery([
        skill_artifact(name: "dummy-skill", source: "dummy_gem"),
        skill_artifact(name: "dummy-skill", source: "companion_gem")
      ])
      run_generator([])

      disable("skills", "dummy-skill--dummy_gem")
      run_generator([])
      expect(Dir).not_to exist(path(".claude/skills/dummy-skill--dummy_gem"))
      expect(File).to exist(path(".claude/skills/dummy-skill--companion_gem/SKILL.md"))
    end

    it "reinstalls an artifact once its name leaves the list" do
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])
      disable("skills", "jobs-sidekiq")
      run_generator([])
      expect(File).not_to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))

      disable("skills")
      run_generator([])
      expect(File).to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
    end

    it "leaves the list where the user wrote it, run after run" do
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])
      disable("skills", "jobs-sidekiq")
      before = File.read(config_path)
      run_generator([])
      run_generator([])
      expect(File.read(config_path)).to eq(before)
      expect(YAML.safe_load(File.read(lock_path))).not_to have_key("disabled")
    end

    it "writes nothing under --dry-run" do
      stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")])
      run_generator([])
      disable("skills", "jobs-sidekiq")
      run_generator(["--dry-run"])
      expect(File).to exist(path(".claude/skills/jobs-sidekiq/SKILL.md"))
    end
  end

  describe "discovery warnings surfaced in output" do
    it "prints a summary of skipped artifacts" do
      allow(Rails::Hyperdrive::BundlerArtifactDiscovery).to receive(:discover) do |report:, **_|
        report.skip("skip /x/SKILL.md: missing a required field (name, description, gem, versions)")
        []
      end
      out = run_generator([])
      expect(out).to include("discovery skipped 1 item(s)")
    end
  end

  describe "oversize eager guideline warning" do
    it "warns when a guideline exceeds the eager soft cap" do
      big = "---\nname: big\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# big\n\n" + ("x\n" * 200)
      stub_discovery([guideline_artifact(name: "big", source: "rails-hyperdrive-x", body: big)])
      out = run_generator([])
      expect(out).to match(/is large/)
    end
  end

  describe "eager budget warning" do
    def guideline_of(name, tokens)
      "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n" + ("x" * (tokens * 4))
    end

    it "warns and names the largest contributors when the total is over the budget" do
      stub_discovery([
        guideline_artifact(name: "huge", source: "rails-hyperdrive-x", body: guideline_of("huge", 9_000)),
        guideline_artifact(name: "big", source: "rails-hyperdrive-x", body: guideline_of("big", 2_000)),
        guideline_artifact(name: "tiny", source: "rails-hyperdrive-x", body: guideline_of("tiny", 10))
      ])
      out = run_generator([])
      expect(out).to match(/eager context is over the ~10000 token budget/)
      expect(out).to match(/largest: huge\.md ~\d+, big\.md ~\d+/)
      expect(out).not_to include("tiny.md ~")
    end
  end

  describe "install summary provenance" do
    it "prints the lock-derived listing" do
      stub_discovery([
        skill_artifact(name: "sidekiq-idempotency", source: "rails-hyperdrive-sidekiq"),
        guideline_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq"),
        skill_artifact(name: "component-authoring", source: "rails-hyperdrive-view-component")
      ])
      out = run_generator([])

      expect(out).to include("Installed 2 skills, 1 guideline")
      expect(out).to match(/rails-hyperdrive-view-component@1\.0\.0\n\s+skill\s+component-authoring/)
    end

    it "prints no listing under --skip-content" do
      expect(run_generator(["--skip-content"])).not_to include("Installed")
    end

    it "reports the mount and the number of MCP tools behind it" do
      count = Rails::Hyperdrive::McpServer::TOOLS.size
      out = run_generator([])

      expect(out).to include("Mount: /_hyperdrive (in config/routes.rb)")
      expect(out).to include("Server: #{count} MCP tools at http://localhost:3000/_hyperdrive/mcp")
    end

    it "prints a connection check the mounted endpoint actually answers" do
      line = run_generator([]).lines.find { |l| l.include?("curl ") }
      expect(line).not_to be_nil

      url = line[%r{https?://\S+}]
      headers = line.scan(/-H '([^:']+): ([^']+)'/).to_h
      payload = line[/-d '(.+)'/, 1]

      env = Rack::MockRequest.env_for(
        url,
        method: "POST",
        input: payload,
        "CONTENT_TYPE" => headers.fetch("Content-Type"),
        "HTTP_ACCEPT" => headers.fetch("Accept")
      )
      status, _headers, body = Rails::Hyperdrive::McpServer.rack_app.call(env)

      expect(status).to eq(200)
      expect(JSON.parse(body.to_a.join).dig("result", "tools")).to be_an(Array)
    end
  end

  describe "gitignored install destination" do
    it "warns when .claude/ is gitignored" do
      File.write(path(".gitignore"), ".claude/\n")
      out = run_generator([])

      expect(out).to match(/gitignored/)
      expect(out).to include(".claude/skills")
      expect(out).to include(".claude/hyperdrive")
      expect(out).to match(/unreviewed/)
    end

    it "warns when the lockfile and the config are gitignored" do
      File.write(path(".gitignore"), ".hyperdrive/\n")
      out = run_generator([])

      expect(out).to match(%r{\.hyperdrive/lock\.yml, \.hyperdrive/config\.yml are gitignored})
    end

    it "stays quiet when the destinations are git-tracked" do
      expect(run_generator([])).not_to match(/gitignored/)
    end

    it "stays quiet when git is unavailable" do
      allow(IO).to receive(:popen).and_call_original
      allow(IO).to receive(:popen).with(array_including("check-ignore"), any_args).and_raise(Errno::ENOENT)
      File.write(path(".gitignore"), ".claude/\n")

      expect(run_generator([])).not_to match(/gitignored/)
    end
  end

  describe "CLAUDE.md import line" do
    before { stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")]) }

    it "does not re-add the import line after the user deletes it (warn once)" do
      run_generator([])
      File.write(path("CLAUDE.md"), "# my own notes\n")
      run_generator([])
      expect(File.read(path("CLAUDE.md"))).not_to include("@.claude/hyperdrive/index.md")
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("state: removed-by-user")
    end

    it "appends the import line to a pre-existing CLAUDE.md" do
      File.write(path("CLAUDE.md"), "# pre-existing user content\n")
      run_generator([])
      body = File.read(path("CLAUDE.md"))
      expect(body).to include("# pre-existing user content")
      expect(body).to include("@.claude/hyperdrive/index.md")
    end
  end

  describe "the settings file" do
    def config_path = path(".hyperdrive/config.yml")

    it "is created with empty sections and an explanatory header" do
      out = run_generator([])

      expect(out).to include(".hyperdrive/config.yml")
      expect(File.read(config_path))
        .to eq(Rails::Generators::Hyperdrive::InstallGenerator::CONFIG_TEMPLATE)
      document = YAML.safe_load(File.read(config_path))
      expect(document["disabled"]).to eq("skills" => [], "guidelines" => [], "agents" => [], "commands" => [])
      expect(document["enabled"]).to eq([])
    end

    it "leaves an existing file byte-identical" do
      run_generator([])
      File.write(config_path, "enabled:\n  - some_gem\n")

      out = run_generator([])

      expect(File.read(config_path)).to eq("enabled:\n  - some_gem\n")
      expect(out).to include(".hyperdrive/config.yml (already present)")
    end

    it "is skipped under --skip-content" do
      run_generator(["--skip-content"])

      expect(File).not_to exist(config_path)
    end

    it "is not written under --dry-run" do
      run_generator(["--dry-run"])

      expect(File).not_to exist(config_path)
    end
  end

  describe "flags" do
    it "honors --dry-run by writing no files" do
      run_generator(["--dry-run"])
      expect(File).not_to exist(path(".mcp.json"))
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
      expect(File.read(path("config/routes.rb"))).not_to include("Rails::Hyperdrive::Engine")
    end

    it "honors --skip-content (no .claude content, no CLAUDE.md, no lockfile, still writes .mcp.json)" do
      run_generator(["--skip-content"])
      expect(File).to exist(path(".mcp.json"))
      expect(File).not_to exist(path(".claude/hyperdrive/index.md"))
      expect(File).not_to exist(path("CLAUDE.md"))
      expect(File).not_to exist(path(".hyperdrive/config.yml"))
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
    end

    it "reconstructs full content on a later init after --skip-content" do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      run_generator(["--skip-content"])
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))

      run_generator([])
      expect(File).to exist(path(".claude/hyperdrive/guidelines/auth-pundit.md"))
      expect(File).to exist(path(".claude/hyperdrive/index.md"))
      expect(File.read(path("CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("state: present")
    end

    it "honors --skip-mcp (no .mcp.json, no mount, everything else still written)" do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      run_generator(["--skip-mcp"])
      expect(File).not_to exist(path(".mcp.json"))
      expect(File.read(path("config/routes.rb"))).not_to include("Rails::Hyperdrive::Engine")
      expect(File).to exist(path(".hyperdrive/lock.yml"))
      expect(File).to exist(path(".claude/hyperdrive/guidelines/auth-pundit.md"))
      expect(File.read(path(".gitignore"))).to include(".hyperdrive/discover_cache.json")
    end

    it "leaves pre-existing MCP configuration byte-identical under --skip-mcp" do
      mcp_json = %({\n  "mcpServers": {\n    "other": {\n      "url": "http://localhost:9000/mcp"\n    }\n  }\n}\n)
      routes = %(Rails.application.routes.draw do\n  mount Rails::Hyperdrive::Engine => "/admin/hyperdrive" if Rails.env.development?\nend\n)
      File.write(path(".mcp.json"), mcp_json)
      File.write(path("config/routes.rb"), routes)

      run_generator(["--skip-mcp"])
      expect(File.read(path(".mcp.json"))).to eq(mcp_json)
      expect(File.read(path("config/routes.rb"))).to eq(routes)
    end

    it "honors --skip-mcp --skip-content together" do
      File.write(path("Gemfile"), %(source "https://rubygems.org"\n))
      run_generator(["--skip-mcp", "--skip-content"])
      expect(File).not_to exist(path(".mcp.json"))
      expect(File.read(path("config/routes.rb"))).not_to include("Rails::Hyperdrive::Engine")
      expect(File).not_to exist(path(".claude"))
      expect(File).not_to exist(path("CLAUDE.md"))
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
      expect(File.read(path("Gemfile"))).to include('plugin "bundler-hyperdrive"')
      expect(File.read(path(".gitignore"))).to include(".hyperdrive/discover_cache.json")
    end

    it "ignores --mount-at under --skip-mcp" do
      out = run_generator(["--skip-mcp", "--mount-at", "/admin/hyperdrive"])
      expect(File).not_to exist(path(".mcp.json"))
      expect(File.read(path("config/routes.rb"))).not_to include("/admin/hyperdrive")
      expect(out).not_to match(/warn/i)
    end

    it "drops the mount, server, and next-steps lines from the --skip-mcp summary" do
      stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")])
      out = run_generator(["--skip-mcp"])
      expect(out).not_to match(/Mount:/)
      expect(out).not_to match(/MCP tools/)
      expect(out).not_to match(/Next steps/)
      expect(out).to include("MCP: skipped (--skip-mcp)")
      expect(out).to match(/Installed/)
    end

    it "writes .mcp.json and the mount on a later init after --skip-mcp" do
      run_generator(["--skip-mcp"])
      expect(File).not_to exist(path(".mcp.json"))

      run_generator([])
      expect(File.read(path(".mcp.json"))).to include("/_hyperdrive/mcp")
      expect(File.read(path("config/routes.rb"))).to include("Rails::Hyperdrive::Engine")
    end

    it "honors --mount-at in both the routes mount and the .mcp.json URL" do
      run_generator(["--mount-at", "/admin/hyperdrive"])
      expect(File.read(path("config/routes.rb"))).to include(%(mount Rails::Hyperdrive::Engine => "/admin/hyperdrive"))
      expect(File.read(path(".mcp.json"))).to include("/admin/hyperdrive/mcp")
    end

    it "writes no initializer" do
      run_generator(["--mount-at", "/admin/hyperdrive"])
      expect(File).not_to exist(path("config/initializers/hyperdrive.rb"))
    end

    it "skips the engine mount when config/routes.rb is absent" do
      File.delete(path("config/routes.rb"))
      out = run_generator([])
      expect(out).to match(%r{no config/routes\.rb found})
      expect(File).to exist(path(".mcp.json"))
    end

    it "refuses to run outside Rails.env.development?" do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      capture(:stderr) { run_generator([]) }
      expect(File).not_to exist(path(".mcp.json"))
    end

    it "refuses to run when not inside a Rails app" do
      allow(::Rails).to receive(:root).and_return(nil)
      capture(:stderr) { run_generator([]) }
      expect(File).not_to exist(path(".mcp.json"))
    end

    it "normalizes --mount-at without a leading slash" do
      run_generator(["--mount-at", "hyperdrive"])
      expect(File.read(path(".mcp.json"))).to include("/hyperdrive/mcp")
    end

    it "strips a trailing slash from --mount-at" do
      run_generator(["--mount-at", "/_hyperdrive/"])
      body = File.read(path(".mcp.json"))
      expect(body).to include("/_hyperdrive/mcp")
      expect(body).not_to include("/_hyperdrive//mcp")
    end
  end
end
