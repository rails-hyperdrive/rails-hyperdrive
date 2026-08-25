require "spec_helper"
require "rails/hyperdrive/manifest_lint"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Hyperdrive::ManifestLint do
  around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

  def write(rel, body)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def write_gemspec(metadata = {})
    lines = metadata.map { |k, v| %(  s.metadata[#{k.inspect}] = #{v.inspect}\n) }
    write("companion.gemspec", <<~RUBY)
      Gem::Specification.new do |s|
        s.name    = "companion"
        s.version = "0.1.0"
        s.summary = "fixture"
        s.authors = ["fixture"]
      #{lines.join}end
    RUBY
  end

  def write_skill(rel, files: {})
    write("skills/#{rel}/SKILL.md", "---\nname: #{File.basename(rel)}\ndescription: d\n---\n\n# skill\n")
    files.each { |path, body| write("skills/#{rel}/#{path}", body) }
  end

  def write_guideline(name)
    write("lib/companion/hyperdrive/guidelines/#{name}", "# guideline\n")
  end

  # The templates root is a manifest key, so it has to be prepended to whatever
  # manifest an example goes on to write.
  def write_template_skill(support: true)
    @manifest_prefix = "skill_templates_dir: templates\n"
    write("templates/alpha/SKILL.md.erb", "---\nname: alpha\ndescription: d\n---\n")
    write("templates/alpha/references/tips.md.erb", "tips\n") if support
  end

  def problems(manifest)
    write("hyperdrive.yml", "#{@manifest_prefix}#{manifest}")
    described_class.check(dir: @dir).problems
  end

  before do
    write_gemspec
    write_skill("alpha", files: { "references/notes.md" => "notes\n" })
    write_guideline("jobs.md")
  end

  describe "a clean manifest" do
    it "reports nothing for every accepted gating form" do
      write("hyperdrive.yml", <<~YAML)
        gems:
          - railties: ">= 7.2"
        hyperdrive_version: ">= 0.8"
        skills:
          alpha:
            gems:
              all:
                - devise: ">= 4.9"
                - pundit
            hyperdrive_version: ">= 0.9"
            conditional:
              references/notes.md:
                gem:
                  any: [sidekiq, solid_queue]
        guidelines:
          jobs.md:
            gem: "pg, mysql2"
      YAML
      result = described_class.check(dir: @dir)

      expect(result.problems).to be_empty
      expect(result.manifest).to eq("hyperdrive.yml")
    end

    it "reports nothing when the gem ships no manifest" do
      result = described_class.check(dir: @dir)
      expect(result.problems).to be_empty
      expect(result.manifest).to be_nil
    end

    # The dangling key still opts the gem in as a companion, so everything
    # ships ungated with no other signal anywhere.
    it "fails when hyperdrive_manifest names a path that is not a file" do
      write_gemspec("hyperdrive_manifest" => "config/gating.yaml")

      result = described_class.check(dir: @dir)
      expect(result.manifest).to eq("config/gating.yaml")
      expect(result.problems).to eq(
        ["gemspec metadata hyperdrive_manifest names 'config/gating.yaml', which is not a file"]
      )
    end

    it "reads the manifest from the hyperdrive_manifest path" do
      write_gemspec("hyperdrive_manifest" => "config/gating.yml")
      write("config/gating.yml", "skills:\n  nope: {}\n")

      result = described_class.check(dir: @dir)
      expect(result.manifest).to eq("config/gating.yml")
      expect(result.problems).to eq(["skills entry 'nope' names no shipped skill directory"])
    end
  end

  describe "structure" do
    it "fails on malformed YAML" do
      expect(problems("skills: [unterminated\n").join).to include("malformed YAML")
    end

    it "fails on a non-map root" do
      expect(problems("- a\n- b\n")).to eq(["root must be a YAML map"])
    end

    it "fails on a non-map skills: section" do
      expect(problems("skills: nope\n").join).to include("skills: must be a map")
    end

    it "fails rather than raising on YAML the installer refuses to load" do
      expect(problems("hyperdrive_version: 2026-01-01\n").join).to include("unreadable")
      expect(problems("skills: &s {}\nguidelines: *s\n").join).to include("unreadable")
    end

    it "fails on a non-map entry" do
      expect(problems("skills:\n  alpha: yes\n")).to eq(["skills entry 'alpha' must be a map of gating keys"])
    end

    it "passes on an empty manifest" do
      expect(problems("")).to be_empty
    end
  end

  describe "directory keys" do
    it "accepts both, drawing no unknown-key problem" do
      write("custom/beta/SKILL.md", "---\nname: beta\ndescription: d\n---\n\n# skill\n")
      expect(problems("skills_dir: custom\nskill_templates_dir: templates\n")).to be_empty
    end

    it "fails on a non-string value" do
      expect(problems("skills_dir:\n  - a\n  - b\n"))
        .to eq(["top level: skills_dir: must be a directory path relative to the gem root"])
    end

    it "fails on a blank value" do
      expect(problems("skill_templates_dir: \"  \"\n"))
        .to eq(["top level: skill_templates_dir: must name a directory relative to the gem root"])
    end

    it "fails on a value containing .. segments" do
      expect(problems("skills_dir: ../outside\n"))
        .to eq(["top level: skills_dir: must not contain '..' segments"])
    end
  end

  describe "the agents: and commands: sections" do
    before do
      write("agents/reviewer.md", "---\nname: reviewer\ndescription: d\n---\n")
      write("commands/analyze.md", "# analyze\n")
    end

    it "accepts gated entries, the directory keys, and command_prefix" do
      expect(problems(<<~YAML)).to be_empty
        agents_dir: plugin/agents
        commands_dir: plugin/commands
        agents:
          reviewer.md:
            gem: railties
            hyperdrive_version: ">= 0.8"
        commands:
          command_prefix: layered-rails
          analyze.md:
            gems:
              all:
                - devise
                - pundit
      YAML
    end

    it "fails on an entry naming nothing the gem ships" do
      expect(problems("agents:\n  gone.md:\n    gem: railties\ncommands:\n  vanished.md: {}\n"))
        .to contain_exactly(
          "agents entry 'gone.md' names no shipped agent",
          "commands entry 'vanished.md' names no shipped command"
        )
    end

    it "fails on an unknown entry key, conditional: included" do
      expect(problems("commands:\n  analyze.md:\n    conditional: {}\n").join)
        .to include("commands entry 'analyze.md': unknown key 'conditional'")
    end

    it "fails on a command_prefix that is not a usable name prefix" do
      expect(problems("commands:\n  command_prefix:\n    - a\n"))
        .to eq(["commands: command_prefix: must be a name prefix with no path separators or '..' segments"])
      expect(problems("commands:\n  command_prefix: ../evil\n"))
        .to eq(["commands: command_prefix: must be a name prefix with no path separators or '..' segments"])
    end

    it "reads command_prefix nowhere else" do
      expect(problems("agents:\n  command_prefix: layered-rails\n"))
        .to contain_exactly(
          "agents entry 'command_prefix' names no shipped agent",
          "agents entry 'command_prefix' must be a map of gating keys"
        )
    end
  end

  describe "unknown keys" do
    it "fails at the top level" do
      expect(problems("skils:\n  alpha: {}\n").join).to include("top level: unknown key 'skils'")
    end

    it "fails in a skills entry" do
      expect(problems("skills:\n  alpha:\n    only_if: sidekiq\n").join)
        .to include("skills entry 'alpha': unknown key 'only_if'")
    end

    it "fails in a guidelines entry, which takes no conditional:" do
      expect(problems("guidelines:\n  jobs.md:\n    conditional: {}\n").join)
        .to include("guidelines entry 'jobs.md': unknown key 'conditional'")
    end

    it "fails in a conditional entry" do
      manifest = "skills:\n  alpha:\n    conditional:\n      references/notes.md:\n" \
                 "        gem: sidekiq\n        hyperdrive_version: \">= 0.9\"\n"
      expect(problems(manifest).join)
        .to include("skills entry 'alpha' conditional key 'references/notes.md': unknown key 'hyperdrive_version'")
    end

    it "points versions: and version: at the gem: member" do
      manifest = "versions: \">= 7\"\nskills:\n  alpha:\n    gem: sidekiq\n    version: \">= 8\"\n"
      expect(problems(manifest)).to contain_exactly(
        a_string_including("top level: 'versions:' is not a gating key; put the requirement on the gem: member"),
        a_string_including("skills entry 'alpha': 'version:' is not a gating key")
      )
    end

    it "suggests hyperdrive_version: for its plural near-miss" do
      expect(problems("hyperdrive_versions: \">= 0.9\"\n").join)
        .to include("unknown key 'hyperdrive_versions' (did you mean 'hyperdrive_version'?)")
    end
  end

  describe "gating values" do
    it "fails on a bare gem: map, which is never read as name: requirement" do
      expect(problems("skills:\n  alpha:\n    gem:\n      railties: \">= 7.0\"\n").join)
        .to include("skills entry 'alpha': gem: must name a gem")
    end

    it "fails on an unparsable member requirement" do
      expect(problems("skills:\n  alpha:\n    gems:\n      - sidekiq: garbage\n").join)
        .to include("skills entry 'alpha': gem: must name a gem")
    end

    it "fails on an unparsable hyperdrive_version:" do
      expect(problems("skills:\n  alpha:\n    hyperdrive_version:\n      min: \"0.9\"\n").join)
        .to include("skills entry 'alpha': hyperdrive_version: must be a version requirement")
    end

    it "fails when one map carries both gem: and gems:" do
      expect(problems("gem: railties\ngems: sidekiq\n").join)
        .to include("top level: gem: and gems: are aliases; keep only one")
    end

    it "fails on a \"*\" pair key carrying a requirement" do
      expect(problems("skills:\n  alpha:\n    gems:\n      - sidekiq\n      - \"*\": \">= 1\"\n").join)
        .to include("a version requirement on '*' is meaningless")
    end

    it "fails on a \"*\" inside all:" do
      expect(problems("skills:\n  alpha:\n    gems:\n      all: [devise, \"*\"]\n").join)
        .to include("'*' in all: is always satisfied")
    end
  end

  describe "keys naming nothing shipped" do
    it "fails on a skills key with no shipped directory" do
      expect(problems("skills:\n  beta:\n    gem: sidekiq\n"))
        .to eq(["skills entry 'beta' names no shipped skill directory"])
    end

    it "fails on a guidelines key with no shipped file" do
      expect(problems("guidelines:\n  models.md:\n    gem: sidekiq\n"))
        .to eq(["guidelines entry 'models.md' names no shipped guideline"])
    end

    it "matches a paired skill by its content-directory relpath" do
      write_template_skill(support: false)

      expect(problems("skills:\n  alpha:\n    gem: sidekiq\n")).to be_empty
    end
  end

  describe "conditional entries" do
    it "fails on a non-map conditional:" do
      expect(problems("skills:\n  alpha:\n    conditional: nope\n").join)
        .to include("conditional: must be a map of supporting-file path to a gating map")
    end

    it "fails on a key naming SKILL.md" do
      expect(problems("skills:\n  alpha:\n    conditional:\n      SKILL.md:\n        gem: sidekiq\n").join)
        .to include("conditional key 'SKILL.md': the entry's own gem: gates the whole skill")
    end

    it "fails on a key naming no shipped supporting file" do
      expect(problems("skills:\n  alpha:\n    conditional:\n      references/gone.md:\n        gem: sidekiq\n").join)
        .to include("conditional key 'references/gone.md': names no shipped supporting file")
    end

    it "matches a template-side supporting file by its shipped *.md.erb path" do
      write_template_skill

      manifest = "skills:\n  alpha:\n    conditional:\n      references/tips.md.erb:\n        gem: sidekiq\n"
      expect(problems(manifest)).to be_empty
    end

    it "matches a template-side supporting file by its rendered face too" do
      write_template_skill

      manifest = "skills:\n  alpha:\n    conditional:\n      references/tips.md:\n        gem: sidekiq\n"
      expect(problems(manifest)).to be_empty
    end

    it "fails when both spellings key the same template-side file" do
      write_template_skill

      manifest = "skills:\n  alpha:\n    conditional:\n      references/tips.md.erb:\n        gem: sidekiq\n" \
                 "      references/tips.md:\n        gem: solid_queue\n"
      expect(problems(manifest).join)
        .to include("conditional key 'references/tips.md.erb': 'references/tips.md' keys the same file")
    end

    it "fails on a non-map entry and on one without gem:" do
      manifest = <<~YAML
        skills:
          alpha:
            conditional:
              references/notes.md: yes
      YAML
      expect(problems(manifest).join).to include("conditional key 'references/notes.md': must be a map with gem:")

      manifest = "skills:\n  alpha:\n    conditional:\n      references/notes.md: {}\n"
      expect(problems(manifest).join).to include("conditional key 'references/notes.md': gem: is required")
    end
  end

  it "reports every problem rather than stopping at the first" do
    manifest = <<~YAML
      gem:
        railties: ">= 7.0"
      skills:
        beta:
          versions: ">= 1"
      guidelines:
        jobs.md:
          hyperdrive_version: garbage
    YAML

    expect(problems(manifest)).to contain_exactly(
      a_string_including("top level: gem: must name a gem"),
      a_string_including("skills entry 'beta' names no shipped skill directory"),
      a_string_including("skills entry 'beta': 'versions:' is not a gating key"),
      a_string_including("guidelines entry 'jobs.md': hyperdrive_version: must be a version requirement")
    )
  end

  describe "gemspec resolution" do
    it "raises when the directory has no gemspec" do
      FileUtils.rm(File.join(@dir, "companion.gemspec"))
      expect { described_class.check(dir: @dir) }
        .to raise_error(described_class::Error, /no \.gemspec found/)
    end

    it "accepts an explicit gemspec path" do
      write("hyperdrive.yml", "skills:\n  beta: {}\n")
      nested = File.join(@dir, "elsewhere")
      FileUtils.mkdir_p(nested)

      result = described_class.check(gemspec: File.join(@dir, "companion.gemspec"), dir: nested)
      expect(result.problems).to eq(["skills entry 'beta' names no shipped skill directory"])
    end
  end
end
