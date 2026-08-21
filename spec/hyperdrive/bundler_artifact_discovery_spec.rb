require "spec_helper"
require "rails/hyperdrive/bundler_artifact_discovery"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Hyperdrive::BundlerArtifactDiscovery do
  let(:dummy_root)     { File.expand_path("../fixtures/dummy_gem", __dir__) }
  let(:companion_root) { File.expand_path("../fixtures/companion_gem", __dir__) }

  def spec_double(name, version, path)
    instance_double(
      Gem::Specification,
      name: name,
      version: Gem::Version.new(version),
      full_gem_path: path,
      metadata: {}
    )
  end

  let(:dummy_spec)     { spec_double("dummy_gem", "1.4.2", dummy_root) }
  let(:companion_spec) { spec_double("companion_gem", "0.1.0", companion_root) }

  describe "skills (self-shipping: target == source)" do
    it "discovers the version-matching skill (1.x in, not 2.x)" do
      skills = described_class.discover(specs: [dummy_spec]).select(&:skill?)
      dummy = skills.find { |s| s.name == "dummy-skill" }
      expect(dummy.versions).to eq("~> 1.0")
      expect(dummy.path).to include("dummy-v1")
      expect(dummy.source_gem).to eq("dummy_gem")
      expect(dummy.target_gem).to eq(["dummy_gem"])
    end
  end

  describe "supporting files" do
    it "captures every file in the skill dir besides SKILL.md, with dir-relative paths and raw bodies" do
      skill = described_class.discover(specs: [dummy_spec]).find { |s| s.name == "dummy-skill" }
      expect(skill.support_files.map { |f| f[:path] })
        .to contain_exactly("examples/sample.rb", "references/deep-dive.md", "references/tips.md")

      reference = skill.support_files.find { |f| f[:path] == "references/deep-dive.md" }
      expect(reference[:body]).to eq(File.binread(File.join(File.dirname(skill.path), "references/deep-dive.md")))
    end

    it "excludes a nested file named SKILL.md" do
      Dir.mktmpdir do |dir|
        sdir = File.join(dir, "lib", "dummy_gem", "hyperdrive", "skills", "outer")
        FileUtils.mkdir_p(File.join(sdir, "nested"))
        File.write(File.join(sdir, "SKILL.md"),
          "---\nname: outer\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# outer\n")
        File.write(File.join(sdir, "nested", "SKILL.md"),
          "---\nname: nested\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# nested\n")
        File.write(File.join(sdir, "nested", "notes.md"), "notes\n")

        spec = spec_double("dummy_gem", "1.0.0", dir)
        outer = described_class.discover(specs: [spec]).find { |a| a.name == "outer" }
        expect(outer.support_files.map { |f| f[:path] }).to eq(["nested/notes.md"])
      end
    end

    it "rejects a relative path containing a .. segment" do
      Dir.mktmpdir do |dir|
        skill_dir = File.join(dir, "lib", "dummy_gem", "hyperdrive", "skills", "x")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"),
          "---\nname: x\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# x\n")
        File.write(File.join(dir, "lib", "dummy_gem", "hyperdrive", "evil.md"), "evil\n")

        # A real glob never emits ".." components; stub only the support-file
        # glob to exercise the defense-in-depth guard.
        allow(Dir).to receive(:glob).and_call_original
        allow(Dir).to receive(:glob).with(File.join(skill_dir, "**", "*"))
          .and_return([File.join(skill_dir, "..", "..", "evil.md")])

        spec = spec_double("dummy_gem", "1.0.0", dir)
        skill = described_class.discover(specs: [spec]).find { |a| a.name == "x" }
        expect(skill.support_files).to eq([])
      end
    end

    it "is always empty for guidelines" do
      guidelines = described_class.discover(specs: [dummy_spec]).select(&:guideline?)
      expect(guidelines.map(&:support_files)).to all(eq([]))
    end
  end

  describe "conditional supporting files (broad conditioning)" do
    def dummy_skill(*specs, warnings: [])
      described_class.discover(specs: specs, warnings: warnings)
                     .find { |a| a.name == "dummy-skill" && a.source_gem == "dummy_gem" }
    end

    it "gates a file out when its condition gem is not in the bundle" do
      skill = dummy_skill(dummy_spec)
      expect(skill.support_files.map { |f| f[:path] }).not_to include("references/conditional.md")
    end

    it "gates a file in when its condition gem is bundled (versions: omitted = unconstrained)" do
      skill = dummy_skill(dummy_spec, companion_spec)
      expect(skill.support_files.map { |f| f[:path] }).to include("references/conditional.md")
    end

    context "with tmpdir-built trees" do
      around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

      let(:spec)    { spec_double("source_gem", "1.0.0", @dir) }
      let(:sidekiq) { spec_double("sidekiq", "7.3.0", @dir.to_s + "/nope") }
      let(:solid)   { spec_double("solid_queue", "1.1.0", @dir.to_s + "/nope") }

      def write_skill(conditional_yaml, files: { "references/extra.md" => "extra\n" })
        sdir = File.join(@dir, "lib", "source_gem", "hyperdrive", "skills", "cond")
        FileUtils.mkdir_p(sdir)
        files.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(sdir, rel)))
          File.write(File.join(sdir, rel), body)
        end
        File.write(File.join(sdir, "SKILL.md"), "---\nname: cond\ndescription: d\n---\n\n# cond\n")
        entry_yaml = conditional_yaml.lines.map { |l| l.strip.empty? ? l : "    #{l}" }.join
        File.write(File.join(@dir, "hyperdrive.yml"), "skills:\n  cond:\n#{entry_yaml.chomp}\n")
      end

      def discover(*extra_specs, warnings: [])
        results = described_class.discover(specs: [spec, *extra_specs], warnings: warnings)
        [results.find { |a| a.name == "cond" }, warnings]
      end

      def paths(skill) = skill.support_files.map { |f| f[:path] }

      it "matches any listed target (YAML list form)" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              gem:
                - sidekiq
                - solid_queue
        YAML
        skill, warnings = discover(solid)
        expect(warnings).to be_empty
        expect(paths(skill)).to include("references/extra.md")
      end

      it "constrains each target independently with a map versions:" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              gem: "sidekiq, solid_queue"
              versions:
                sidekiq: ">= 8.0"
                solid_queue: ">= 2.0"
        YAML
        skill, = discover(sidekiq, solid)
        expect(paths(skill)).to be_empty

        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              gem: "sidekiq, solid_queue"
              versions:
                sidekiq: ">= 8.0"
                solid_queue: ">= 1.0"
        YAML
        skill, = discover(sidekiq, solid)
        expect(paths(skill)).to include("references/extra.md")
      end

      it "applies a scalar versions: requirement" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              gem: sidekiq
              versions: ">= 8.0"
        YAML
        skill, warnings = discover(sidekiq)
        expect(warnings).to be_empty
        expect(paths(skill)).to be_empty
      end

      it "always installs a file conditioned on gem: \"*\"" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              gem: "*"
        YAML
        skill, warnings = discover
        expect(warnings).to be_empty
        expect(paths(skill)).to include("references/extra.md")
      end

      it "fails open when an entry is not a map" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md: sidekiq
        YAML
        skill, warnings = discover
        expect(warnings.join).to include("must be a map with gem:")
        expect(paths(skill)).to include("references/extra.md")
      end

      it "fails open when an entry has an empty value" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
        YAML
        skill, warnings = discover
        expect(warnings.join).to include("must be a map with gem:")
        expect(paths(skill)).to include("references/extra.md")
      end

      it "fails open when an entry has no usable gem:" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              versions: ">= 1.0"
        YAML
        skill, warnings = discover
        expect(warnings.join).to include("needs gem:")
        expect(paths(skill)).to include("references/extra.md")
      end

      it "fails open when versions: is unparsable" do
        write_skill(<<~YAML)
          conditional:
            references/extra.md:
              gem: sidekiq
              versions: garbage
        YAML
        skill, warnings = discover(sidekiq)
        expect(warnings.join).to include("unparsable versions:")
        expect(paths(skill)).to include("references/extra.md")
      end

      it "installs everything when conditional: is not a map" do
        write_skill("conditional: nope")
        skill, warnings = discover
        expect(warnings.join).to include("conditional: must be a map")
        expect(paths(skill)).to include("references/extra.md")
      end

      it "warns about a key naming no shipped supporting file" do
        write_skill(<<~YAML)
          conditional:
            references/typo.md:
              gem: sidekiq
        YAML
        skill, warnings = discover
        expect(warnings.join).to include("names no shipped supporting file")
        expect(paths(skill)).to include("references/extra.md")
      end

      it "warns about and ignores a SKILL.md key" do
        write_skill(<<~YAML)
          conditional:
            SKILL.md:
              gem: sidekiq
        YAML
        skill, warnings = discover
        expect(warnings.join).to include("gate the whole skill")
        expect(skill).not_to be_nil
      end
    end
  end

  describe "ERB supporting files (surgical conditioning)" do
    it "renders x.md.erb into support_files as x.md" do
      skill = described_class.discover(specs: [dummy_spec]).find { |s| s.name == "dummy-skill" }
      tips = skill.support_files.find { |f| f[:path] == "references/tips.md" }
      expect(tips[:body]).to eq("# Tips\n\nDummy gem 1.4.2 is present.\n")
      expect(skill.support_files.map { |f| f[:path] }).not_to include("references/tips.md.erb")
    end

    it "renders conditionally against the injected bundle" do
      skill = described_class.discover(specs: [dummy_spec, companion_spec])
                             .find { |s| s.name == "dummy-skill" && s.source_gem == "dummy_gem" }
      tips = skill.support_files.find { |f| f[:path] == "references/tips.md" }
      expect(tips[:body]).to include("Companion is bundled at 0.1.0.")
    end

    context "with tmpdir-built trees" do
      around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

      let(:spec) { spec_double("source_gem", "1.0.0", @dir) }

      def skill_dir
        File.join(@dir, "lib", "source_gem", "hyperdrive", "skills", "erb")
      end

      def write_skill(files, manifest: nil)
        FileUtils.mkdir_p(skill_dir)
        files.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(skill_dir, rel)))
          File.write(File.join(skill_dir, rel), body)
        end
        File.write(File.join(skill_dir, "SKILL.md"), "---\nname: erb\ndescription: d\n---\n\n# erb\n")
        File.write(File.join(@dir, "hyperdrive.yml"), manifest) if manifest
      end

      def discover(warnings: [])
        results = described_class.discover(specs: [spec], warnings: warnings)
        [results.find { |a| a.name == "erb" }, warnings]
      end

      it "skips a supporting file whose ERB raises, keeps the skill and its other files" do
        write_skill(
          {
            "references/broken.md.erb" => "<% raise 'boom' %>\n",
            "references/ok.md"         => "ok\n"
          }
        )
        skill, warnings = discover
        expect(warnings.join).to include("broken.md.erb").and include("ERB render failed")
        expect(skill.support_files.map { |f| f[:path] }).to contain_exactly("references/ok.md")
      end

      it "skips a supporting file whose ERB does not compile" do
        write_skill({ "references/broken.md.erb" => "<% if %>\n" })
        skill, warnings = discover
        expect(warnings.join).to include("ERB render failed")
        expect(skill.support_files).to eq([])
      end

      it "never renders a gated-out .md.erb file" do
        write_skill(
          { "references/boom.md.erb" => "<% raise 'must not render' %>\n" },
          manifest: "skills:\n  erb:\n    conditional:\n      references/boom.md.erb:\n        gem: not_bundled\n"
        )
        skill, warnings = discover
        expect(warnings).to be_empty
        expect(skill.support_files).to eq([])
      end

      it "prefers a plain x.md over x.md.erb rendering to the same path, with a warning" do
        write_skill(
          {
            "references/tips.md"     => "plain\n",
            "references/tips.md.erb" => "templated\n"
          }
        )
        skill, warnings = discover
        expect(warnings.join).to include("tips.md.erb").and include("takes precedence")
        tips = skill.support_files.find { |f| f[:path] == "references/tips.md" }
        expect(tips[:body]).to eq("plain\n")
      end
    end
  end

  describe "SKILL.md.erb skills" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:spec)    { spec_double("source_gem", "1.0.0", @dir) }
    let(:sidekiq) { spec_double("sidekiq", "7.3.0", @dir.to_s + "/nope") }

    def write(rel, body)
      path = File.join(@dir, "lib", "source_gem", "hyperdrive", "skills", rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    let(:template) { <<~MD }
      ---
      name: templated
      description: d
      gem: "*"
      versions: "*"
      ---

      # Templated

      <%- if gem?("sidekiq", ">= 7.0") -%>
      Sidekiq <%= gem_version("sidekiq") %> notes.
      <%- end -%>
    MD

    it "defines a skill whose body is the rendered markdown, frontmatter parsed post-render" do
      write("templated/SKILL.md.erb", template)
      skill = described_class.discover(specs: [spec, sidekiq]).find { |a| a.name == "templated" }
      expect(skill.body).to include("Sidekiq 7.3.0 notes.")
      expect(skill.body).not_to include("<%")
      expect(skill.target_gem).to eq(["*"])
    end

    it "skips the whole skill when SKILL.md.erb fails to render" do
      write("broken/SKILL.md.erb", "<% raise 'boom' %>\n")
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(results).to be_empty
      expect(warnings.join).to include("SKILL.md.erb").and include("ERB render failed")
    end

    it "prefers a plain SKILL.md over SKILL.md.erb in the same directory, with a warning" do
      write("both/SKILL.md", "---\nname: plain\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# plain\n")
      write("both/SKILL.md.erb", template)
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(results.map(&:name)).to contain_exactly("plain")
      expect(warnings.join).to include("SKILL.md.erb").and include("takes precedence")
    end

    it "excludes a nested SKILL.md.erb from the outer skill's supporting files" do
      write("outer/SKILL.md", "---\nname: outer\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# outer\n")
      write("outer/nested/SKILL.md.erb", template)
      write("outer/nested/notes.md", "notes\n")
      outer = described_class.discover(specs: [spec]).find { |a| a.name == "outer" }
      expect(outer.support_files.map { |f| f[:path] }).to eq(["nested/notes.md"])
    end
  end

  describe "guidelines" do
    it "discovers guidelines as a distinct artifact type" do
      guidelines = described_class.discover(specs: [dummy_spec]).select(&:guideline?)
      expect(guidelines.map(&:name)).to contain_exactly("dummy-guideline", "universal")
    end

    it "strips frontmatter from the install-ready guideline body" do
      guideline = described_class.discover(specs: [dummy_spec]).find { |a| a.name == "dummy-guideline" }
      body = described_class.install_ready_body(guideline)
      expect(body).not_to include("---")
      expect(body).not_to include("name: dummy-guideline")
      expect(body).to start_with("# Dummy Guideline")
    end

    it "installs the skill body verbatim, frontmatter included" do
      skill = described_class.discover(specs: [dummy_spec]).find { |a| a.name == "dummy-skill" }
      body = described_class.install_ready_body(skill)
      expect(body).to eq(File.read(skill.path))
      expect(body).to start_with("---")
      expect(body).to include("name: dummy-skill")
    end

    it "installs a skill carrying legacy installer keys verbatim, never reading them" do
      Dir.mktmpdir do |dir|
        sdir = File.join(dir, "lib", "dummy_gem", "hyperdrive", "skills", "jobs")
        FileUtils.mkdir_p(sdir)
        shipped = <<~SKILL
          ---
          name: jobs
          gem: some-absent-gem
          versions: ">= 99"
          description: d
          conditional:
            references/a.md:
              gem: some-absent-gem
          allowed-tools:
            - Read
          ---

          # jobs
        SKILL
        File.write(File.join(sdir, "SKILL.md"), shipped)

        spec = spec_double("dummy_gem", "1.0.0", dir)
        warnings = []
        skill = described_class.discover(specs: [spec], warnings: warnings).find { |a| a.name == "jobs" }
        expect(warnings).to be_empty
        expect(skill.target_gem).to eq(["*"])
        expect(described_class.install_ready_body(skill)).to eq(shipped)
      end
    end
  end

  describe "target/source split" do
    it "resolves frontmatter gem: against a DIFFERENT bundle gem" do
      results = described_class.discover(specs: [dummy_spec, companion_spec])
      companion = results.find { |a| a.name == "companion-skill" }
      expect(companion.source_gem).to eq("companion_gem")
      expect(companion.target_gem).to eq(["dummy_gem"])
    end

    it "skips an artifact whose target gem is absent from the bundle" do
      warnings = []
      results = described_class.discover(specs: [companion_spec], warnings: warnings)
      expect(results.map(&:name)).not_to include("companion-skill")
      expect(warnings.join).to include("target gem 'dummy_gem' not in bundle")
    end
  end

  describe "universal artifacts (gem: '*')" do
    it "matches without resolving a target or consulting versions" do
      universal = described_class.discover(specs: [companion_spec]).find { |a| a.name == "universal" }
      expect(universal).to be_nil

      universal = described_class.discover(specs: [dummy_spec]).find { |a| a.name == "universal" }
      expect(universal.target_gem).to eq(["*"])
    end
  end

  describe "Phase 1 — collapse within one source gem" do
    it "keeps one survivor per (name, source) for same-source duplicates" do
      survivors = described_class.discover(specs: [dummy_spec]).select { |a| a.name == "dummy-skill" }
      expect(survivors.size).to eq(1)
    end

    it "does NOT collapse across source gems (composite identity)" do
      survivors = described_class.discover(specs: [dummy_spec, companion_spec])
                                 .select { |a| a.name == "dummy-skill" }
      expect(survivors.map(&:source_gem)).to contain_exactly("dummy_gem", "companion_gem")
    end
  end

  describe "rails_hyperdrive_skills_dir override" do
    it "rejects an override containing .. segments" do
      Dir.mktmpdir do |dir|
        gem_root = File.join(dir, "gem_root")
        FileUtils.mkdir_p(gem_root)
        edir = File.join(dir, "outside", "evil")
        FileUtils.mkdir_p(edir)
        File.write(
          File.join(edir, "SKILL.md"),
          "---\nname: evil\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# evil\n"
        )
        spec = spec_double("dummy_gem", "1.0.0", gem_root)
        allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "../outside")
        expect(described_class.discover(specs: [spec])).to be_empty
      end
    end

    it "discovers skills from a valid override directory (union with convention)" do
      Dir.mktmpdir do |dir|
        odir = File.join(dir, "custom_skills", "extra")
        FileUtils.mkdir_p(odir)
        File.write(
          File.join(odir, "SKILL.md"),
          "---\nname: extra\ndescription: d\ngem: \"*\"\nversions: \">= 0\"\n---\n\n# extra\n"
        )
        spec = spec_double("dummy_gem", "1.0.0", dir)
        allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "custom_skills")
        expect(described_class.discover(specs: [spec]).map(&:name)).to include("extra")
      end
    end
  end

  describe "top-level skills/ root (companion opt-in gate)" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:skills_sh_root) { File.expand_path("../fixtures/skills_sh_gem", __dir__) }

    def write(rel, body)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def top_level_skill(name = "top")
      write("skills/#{name}/SKILL.md", "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n")
    end

    it "scans skills/ when the gem ships a convention-path artifact" do
      write("lib/some_gem/hyperdrive/guidelines/g.md", "---\nname: g\ndescription: d\n---\n\n# g\n")
      top_level_skill
      results = described_class.discover(specs: [spec_double("some_gem", "1.0.0", @dir)])
      expect(results.map(&:name)).to contain_exactly("g", "top")
    end

    it "scans skills/ when the gemspec declares rails_hyperdrive_targets" do
      top_level_skill
      spec = spec_double("some_gem", "1.0.0", @dir)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_targets" => "*")
      expect(described_class.discover(specs: [spec]).map(&:name)).to eq(["top"])
    end

    it "scans skills/ when the gemspec declares rails_hyperdrive_skills_dir" do
      top_level_skill
      write("custom/extra/SKILL.md", "---\nname: extra\ndescription: d\n---\n\n# extra\n")
      spec = spec_double("some_gem", "1.0.0", @dir)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "custom")
      expect(described_class.discover(specs: [spec]).map(&:name)).to contain_exactly("top", "extra")
    end

    it "does not double-discover when rails_hyperdrive_skills_dir points at skills/" do
      top_level_skill
      spec = spec_double("some_gem", "1.0.0", @dir)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "skills")
      results = described_class.discover(specs: [spec])
      expect(results.size).to eq(1)
      expect(results.first.name).to eq("top")
    end

    it "scans skills/ when the gem is named in enabled_gems" do
      spec = spec_double("skills_sh_gem", "1.0.0", skills_sh_root)
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings, enabled_gems: ["skills_sh_gem"])
      expect(warnings).to be_empty
      expect(results.map(&:name)).to eq(["pure-skill"])
      expect(results.first.target_gem).to eq(["*"])
    end

    it "never scans an un-opted gem's skills/" do
      top_level_skill
      results = described_class.discover(specs: [spec_double("some_gem", "1.0.0", @dir)])
      expect(results).to be_empty
    end

    it "treats a rejected ..-containing override as an opt-in signal while still ignoring its path" do
      top_level_skill
      spec = spec_double("some_gem", "1.0.0", @dir)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "../outside")
      expect(described_class.discover(specs: [spec]).map(&:name)).to eq(["top"])
    end

    it "scans skills/ when the gem ships a conventional hyperdrive.yml, even an empty one" do
      top_level_skill
      write("hyperdrive.yml", "")
      warnings = []
      results = described_class.discover(specs: [spec_double("some_gem", "1.0.0", @dir)], warnings: warnings)
      expect(warnings).to be_empty
      expect(results.map(&:name)).to eq(["top"])
    end

    it "scans skills/ when the gemspec declares rails_hyperdrive_manifest, even without the file" do
      top_level_skill
      spec = spec_double("some_gem", "1.0.0", @dir)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_manifest" => "config/hyperdrive.yml")
      expect(described_class.discover(specs: [spec]).map(&:name)).to eq(["top"])
    end

    it "treats a ..-containing manifest override as an opt-in signal, reading the conventional path instead" do
      top_level_skill
      write("hyperdrive.yml", "skills:\n  top:\n    gem: absent_gem\n")
      spec = spec_double("some_gem", "1.0.0", @dir)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_manifest" => "../outside.yml")
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(results).to be_empty
      expect(warnings.join).to include("target gem 'absent_gem' not in bundle")
    end

    it "pairs a skills/ content dir with a convention-path template into one artifact, no metadata needed" do
      write("lib/some_gem/hyperdrive/skills/both/SKILL.md.erb",
        "---\nname: both\ndescription: d\n---\n\n# templated\n")
      write("skills/both/SKILL.md", "---\nname: both\ndescription: d\n---\n\n# static\n")
      results = described_class.discover(specs: [spec_double("some_gem", "1.0.0", @dir)])
      expect(results.size).to eq(1)
      expect(results.first.path).to eq(File.join(@dir, "lib/some_gem/hyperdrive/skills/both/SKILL.md.erb"))
      expect(results.first.body).to include("templated")
      expect(results.first.support_root).to eq(File.join(@dir, "skills", "both"))
    end
  end

  describe "surfacing un-opted skills.sh gems" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:skills_sh_root) { File.expand_path("../fixtures/skills_sh_gem", __dir__) }

    def write(rel, body)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "reports an un-opted gem shipping skills.sh content, without installing it" do
      spec = spec_double("skills_sh_gem", "1.0.0", skills_sh_root)
      notices = []
      results = described_class.discover(specs: [spec], notices: notices)
      expect(results).to be_empty
      expect(notices.size).to eq(1)
      expect(notices.first).to include("skills_sh_gem").and include("1 skills.sh skill(s)").and include("enabled:")
    end

    it "counts one skill per directory" do
      write("skills/a/SKILL.md", "x")
      write("skills/b/SKILL.md", "x")
      notices = []
      described_class.discover(specs: [spec_double("some_gem", "1.0.0", @dir)], notices: notices)
      expect(notices.first).to include("2 skills.sh skill(s)")
    end

    it "ignores SKILL.md.erb when detecting skills.sh content" do
      write("skills/t/SKILL.md.erb", "x")
      notices = []
      expect(described_class.discover(specs: [spec_double("some_gem", "1.0.0", @dir)], notices: notices)).to be_empty
      expect(notices).to be_empty
    end

    it "emits no notice for an opted-in gem" do
      dummy = spec_double("dummy_gem", "1.4.2", File.expand_path("../fixtures/dummy_gem", __dir__))
      notices = []
      described_class.discover(specs: [dummy], notices: notices)
      expect(notices).to be_empty
    end

    it "emits no notice for a gem named in enabled_gems" do
      spec = spec_double("skills_sh_gem", "1.0.0", skills_sh_root)
      notices = []
      described_class.discover(specs: [spec], enabled_gems: ["skills_sh_gem"], notices: notices)
      expect(notices).to be_empty
    end
  end

  describe "permissive parser (warn + skip, never raise)" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }
    let(:spec) { spec_double("dummy_gem", "1.4.2", @dir) }

    def write_skill(name, body)
      sdir = File.join(@dir, "lib", "dummy_gem", "hyperdrive", "skills", name)
      FileUtils.mkdir_p(sdir)
      File.write(File.join(sdir, "SKILL.md"), body)
    end

    it "skips a file with no frontmatter" do
      write_skill("a", "# just a heading, no frontmatter\n")
      warnings = []
      expect(described_class.discover(specs: [spec], warnings: warnings)).to be_empty
      expect(warnings.join).to include("missing or malformed frontmatter")
    end

    it "skips a file missing name or description" do
      write_skill("a", "---\nname: a\n---\n\n# a\n")
      warnings = []
      expect(described_class.discover(specs: [spec], warnings: warnings)).to be_empty
      expect(warnings.join).to include("missing a required field (name, description)")
    end

    it "skips a file with malformed YAML frontmatter" do
      write_skill("a", "---\nname: [unterminated\n---\n\n# a\n")
      warnings = []
      described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings.join).to include("malformed YAML frontmatter")
    end

    it "warns and skips, never raises, on a frontmatter value of a disallowed class" do
      write_skill("a", "---\nname: a\ndescription: d\nat: 2024-01-01 10:00:00\n---\n\n# a\n")
      warnings = []
      expect(described_class.discover(specs: [spec], warnings: warnings)).to be_empty
      expect(warnings.join).to include("malformed YAML frontmatter")
    end

    it "installs ungated when a manifest versions: requirement is invalid (no raise, no skip)" do
      write_skill("a", "---\nname: a\ndescription: d\n---\n\n# a\n")
      File.write(File.join(@dir, "hyperdrive.yml"), "skills:\n  a:\n    gem: dummy_gem\n    versions: garbage\n")
      warnings = []
      skill = described_class.discover(specs: [spec], warnings: warnings).find { |s| s.name == "a" }
      expect(warnings.join).to include("unparsable versions:")
      expect(skill.target_gem).to eq(["*"])
    end
  end

  describe "relaxed frontmatter (skills.sh base contract)" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }
    let(:spec) { spec_double("dummy_gem", "1.4.2", @dir) }

    def write_skill(name, body)
      sdir = File.join(@dir, "lib", "dummy_gem", "hyperdrive", "skills", name)
      FileUtils.mkdir_p(sdir)
      File.write(File.join(sdir, "SKILL.md"), body)
    end

    def write_guideline(name, body)
      gdir = File.join(@dir, "lib", "dummy_gem", "hyperdrive", "guidelines")
      FileUtils.mkdir_p(gdir)
      File.write(File.join(gdir, "#{name}.md"), body)
    end

    it "parses a name+description-only skill with zero warnings, universal and unconstrained" do
      write_skill("a", "---\nname: a\ndescription: d\n---\n\n# a\n")
      warnings = []
      skill = described_class.discover(specs: [spec], warnings: warnings).find { |s| s.name == "a" }
      expect(warnings).to be_empty
      expect(skill.target_gem).to eq(["*"])
      expect(skill.versions).to be_nil
    end

    it "parses a name+description-only guideline with zero warnings" do
      write_guideline("g", "---\nname: g\ndescription: d\n---\n\n# g\n")
      warnings = []
      guideline = described_class.discover(specs: [spec], warnings: warnings).find { |a| a.name == "g" }
      expect(warnings).to be_empty
      expect(guideline).to be_guideline
      expect(guideline.target_gem).to eq(["*"])
    end

    it "treats a manifest entry gem: with absent versions: as unconstrained" do
      write_skill("a", "---\nname: a\ndescription: d\n---\n\n# a\n")
      File.write(File.join(@dir, "hyperdrive.yml"), "skills:\n  a:\n    gem: dummy_gem\n")
      warnings = []
      skill = described_class.discover(specs: [spec], warnings: warnings).find { |s| s.name == "a" }
      expect(warnings).to be_empty
      expect(skill.target_gem).to eq(["dummy_gem"])
      expect(skill.versions).to be_nil
    end

    it "warns and installs ungated on a manifest entry gem: with an unusable value" do
      write_skill("a", "---\nname: a\ndescription: d\n---\n\n# a\n")
      File.write(File.join(@dir, "hyperdrive.yml"), "skills:\n  a:\n    gem:\n")
      warnings = []
      skill = described_class.discover(specs: [spec], warnings: warnings).find { |s| s.name == "a" }
      expect(warnings.join).to include("gem: must name a gem")
      expect(skill.target_gem).to eq(["*"])
    end

    it "silently ignores frontmatter gem:/versions:/conditional: keys and installs them verbatim" do
      body = "---\nname: a\ndescription: d\ngem: some-absent-gem\nversions: \">= 99\"\n" \
             "conditional:\n  references/x.md:\n    gem: some-absent-gem\n---\n\n# a\n"
      write_skill("a", body)
      warnings = []
      skill = described_class.discover(specs: [spec], warnings: warnings).find { |s| s.name == "a" }
      expect(warnings).to be_empty
      expect(skill.target_gem).to eq(["*"])
      expect(skill.versions).to be_nil
      expect(described_class.install_ready_body(skill)).to eq(body)
    end

    it "parses a date-valued unknown key with zero warnings and installs it verbatim" do
      body = "---\nname: a\ndescription: d\ncreated: 2024-01-01\n---\n\n# a\n"
      write_skill("a", body)
      warnings = []
      skill = described_class.discover(specs: [spec], warnings: warnings).find { |s| s.name == "a" }
      expect(warnings).to be_empty
      expect(described_class.install_ready_body(skill)).to eq(body)
    end

    it "renders the install-ready body byte-identical to the shipped file" do
      write_skill("a", "---\nname: a\ndescription: d\n---\n\n# a\n")
      skill = described_class.discover(specs: [spec]).find { |s| s.name == "a" }
      expect(described_class.install_ready_body(skill)).to eq("---\nname: a\ndescription: d\n---\n\n# a\n")
    end
  end

  describe "manifest versions: multi-constraint parsing" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }
    let(:spec) { spec_double("dummy_gem", "1.4.2", @dir) }

    def write_skill(name, entry_yaml)
      sdir = File.join(@dir, "lib", "dummy_gem", "hyperdrive", "skills", name)
      FileUtils.mkdir_p(sdir)
      File.write(File.join(sdir, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n")
      entry = entry_yaml.lines.map { |l| l.strip.empty? ? l : "    #{l}" }.join
      File.write(File.join(@dir, "hyperdrive.yml"), "skills:\n  #{name}:\n#{entry.chomp}\n")
    end

    it "accepts the documented comma-separated single-string form" do
      write_skill("a", "gem: dummy_gem\nversions: \">= 1.0, < 2.0\"\n")
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings).to be_empty
      expect(results.map(&:name)).to include("a")
    end

    it "accepts the YAML-list form" do
      write_skill("b", "gem: dummy_gem\nversions:\n  - \">= 1.0\"\n  - \"< 2.0\"\n")
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings).to be_empty
      expect(results.map(&:name)).to include("b")
    end

    it "still rejects an out-of-range version with either form" do
      write_skill("c", "gem: dummy_gem\nversions: \">= 2.0, < 3.0\"\n")
      warnings = []
      expect(described_class.discover(specs: [spec], warnings: warnings)).to be_empty
      expect(warnings.join).to include("does not satisfy")
    end
  end

  describe "manifest multi-target gem:" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:spec)      { spec_double("source_gem", "1.0.0", @dir) }
    let(:sidekiq)   { spec_double("sidekiq", "7.3.0", @dir.to_s + "/nope") }
    let(:solid)     { spec_double("solid_queue", "1.1.0", @dir.to_s + "/nope") }

    def write_skill(name, entry_yaml)
      sdir = File.join(@dir, "lib", "source_gem", "hyperdrive", "skills", name)
      FileUtils.mkdir_p(sdir)
      File.write(File.join(sdir, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n")
      entry = entry_yaml.lines.map { |l| l.strip.empty? ? l : "    #{l}" }.join
      File.write(File.join(@dir, "hyperdrive.yml"), "skills:\n  #{name}:\n#{entry.chomp}\n")
    end

    def discover(*specs, warnings: [])
      [described_class.discover(specs: [spec, *specs], warnings: warnings), warnings]
    end

    it "installs when any declared target is present (YAML list form)" do
      write_skill("jobs", "gem:\n  - sidekiq\n  - solid_queue\nversions: \">= 0\"\n")
      results, warnings = discover(solid)
      expect(warnings).to be_empty
      expect(results.first.target_gem).to eq(["solid_queue"])
    end

    it "accepts the comma-separated string form" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions: \">= 0\"\n")
      results, = discover(sidekiq)
      expect(results.first.target_gem).to eq(["sidekiq"])
    end

    it "reports every matching target when several are bundled" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions: \">= 0\"\n")
      results, = discover(sidekiq, solid)
      expect(results.first.target_gem).to eq(%w[sidekiq solid_queue])
    end

    it "applies a scalar versions: to every declared target" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions: \">= 2.0\"\n")
      results, = discover(sidekiq, solid)
      expect(results.first.target_gem).to eq(["sidekiq"]) # solid_queue 1.1.0 is out of range
    end

    it "constrains each target independently with a map versions:" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions:\n  sidekiq: \">= 8.0\"\n  solid_queue: \">= 1.0\"\n")
      results, = discover(sidekiq, solid)
      expect(results.first.target_gem).to eq(["solid_queue"])
    end

    it "leaves targets absent from the versions: map unconstrained" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions:\n  sidekiq: \">= 8.0\"\n")
      results, = discover(sidekiq, solid)
      expect(results.first.target_gem).to eq(["solid_queue"])
    end

    it "is universal when \"*\" appears anywhere in the list" do
      write_skill("jobs", "gem: \"sidekiq, *\"\nversions: \">= 99\"\n")
      results, warnings = discover
      expect(warnings).to be_empty
      expect(results.first.target_gem).to eq(["*"])
    end

    it "skips when no declared target is in the bundle" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions: \">= 0\"\n")
      results, warnings = discover
      expect(results).to be_empty
      expect(warnings.join).to include("target gems 'sidekiq, solid_queue' not in bundle")
    end

    it "reports each present-but-unsatisfying target when none matches" do
      write_skill("jobs", "gem: \"sidekiq, solid_queue\"\nversions: \">= 99\"\n")
      results, warnings = discover(sidekiq, solid)
      expect(results).to be_empty
      expect(warnings.join).to include("sidekiq 7.3.0 does not satisfy")
      expect(warnings.join).to include("solid_queue 1.1.0 does not satisfy")
    end

    it "installs ungated when the list holds an entry that is not a gem name" do
      write_skill("jobs", "gem:\n  - sidekiq\n  - [nested]\nversions: \">= 0\"\n")
      results, warnings = discover(sidekiq)
      expect(warnings.join).to include("gem: must name a gem")
      expect(results.first.target_gem).to eq(["*"])
    end
  end

  describe "template/content pairing" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:sidekiq) { spec_double("sidekiq", "7.3.0", @dir.to_s + "/nope") }

    def paired_spec(metadata = { "rails_hyperdrive_skills_dir" => "skills" })
      s = spec_double("source_gem", "1.0.0", @dir)
      allow(s).to receive(:metadata).and_return(metadata)
      s
    end

    def write(rel, body)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def template_body(name = "paired")
      <<~MD
        ---
        name: #{name}
        description: d
        gem: "*"
        versions: "*"
        ---

        # #{name} (templated)

        <%- if gem?("sidekiq") -%>
        Sidekiq notes.
        <%- end -%>
      MD
    end

    def static_body(name = "paired")
      "---\nname: #{name}\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# #{name} (static)\n"
    end

    it "pairs a content dir with the same-relpath template dir into one artifact" do
      write("skills/paired/SKILL.md", static_body)
      write("skills/paired/references/notes.md", "notes\n")
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb", template_body)

      warnings = []
      results = described_class.discover(specs: [paired_spec], warnings: warnings)
      expect(warnings).to be_empty
      expect(results.size).to eq(1)

      skill = results.first
      expect(skill.name).to eq("paired")
      expect(skill.body).to include("# paired (templated)")
      expect(skill.body).not_to include("(static)")
      expect(skill.path).to eq(File.join(@dir, "lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb"))
      expect(skill.support_root).to eq(File.join(@dir, "skills/paired"))
      expect(skill.support_files.map { |f| f[:path] }).to contain_exactly("references/notes.md")
    end

    it "renders the paired template against the app's resolved bundle" do
      write("skills/paired/SKILL.md", static_body)
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb", template_body)

      without = described_class.discover(specs: [paired_spec]).first
      expect(without.body).not_to include("Sidekiq notes.")

      with = described_class.discover(specs: [paired_spec, sidekiq]).first
      expect(with.body).to include("Sidekiq notes.")
    end

    it "matches on the relative path from the root, so nested layouts pair" do
      write("skills/cat/nested/SKILL.md", static_body("nested"))
      write("lib/source_gem/hyperdrive/skills/cat/nested/SKILL.md.erb", template_body("nested"))

      results = described_class.discover(specs: [paired_spec])
      expect(results.size).to eq(1)
      expect(results.first.path).to end_with("lib/source_gem/hyperdrive/skills/cat/nested/SKILL.md.erb")
      expect(results.first.support_root).to eq(File.join(@dir, "skills/cat/nested"))
    end

    it "leaves a template-only dir a standalone skill with support_root beside the definition" do
      write("lib/source_gem/hyperdrive/skills/solo/SKILL.md.erb", template_body("solo"))

      skill = described_class.discover(specs: [paired_spec]).first
      expect(skill.name).to eq("solo")
      expect(skill.support_root).to eq(File.dirname(skill.path))
    end

    it "leaves a content-only dir a standalone static skill" do
      write("skills/solo/SKILL.md", static_body("solo"))

      skill = described_class.discover(specs: [paired_spec]).first
      expect(skill.body).to include("(static)")
      expect(skill.support_root).to eq(File.dirname(skill.path))
    end

    it "warns about and ignores extra files in the template dir" do
      write("skills/paired/SKILL.md", static_body)
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb", template_body)
      write("lib/source_gem/hyperdrive/skills/paired/references/stray.md", "stray\n")

      warnings = []
      skill = described_class.discover(specs: [paired_spec], warnings: warnings).first
      expect(warnings.join).to include("besides SKILL.md.erb")
      expect(skill.support_files).to eq([])
    end

    it "skips the artifact when the paired template fails to render, without a static fallback" do
      write("skills/paired/SKILL.md", static_body)
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb", "<% raise 'boom' %>\n")

      warnings = []
      results = described_class.discover(specs: [paired_spec], warnings: warnings)
      expect(results).to be_empty
      expect(warnings.join).to include("ERB render failed")
    end

    it "resolves a same-dir tie in the content dir first, then pairs the surviving SKILL.md" do
      write("skills/paired/SKILL.md", static_body)
      write("skills/paired/SKILL.md.erb", "<% raise 'never rendered' %>\n")
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb", template_body)

      warnings = []
      skill = described_class.discover(specs: [paired_spec], warnings: warnings).first
      expect(warnings.join).to include("SKILL.md in the same directory takes precedence")
      expect(skill.body).to include("(templated)")
      expect(skill.path).to eq(File.join(@dir, "lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb"))
    end

    it "honors rails_hyperdrive_skill_templates_dir" do
      write("skills/paired/SKILL.md", static_body)
      write("tpl/paired/SKILL.md.erb", template_body)

      spec = paired_spec(
        "rails_hyperdrive_skills_dir" => "skills",
        "rails_hyperdrive_skill_templates_dir" => "tpl"
      )
      skill = described_class.discover(specs: [spec]).first
      expect(skill.body).to include("(templated)")
      expect(skill.path).to eq(File.join(@dir, "tpl/paired/SKILL.md.erb"))
    end

    it "treats a blank templates dir as the default" do
      write("skills/paired/SKILL.md", static_body)
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb", template_body)

      spec = paired_spec(
        "rails_hyperdrive_skills_dir" => "skills",
        "rails_hyperdrive_skill_templates_dir" => "  "
      )
      skill = described_class.discover(specs: [spec]).first
      expect(skill.body).to include("(templated)")
    end

    it "rejects a templates dir containing .. segments, falling back to the default" do
      write("skills/paired/SKILL.md", static_body)
      outside = File.join(File.dirname(@dir), "outside-#{File.basename(@dir)}")
      FileUtils.mkdir_p(File.join(outside, "paired"))
      File.write(File.join(outside, "paired", "SKILL.md.erb"), template_body)

      spec = paired_spec(
        "rails_hyperdrive_skills_dir" => "skills",
        "rails_hyperdrive_skill_templates_dir" => "../#{File.basename(outside)}"
      )
      skill = described_class.discover(specs: [spec]).first
      expect(skill.body).to include("(static)")
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    it "at equal spec_version, the skills/... path wins the Phase-1 tiebreak" do
      write("skills/dup/SKILL.md", static_body("dup"))
      write("lib/source_gem/hyperdrive/skills/other/SKILL.md", static_body("dup"))

      survivors = described_class.discover(specs: [paired_spec]).select { |a| a.name == "dup" }
      expect(survivors.size).to eq(1)
      expect(survivors.first.path).to eq(File.join(@dir, "skills/dup/SKILL.md"))
    end
  end

  describe "gem-root manifest gating" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:spec)    { spec_double("source_gem", "1.0.0", @dir) }
    let(:sidekiq) { spec_double("sidekiq", "7.3.0", @dir.to_s + "/nope") }

    def write(rel, body)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def write_skill(name)
      write("lib/source_gem/hyperdrive/skills/#{name}/SKILL.md",
        "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n")
    end

    def write_guideline(name)
      write("lib/source_gem/hyperdrive/guidelines/#{name}.md",
        "---\nname: #{name}\ndescription: d\n---\n\n# #{name}\n")
    end

    def discover(*extra_specs, warnings: [])
      [described_class.discover(specs: [spec, *extra_specs], warnings: warnings), warnings]
    end

    it "applies gem-wide defaults to skills and guidelines alike" do
      write_skill("a")
      write_guideline("g")
      write("hyperdrive.yml", "gem: sidekiq\nversions: \">= 7.0\"\n")

      results, warnings = discover
      expect(results).to be_empty
      expect(warnings.join).to include("skip a").and include("skip g")

      results, warnings = discover(sidekiq, warnings: [])
      expect(warnings).to be_empty
      expect(results.map(&:target_gem)).to all(eq(["sidekiq"]))
    end

    it "lets a per-entry key override the default per key, inheriting the rest" do
      write_skill("a")
      write("hyperdrive.yml", "gem: sidekiq\nversions: \">= 99\"\nskills:\n  a:\n    versions: \">= 7.0\"\n")

      results, warnings = discover(sidekiq)
      expect(warnings).to be_empty
      expect(results.first.target_gem).to eq(["sidekiq"])
      expect(results.first.versions).to eq(">= 7.0")
    end

    it "inherits a top-level versions: into an entry that only names a gem:" do
      write_skill("a")
      write("hyperdrive.yml", "versions: \">= 99\"\nskills:\n  a:\n    gem: sidekiq\n")

      results, warnings = discover(sidekiq)
      expect(results).to be_empty
      expect(warnings.join).to include("sidekiq 7.3.0 does not satisfy '>= 99'")
    end

    it "un-gates an entry declaring gem: \"*\" against a gem-wide default" do
      write_skill("a")
      write("hyperdrive.yml", "gem: absent_gem\nskills:\n  a:\n    gem: \"*\"\n")

      results, warnings = discover
      expect(warnings).to be_empty
      expect(results.first.target_gem).to eq(["*"])
    end

    it "gates a guideline through its filename entry" do
      write_guideline("g")
      write_guideline("h")
      write("hyperdrive.yml", "guidelines:\n  g.md:\n    gem: absent_gem\n")

      results, warnings = discover
      expect(results.map(&:name)).to eq(["h"])
      expect(warnings.join).to include("skip g")
    end

    it "gates a template-paired skill through its content-dir relpath" do
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "skills")
      write("skills/paired/SKILL.md", "---\nname: paired\ndescription: d\n---\n\n# paired (static)\n")
      write("lib/source_gem/hyperdrive/skills/paired/SKILL.md.erb",
        "---\nname: paired\ndescription: d\n---\n\n# paired (templated)\n")
      write("hyperdrive.yml", "skills:\n  paired:\n    gem: sidekiq\n")

      results, warnings = discover
      expect(results).to be_empty
      expect(warnings.join).to include("target gem 'sidekiq' not in bundle")

      results, warnings = discover(sidekiq, warnings: [])
      expect(warnings).to be_empty
      expect(results.first.body).to include("(templated)")
      expect(results.first.target_gem).to eq(["sidekiq"])
    end

    it "warns about a skills: key naming no shipped skill directory" do
      write_skill("a")
      write("hyperdrive.yml", "skills:\n  renamed-away:\n    gem: sidekiq\n")

      results, warnings = discover
      expect(results.map(&:name)).to eq(["a"])
      expect(warnings.join).to include("manifest skills entry 'renamed-away' names no shipped skill directory")
    end

    it "warns about a guidelines: key naming no shipped guideline" do
      write_guideline("g")
      write("hyperdrive.yml", "guidelines:\n  gone.md:\n    gem: sidekiq\n")

      _results, warnings = discover
      expect(warnings.join).to include("manifest guidelines entry 'gone.md' names no shipped guideline")
    end

    it "does not report an unknown key for a skill dropped by an ERB render failure" do
      write("lib/source_gem/hyperdrive/skills/broken/SKILL.md.erb", "<% raise 'boom' %>\n")
      write("hyperdrive.yml", "skills:\n  broken:\n    gem: \"*\"\n")

      results, warnings = discover
      expect(results).to be_empty
      expect(warnings.join).to include("ERB render failed")
      expect(warnings.join).not_to include("names no shipped skill directory")
    end

    it "warns and proceeds as if absent on malformed manifest YAML" do
      write_skill("a")
      write("hyperdrive.yml", "skills: [unterminated\n")

      results, warnings = discover
      expect(warnings.join).to include("malformed YAML")
      expect(results.first.target_gem).to eq(["*"])
    end

    it "warns and proceeds as if absent when the manifest root is not a map" do
      write_skill("a")
      write("hyperdrive.yml", "- just\n- a\n- list\n")

      results, warnings = discover
      expect(warnings.join).to include("root must be a YAML map")
      expect(results.first.target_gem).to eq(["*"])
    end

    it "warns and ignores a non-map skills: section" do
      write_skill("a")
      write("hyperdrive.yml", "skills: nope\n")

      results, warnings = discover
      expect(warnings.join).to include("manifest skills: must be a map")
      expect(results.first.target_gem).to eq(["*"])
    end

    it "installs ungated — defaults not applied — on a malformed entry" do
      write_skill("a")
      write("hyperdrive.yml", "gem: absent_gem\nskills:\n  a: nope\n")

      results, warnings = discover
      expect(warnings.join).to include("manifest entry for 'a' must be a map")
      expect(results.first.target_gem).to eq(["*"])
    end

    it "warns once and ignores unusable gem-wide defaults" do
      write_skill("a")
      write("hyperdrive.yml", "gem: [nested_list_entry, [oops]]\nversions: \">= 1.0\"\n")

      results, warnings = discover
      expect(warnings.grep(%r{top-level gem:/versions:/hyperdrive_version: defaults are unusable}).size).to eq(1)
      expect(results.first.target_gem).to eq(["*"])
    end

    describe "hyperdrive_version: fence" do
      def discover_fenced(*extra_specs)
        warnings = []
        fence_warnings = []
        results = described_class.discover(specs: [spec, *extra_specs], warnings: warnings,
          fence_warnings: fence_warnings)
        [results, warnings, fence_warnings]
      end

      before { stub_const("Rails::Hyperdrive::VERSION", "0.6.0") }

      it "discovers an artifact whose fence the running installer satisfies" do
        write_skill("a")
        write_guideline("g")
        write("hyperdrive.yml", "hyperdrive_version: \">= 0.1\"\n")

        results, warnings, fence_warnings = discover_fenced
        expect(results.map(&:name)).to contain_exactly("a", "g")
        expect(warnings).to be_empty
        expect(fence_warnings).to be_empty
      end

      it "skips a fenced-out skill with an actionable upgrade warning" do
        write_skill("a")
        write("hyperdrive.yml", "hyperdrive_version: \">= 99\"\n")

        results, warnings, fence_warnings = discover_fenced
        expect(results).to be_empty
        expect(warnings).to eq(
          ["skill 'a' (from source_gem) requires rails-hyperdrive >= 99 (this is 0.6.0); " \
           "upgrade rails-hyperdrive to install it"]
        )
        expect(fence_warnings).to eq(warnings)
      end

      it "labels a fenced-out guideline by its own artifact type" do
        write_guideline("g")
        write("hyperdrive.yml", "guidelines:\n  g.md:\n    hyperdrive_version: \">= 99\"\n")

        results, _warnings, fence_warnings = discover_fenced
        expect(results).to be_empty
        expect(fence_warnings.first).to start_with("guideline 'g' (from source_gem) requires rails-hyperdrive >= 99")
      end

      it "renders a multi-part requirement as written, listed or comma-separated" do
        write_skill("a")
        write_skill("b")
        write("hyperdrive.yml", <<~YAML)
          skills:
            a:
              hyperdrive_version: [">= 0.1", "< 0.5"]
            b:
              hyperdrive_version: ">= 0.1, < 0.5"
        YAML

        results, _warnings, fence_warnings = discover_fenced
        expect(results).to be_empty
        expect(fence_warnings.size).to eq(2)
        expect(fence_warnings).to all(include("requires rails-hyperdrive >= 0.1, < 0.5 (this is 0.6.0)"))
      end

      it "lets a satisfied per-entry fence override an unsatisfied default" do
        write_skill("a")
        write_skill("b")
        write("hyperdrive.yml", "hyperdrive_version: \">= 99\"\nskills:\n  a:\n    hyperdrive_version: \">= 0\"\n")

        results, _warnings, fence_warnings = discover_fenced
        expect(results.map(&:name)).to eq(["a"])
        expect(fence_warnings.map { |w| w[/'\w+'/] }).to eq(["'b'"])
      end

      it "lets an unsatisfied per-entry fence override a satisfied default" do
        write_skill("a")
        write_skill("b")
        write("hyperdrive.yml", "hyperdrive_version: \">= 0.1\"\nskills:\n  a:\n    hyperdrive_version: \">= 99\"\n")

        results, _warnings, fence_warnings = discover_fenced
        expect(results.map(&:name)).to eq(["b"])
        expect(fence_warnings.map { |w| w[/'\w+'/] }).to eq(["'a'"])
      end

      it "reports only the fence when the target gem would also miss" do
        write_skill("a")
        write("hyperdrive.yml", "gem: absent_gem\nhyperdrive_version: \">= 99\"\n")

        results, warnings, = discover_fenced
        expect(results).to be_empty
        expect(warnings.size).to eq(1)
        expect(warnings.first).to include("requires rails-hyperdrive >= 99")
      end

      it "keeps an ordinary target-gem miss out of the fence collector" do
        write_skill("a")
        write("hyperdrive.yml", "gem: absent_gem\n")

        results, warnings, fence_warnings = discover_fenced
        expect(results).to be_empty
        expect(warnings.join).to include("target gem 'absent_gem' not in bundle")
        expect(fence_warnings).to be_empty
      end

      it "installs unfenced and ungated on a malformed top-level fence" do
        write_skill("a")
        write("hyperdrive.yml", "gem: sidekiq\nhyperdrive_version: garbage\n")

        results, warnings, fence_warnings = discover_fenced
        expect(results.first.target_gem).to eq(["*"])
        expect(warnings.grep(%r{top-level gem:/versions:/hyperdrive_version: defaults are unusable}).size).to eq(1)
        expect(fence_warnings).to be_empty
      end

      it "installs unfenced and ungated on a malformed per-entry fence" do
        write_skill("a")
        write("hyperdrive.yml", "gem: absent_gem\nskills:\n  a:\n    hyperdrive_version: garbage\n")

        results, warnings, fence_warnings = discover_fenced
        expect(results.first.target_gem).to eq(["*"])
        expect(warnings.grep(/unparsable hyperdrive_version:/).size).to eq(1)
        expect(fence_warnings).to be_empty
      end

      it "parses a manifest carrying only pre-fence keys with zero warnings" do
        write_skill("a")
        write("lib/source_gem/hyperdrive/skills/a/x.md", "x")
        write_guideline("g")
        write("hyperdrive.yml", <<~YAML)
          gem: sidekiq
          versions: ">= 7.0"
          skills:
            a:
              conditional:
                x.md: { gem: sidekiq }
          guidelines:
            g.md:
              gem: sidekiq
        YAML

        _results, warnings, fence_warnings = discover_fenced(sidekiq)
        expect(warnings).to be_empty
        expect(fence_warnings).to be_empty
      end
    end

    it "honors a rails_hyperdrive_manifest metadata path" do
      write_skill("a")
      write("config/hyperdrive.yml", "skills:\n  a:\n    gem: absent_gem\n")
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_manifest" => "config/hyperdrive.yml")

      results, warnings = discover
      expect(results).to be_empty
      expect(warnings.join).to include("target gem 'absent_gem' not in bundle")
    end
  end

  describe "Artifact#to_h" do
    it "exposes the metadata fields without the body" do
      artifact = described_class.discover(specs: [dummy_spec]).find(&:skill?)
      h = artifact.to_h
      expect(h).to include(name: "dummy-skill", artifact_type: :skill, source_gem: "dummy_gem")
      expect(h).not_to have_key(:body)
      expect(h).not_to have_key(:support_root)
    end
  end

  describe "when Bundler cannot resolve the bundle" do
    it "discovers nothing rather than raising" do
      allow(::Bundler).to receive(:load).and_raise(::Bundler::GemfileNotFound)
      expect(described_class.discover).to eq([])
    end
  end

  describe "permissive parser" do
    it "warns and skips on a version mismatch rather than raising" do
      old_spec = spec_double("dummy_gem", "2.5.0", dummy_root)
      warnings = []
      results = described_class.discover(specs: [old_spec], warnings: warnings)
      # dummy-skill v1 (~> 1.0) no longer matches 2.5.0; v2 (~> 2.0) does.
      dummy = results.find { |a| a.name == "dummy-skill" }
      expect(dummy.path).to include("dummy-v2")
    end
  end
end
