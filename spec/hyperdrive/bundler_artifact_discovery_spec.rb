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
        File.write(File.join(sdir, "SKILL.md"), <<~MD)
          ---
          name: cond
          description: d
          gem: "*"
          versions: "*"
          #{conditional_yaml.chomp}
          ---

          # cond
        MD
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

      def write_skill(files, frontmatter_extra: "")
        FileUtils.mkdir_p(skill_dir)
        files.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(skill_dir, rel)))
          File.write(File.join(skill_dir, rel), body)
        end
        File.write(File.join(skill_dir, "SKILL.md"), <<~MD)
          ---
          name: erb
          description: d
          gem: "*"
          versions: "*"
          #{frontmatter_extra.chomp}
          ---

          # erb
        MD
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
          frontmatter_extra: "conditional:\n  references/boom.md.erb:\n    gem: not_bundled"
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

    it "keeps the full skill body (frontmatter retained)" do
      skill = described_class.discover(specs: [dummy_spec]).find(&:skill?)
      expect(described_class.install_ready_body(skill)).to start_with("---")
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

    it "skips a file missing a required field" do
      write_skill("a", "---\nname: a\ndescription: d\n---\n\n# a\n")
      warnings = []
      described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings.join).to include("missing a required field")
    end

    it "skips a file with malformed YAML frontmatter" do
      write_skill("a", "---\nname: [unterminated\n---\n\n# a\n")
      warnings = []
      described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings.join).to include("malformed YAML frontmatter")
    end

    it "skips when the versions: requirement string is invalid (no raise)" do
      write_skill("a", "---\nname: a\ndescription: d\ngem: dummy_gem\nversions: garbage\n---\n\n# a\n")
      warnings = []
      expect(described_class.discover(specs: [spec], warnings: warnings)).to be_empty
      expect(warnings.join).to include("does not satisfy")
    end
  end

  describe "versions: multi-constraint parsing" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }
    let(:spec) { spec_double("dummy_gem", "1.4.2", @dir) }

    def write_skill(name, body)
      sdir = File.join(@dir, "lib", "dummy_gem", "hyperdrive", "skills", name)
      FileUtils.mkdir_p(sdir)
      File.write(File.join(sdir, "SKILL.md"), body)
    end

    it "accepts the documented comma-separated single-string form" do
      write_skill("a", <<~MD)
        ---
        name: a
        description: d
        gem: dummy_gem
        versions: ">= 1.0, < 2.0"
        ---

        # a
      MD
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings).to be_empty
      expect(results.map(&:name)).to include("a")
    end

    it "accepts the YAML-list form" do
      write_skill("b", <<~MD)
        ---
        name: b
        description: d
        gem: dummy_gem
        versions:
          - ">= 1.0"
          - "< 2.0"
        ---

        # b
      MD
      warnings = []
      results = described_class.discover(specs: [spec], warnings: warnings)
      expect(warnings).to be_empty
      expect(results.map(&:name)).to include("b")
    end

    it "still rejects an out-of-range version with either form" do
      write_skill("c", <<~MD)
        ---
        name: c
        description: d
        gem: dummy_gem
        versions: ">= 2.0, < 3.0"
        ---

        # c
      MD
      warnings = []
      expect(described_class.discover(specs: [spec], warnings: warnings)).to be_empty
      expect(warnings.join).to include("does not satisfy")
    end
  end

  describe "multi-target gem:" do
    around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:spec)      { spec_double("source_gem", "1.0.0", @dir) }
    let(:sidekiq)   { spec_double("sidekiq", "7.3.0", @dir.to_s + "/nope") }
    let(:solid)     { spec_double("solid_queue", "1.1.0", @dir.to_s + "/nope") }

    def write_skill(name, frontmatter)
      sdir = File.join(@dir, "lib", "source_gem", "hyperdrive", "skills", name)
      FileUtils.mkdir_p(sdir)
      File.write(File.join(sdir, "SKILL.md"), "---\nname: #{name}\ndescription: d\n#{frontmatter}---\n\n# #{name}\n")
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

    it "skips a list holding an entry that is not a gem name" do
      write_skill("jobs", "gem:\n  - sidekiq\n  - [nested]\nversions: \">= 0\"\n")
      results, warnings = discover(sidekiq)
      expect(results).to be_empty
      expect(warnings.join).to include("gem: must name a gem")
    end
  end

  describe "Artifact#to_h" do
    it "exposes the metadata fields without the body" do
      artifact = described_class.discover(specs: [dummy_spec]).find(&:skill?)
      h = artifact.to_h
      expect(h).to include(name: "dummy-skill", artifact_type: :skill, source_gem: "dummy_gem")
      expect(h).not_to have_key(:body)
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
