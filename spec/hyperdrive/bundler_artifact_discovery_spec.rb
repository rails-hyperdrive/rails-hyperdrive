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
      spec = spec_double("dummy_gem", "1.4.2", dummy_root)
      allow(spec).to receive(:metadata).and_return("rails_hyperdrive_skills_dir" => "../../etc")
      expect(described_class.skills_dir_override(spec)).to be_nil
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

  describe "safe_bundler_specs" do
    it "returns [] when Bundler cannot resolve the bundle" do
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
