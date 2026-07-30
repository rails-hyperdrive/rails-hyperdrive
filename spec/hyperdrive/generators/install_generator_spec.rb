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

  # By default, stub discovery to return no companion artifacts (zero-content
  # install) — individual examples override with `stub_discovery`.
  def stub_discovery(artifacts)
    allow(Rails::Hyperdrive::BundlerArtifactDiscovery)
      .to receive(:discover).and_return(artifacts)
  end

  def skill_artifact(name:, source:, body: nil)
    Artifact.new(
      name: name, description: "d", target_gem: ["dummy_gem"], versions: "~> 1.0",
      artifact_type: :skill, source_gem: source, path: "/x/#{name}/SKILL.md",
      body: body || "---\nname: #{name}\ndescription: d\ngem: dummy_gem\nversions: \"~> 1.0\"\n---\n\n# #{name}\n",
      spec_version: "1.0.0"
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

    it "preserves other servers under --update" do
      write_mcp_json(other_server)
      run_generator(["--update"])
      expect(mcp_json["mcpServers"]).to have_key("my-other-server")
    end

    it "preserves other servers under --force-install" do
      write_mcp_json(other_server)
      run_generator(["--force-install"])
      expect(mcp_json["mcpServers"]).to have_key("my-other-server")
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
        expect(File).to exist(path(".claude/hyperdrive/stack.md"))
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

  describe "zero-content install (no companions)" do
    it "generates stack.md, index.md, the lockfile, and a CLAUDE.md import line" do
      run_generator([])
      expect(File).to exist(path(".claude/hyperdrive/stack.md"))
      expect(File.read(path(".claude/hyperdrive/index.md"))).to include("@stack.md")
      expect(File).to exist(path(".hyperdrive/lock.yml"))
      expect(File.read(path("CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")
    end

    it "writes stack.md with an HTML audit header and a facts section" do
      run_generator([])
      body = File.read(path(".claude/hyperdrive/stack.md"))
      expect(body).to start_with("<!-- hyperdrive: source=internal@")
      expect(body).to include("## Stack")
      expect(body).to include("## MCP tools")
    end

    it "tracks stack.md in the lockfile as the internal source" do
      run_generator([])
      lock = File.read(path(".hyperdrive/lock.yml"))
      expect(lock).to include("artifact: stack")
      expect(lock).to include("source: internal@")
    end
  end

  # The discover cache is the one gitignored artifact; init writes the
  # rule so the cache never gets committed once `hyperdrive:discover` runs.
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

  describe "skill install (frontmatter kept, YAML audit header)" do
    before { stub_discovery([skill_artifact(name: "jobs-sidekiq", source: "rails-hyperdrive-sidekiq")]) }

    it "installs the skill with a YAML-comment audit header" do
      run_generator([])
      body = File.read(path(".claude/skills/jobs-sidekiq/SKILL.md"))
      expect(body).to start_with("---")
      expect(body).to include("# hyperdrive: source=rails-hyperdrive-sidekiq@1.0.0")
    end
  end

  describe "guideline install (frontmatter stripped, HTML audit header)" do
    before { stub_discovery([guideline_artifact(name: "auth-pundit", source: "rails-hyperdrive-pundit")]) }

    it "installs the guideline frontmatter-stripped with an HTML audit header" do
      run_generator([])
      body = File.read(path(".claude/hyperdrive/guidelines/auth-pundit.md"))
      expect(body).to start_with("<!-- hyperdrive: source=rails-hyperdrive-pundit@1.0.0 -->")
      expect(body).not_to include("name: auth-pundit")
      expect(body).to include("# auth-pundit")
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
      run_generator([])
      index = path(".claude/hyperdrive/index.md")
      File.write(index, "@stack.md\n") # user removed the guideline line
      run_generator([])
      expect(File.read(index)).not_to include("@guidelines/auth-pundit.md")
    end
  end

  describe "cross-source conflict (Phase 2 — install both, postfixed)" do
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

    it "force-overwrites a user-edited file on update" do
      run_generator([])
      gpath = path(".claude/hyperdrive/guidelines/auth-pundit.md")
      File.write(gpath, File.read(gpath) + "\nMY LOCAL EDIT\n")
      run_generator(["--update"])
      expect(File.read(gpath)).not_to include("MY LOCAL EDIT")
    end

    it "rewrites an unedited file when the gem ships new content (no --update needed)" do
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

  describe "discovery warnings surfaced in output" do
    it "prints a summary of skipped artifacts" do
      allow(Rails::Hyperdrive::BundlerArtifactDiscovery).to receive(:discover) do |warnings:, **_|
        warnings << "skip /x/SKILL.md: missing a required field (name, description, gem, versions)"
        []
      end
      out = run_generator([])
      expect(out).to include("discovery skipped 1 artifact(s)")
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

  describe "CLAUDE.md opt-out state machine" do
    before { stub_discovery([]) }

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

    it "adopts a pre-existing CLAUDE.md that already contains the import line (no lock yet)" do
      File.write(path("CLAUDE.md"), "# my notes\n\n@.claude/hyperdrive/index.md\n")
      run_generator([])
      body = File.read(path("CLAUDE.md"))
      expect(body.scan("@.claude/hyperdrive/index.md").length).to eq(1)
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("state: present")
    end

    it "flips state back to present when the user re-adds the import line" do
      run_generator([])
      File.write(path("CLAUDE.md"), "# my own notes\n") # remove the line
      run_generator([])
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("state: removed-by-user")

      File.write(path("CLAUDE.md"), "# my own notes\n\n@.claude/hyperdrive/index.md\n") # re-add manually
      run_generator([])
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("state: present")
    end
  end

  describe "flags" do
    it "honors --dry-run by writing no files" do
      run_generator(["--dry-run"])
      expect(File).not_to exist(path(".mcp.json"))
      expect(File).not_to exist(path(".claude/hyperdrive/stack.md"))
      expect(File.read(path("config/routes.rb"))).not_to include("Rails::Hyperdrive::Engine")
    end

    it "honors --skip-content (no .claude content, no CLAUDE.md, no lockfile, still writes .mcp.json)" do
      run_generator(["--skip-content"])
      expect(File).to exist(path(".mcp.json"))
      expect(File).not_to exist(path(".claude/hyperdrive/stack.md"))
      expect(File).not_to exist(path(".claude/hyperdrive/index.md"))
      expect(File).not_to exist(path("CLAUDE.md"))
      expect(File).not_to exist(path(".hyperdrive/lock.yml"))
    end

    it "reconstructs full content on a later init after --skip-content" do
      run_generator(["--skip-content"])
      run_generator([])
      expect(File).to exist(path(".claude/hyperdrive/stack.md"))
      expect(File).to exist(path(".claude/hyperdrive/index.md"))
      expect(File.read(path("CLAUDE.md"))).to include("@.claude/hyperdrive/index.md")
      expect(File.read(path(".hyperdrive/lock.yml"))).to include("state: present")
    end

    it "honors --mount-at and writes the initializer when non-default" do
      run_generator(["--mount-at", "/admin/hyperdrive"])
      expect(File.read(path(".mcp.json"))).to include("/admin/hyperdrive/mcp")
      expect(File).to exist(path("config/initializers/hyperdrive.rb"))
    end

    it "does NOT write the initializer when --mount-at is the default" do
      run_generator([])
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
