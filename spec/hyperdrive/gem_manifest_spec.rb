require "spec_helper"
require "rails/hyperdrive/gem_manifest"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Hyperdrive::GemManifest do
  around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

  def spec_double(metadata = {})
    instance_double(
      Gem::Specification,
      name: "source_gem",
      version: Gem::Version.new("1.0.0"),
      full_gem_path: @dir,
      metadata: metadata
    )
  end

  def write(rel, body)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def load_manifest(metadata: {}, warnings: [])
    [described_class.load(spec_double(metadata), warnings: warnings), warnings]
  end

  describe "gate resolution" do
    it "resolves an ungated gate when no manifest exists" do
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      gate = manifest.skill_gate("anything")
      expect(gate.targets).to eq(["*"])
      expect(gate.versions).to be_nil
      expect(gate.conditional).to be_nil
    end

    it "applies gem-wide defaults to skills and guidelines without entries" do
      write("hyperdrive.yml", "gems:\n  - railties: \">= 7.2\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: ["railties"], versions: { "railties" => ">= 7.2" })
      expect(manifest.guideline_gate("g.md").to_h)
        .to include(targets: ["railties"], versions: { "railties" => ">= 7.2" })
    end

    it "replaces the default gate wholesale when an entry names its own gem:" do
      write("hyperdrive.yml", <<~YAML)
        gems:
          - railties: ">= 7.2"
        skills:
          a:
            gem: sidekiq
          b: {}
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: ["sidekiq"], versions: nil)
      expect(manifest.skill_gate("b").to_h).to include(targets: ["railties"], versions: { "railties" => ">= 7.2" })
    end

    it "un-gates an entry declaring gem: \"*\" against a default" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gem: \"*\"\n")
      manifest, = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
    end

    it "exposes conditional: only on skill entries" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            conditional:
              references/x.md:
                gem: alba
        guidelines:
          g.md:
            conditional:
              nonsense: true
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").conditional).to eq("references/x.md" => { "gem" => "alba" })
      expect(manifest.guideline_gate("g.md").conditional).to be_nil
    end

    it "resolves an any:/all: map form to targets plus a match mode" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            gem:
              any: [sidekiq, solid_queue]
          b:
            gem:
              all: [devise, pundit]
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: %w[sidekiq solid_queue], match_mode: :any)
      expect(manifest.skill_gate("b").to_h).to include(targets: %w[devise pundit], match_mode: :all)
    end

    it "accepts the comma-separated string form inside an any:/all: map" do
      write("hyperdrive.yml", "skills:\n  a:\n    gem:\n      all: \"devise, pundit\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: %w[devise pundit], match_mode: :all)
    end

    it "applies a top-level all: default to entries that omit gem:" do
      write("hyperdrive.yml", "gem:\n  all: [devise, pundit]\nskills:\n  a: {}\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: %w[devise pundit], match_mode: :all)
      expect(manifest.guideline_gate("g.md").to_h).to include(targets: %w[devise pundit], match_mode: :all)
    end

    it "warns and drops a \"*\" member from all:, leaving the rest of the gate" do
      write("hyperdrive.yml", "skills:\n  a:\n    gem:\n      all: [devise, \"*\"]\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["devise"], match_mode: :all)
      expect(warnings.join).to include("'*' in all: is always satisfied; ignoring it")
    end

    it "warns and resolves universal when all: names nothing but \"*\"" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gem:\n      all: [\"*\"]\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
      expect(warnings.join).to include("'*' in all: is always satisfied")
    end

    it "warns once and drops a \"*\" member from a top-level all: default" do
      write("hyperdrive.yml", "gem:\n  all: [devise, \"*\"]\nskills:\n  a: {}\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["devise"], match_mode: :all)
      expect(manifest.guideline_gate("g.md").to_h).to include(targets: ["devise"], match_mode: :all)
      expect(warnings.grep(/top-level gem: '\*' in all: is always satisfied/).size).to eq(1)
    end

    it "resolves no fence when hyperdrive_version: is absent everywhere" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gem: sidekiq\n")
      manifest, = load_manifest
      expect(manifest.skill_gate("a").hyperdrive_version).to be_nil
      expect(manifest.skill_gate("unlisted").hyperdrive_version).to be_nil
    end

    it "applies a gem-wide hyperdrive_version: to skills and guidelines alike" do
      write("hyperdrive.yml", "hyperdrive_version: \">= 0.8\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").hyperdrive_version).to eq(">= 0.8")
      expect(manifest.guideline_gate("g.md").hyperdrive_version).to eq(">= 0.8")
    end

    it "overrides a gem-wide hyperdrive_version: per entry" do
      write("hyperdrive.yml", <<~YAML)
        hyperdrive_version: ">= 0.8"
        skills:
          a:
            hyperdrive_version: ">= 1.0"
          b:
            gem: sidekiq
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").hyperdrive_version).to eq(">= 1.0")
      expect(manifest.skill_gate("b").hyperdrive_version).to eq(">= 0.8")
    end

    it "un-fences an entry declaring hyperdrive_version: \">= 0\" against a default" do
      write("hyperdrive.yml", "hyperdrive_version: \">= 99\"\nskills:\n  a:\n    hyperdrive_version: \">= 0\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").hyperdrive_version).to eq(">= 0")
    end

    it "lists the declared skill and guideline keys" do
      write("hyperdrive.yml", "skills:\n  a:\n    gem: alba\nguidelines:\n  g.md:\n    gem: alba\n")
      manifest, = load_manifest
      expect(manifest.skill_keys).to eq(["a"])
      expect(manifest.guideline_keys).to eq(["g.md"])
    end
  end

  describe "member-level version requirements" do
    it "reads a pair member in a bare list as an any-match target with its own requirement" do
      write("hyperdrive.yml", "skills:\n  a:\n    gems:\n      - railties: \">= 7.0\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h)
        .to include(targets: ["railties"], versions: { "railties" => ">= 7.0" }, match_mode: :any)
    end

    it "mixes bare and pair members in one list, constraining only the pairs" do
      write("hyperdrive.yml", "skills:\n  a:\n    gems:\n      - sidekiq\n      - solid_queue: \">= 1.0\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h)
        .to include(targets: %w[sidekiq solid_queue], versions: { "solid_queue" => ">= 1.0" })
    end

    it "carries member requirements through the any: and all: map forms" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            gems:
              any:
                - sidekiq
                - solid_queue: ">= 1.0"
          b:
            gems:
              all:
                - devise: ">= 4.9"
                - pundit
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h)
        .to include(targets: %w[sidekiq solid_queue], versions: { "solid_queue" => ">= 1.0" }, match_mode: :any)
      expect(manifest.skill_gate("b").to_h)
        .to include(targets: %w[devise pundit], versions: { "devise" => ">= 4.9" }, match_mode: :all)
    end

    it "passes a comma-compound requirement whole rather than splitting it into targets" do
      write("hyperdrive.yml", "skills:\n  a:\n    gems:\n      - devise: \">= 4.9, < 6\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h)
        .to include(targets: ["devise"], versions: { "devise" => ">= 4.9, < 6" })
    end

    it "treats a \"*\" or null pair value as the equivalent bare member" do
      write("hyperdrive.yml", "skills:\n  a:\n    gems:\n      - sidekiq: \"*\"\n      - solid_queue:\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: %w[sidekiq solid_queue], versions: nil)
    end

    it "keeps a comma-separated string name-only" do
      write("hyperdrive.yml", "skills:\n  a:\n    gem: \"pg, mysql2\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: %w[pg mysql2], versions: nil)
    end

    it "warns and drops a \"*\" pair key, leaving the remaining members gating" do
      write("hyperdrive.yml", "skills:\n  a:\n    gems:\n      - sidekiq\n      - \"*\": \">= 1\"\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["sidekiq"], match_mode: :any)
      expect(warnings.join).to include("a version requirement on '*' is meaningless")
    end

    it "warns and drops a \"*\" pair key under all: too" do
      write("hyperdrive.yml", "skills:\n  a:\n    gems:\n      all:\n        - devise\n        - \"*\": \">= 1\"\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["devise"], match_mode: :all)
      expect(warnings.join).to include("a version requirement on '*' is meaningless")
    end

    it "resolves universal when a dropped \"*\" pair was the only member" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gems:\n      - \"*\": \">= 1\"\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
      expect(warnings.join).to include("a version requirement on '*' is meaningless")
      expect(warnings.join).not_to include("gem: must name a gem")
    end
  end

  describe "gems: alias" do
    it "reads gems: exactly like gem: at every position" do
      write("hyperdrive.yml", <<~YAML)
        gems: railties
        skills:
          a:
            gems:
              all: [devise, pundit]
        guidelines:
          g.md:
            gems: sidekiq
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("unlisted").targets).to eq(["railties"])
      expect(manifest.skill_gate("a").to_h).to include(targets: %w[devise pundit], match_mode: :all)
      expect(manifest.guideline_gate("g.md").targets).to eq(["sidekiq"])
    end

    it "warns and reads gems: when a map carries both keys" do
      write("hyperdrive.yml", "gem: railties\ngems: sidekiq\nskills:\n  a:\n    gem: alba\n    gems: pundit\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("unlisted").targets).to eq(["sidekiq"])
      expect(manifest.skill_gate("a").targets).to eq(["pundit"])
      expect(warnings.grep(/gem: and gems: are aliases; reading gems: and ignoring gem:/).size).to eq(2)
    end

    it "takes the gems: value even when it is the unusable one" do
      write("hyperdrive.yml", "skills:\n  a:\n    gem: railties\n    gems:\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
      expect(warnings.join).to include("gem: must name a gem")
    end
  end

  describe "retired versions: key" do
    it "warns once and leaves the gem-wide gate unconstrained" do
      write("hyperdrive.yml", "gem: railties\nversions: \">= 7.2\"\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["railties"], versions: nil)
      expect(warnings.grep(/top-level versions: is no longer supported/).size).to eq(1)
      expect(warnings.join).to include("put the requirement on the gem: member")
    end

    it "warns per entry and leaves the entry gate unconstrained" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            gem: sidekiq
            versions: ">= 8.0"
        guidelines:
          g.md:
            gem: sidekiq
            versions: ">= 8.0"
      YAML
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["sidekiq"], versions: nil)
      expect(manifest.guideline_gate("g.md").to_h).to include(targets: ["sidekiq"], versions: nil)
      expect(warnings.grep(/versions: is no longer supported/).size).to eq(2)
    end
  end

  describe "fence-first evaluation" do
    it "keeps an entry's own fence when its gem: is unparsable" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            gem:
              none: [sqlite3]
            hyperdrive_version: ">= 0.9"
      YAML
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h)
        .to include(targets: ["*"], versions: nil, hyperdrive_version: ">= 0.9")
      expect(warnings.join).to include("gem: must name a gem")
    end

    it "falls back to the gem-wide fence when an entry with an unparsable gem: declares none" do
      write("hyperdrive.yml", "hyperdrive_version: \">= 0.9\"\nskills:\n  a:\n    gem:\n      none: [sqlite3]\n")
      manifest, = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["*"], hyperdrive_version: ">= 0.9")
    end

    it "keeps the gem-wide fence on a non-map entry" do
      write("hyperdrive.yml", "gem: railties\nhyperdrive_version: \">= 0.9\"\nskills:\n  a: yes\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["*"], hyperdrive_version: ">= 0.9")
      expect(warnings.join).to include("manifest entry for 'a' must be a map")
    end

    it "installs unfenced on an entry's own malformed fence, never substituting the default" do
      write("hyperdrive.yml", <<~YAML)
        hyperdrive_version: ">= 0.9"
        skills:
          a:
            gem: sidekiq
            hyperdrive_version:
              min: "0.9"
      YAML
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["*"], hyperdrive_version: nil)
      expect(warnings.join).to include("unparsable hyperdrive_version:")
    end

    it "keeps a parseable top-level fence when the top-level gem: default is unusable" do
      write("hyperdrive.yml", "gem:\n  none: [sqlite3]\nhyperdrive_version: \">= 0.9\"\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("unlisted").to_h).to include(targets: ["*"], hyperdrive_version: ">= 0.9")
      expect(warnings.grep(/top-level gem: default is unusable/).size).to eq(1)
      expect(warnings.join).not_to include("hyperdrive_version: default is unusable")
    end

    it "keeps the top-level gem: default when only the top-level fence is malformed" do
      write("hyperdrive.yml", "gems:\n  - railties: \">= 7.2\"\nhyperdrive_version: garbage\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h)
        .to include(targets: ["railties"], versions: { "railties" => ">= 7.2" }, hyperdrive_version: nil)
      expect(warnings.grep(/top-level hyperdrive_version: default is unusable/).size).to eq(1)
      expect(warnings.join).not_to include("gem: default is unusable")
    end
  end

  describe "fail-open behavior" do
    it "warns and resolves ungated on a non-map entry, ignoring the defaults" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a: nope\n")
      manifest, warnings = load_manifest
      gate = manifest.skill_gate("a")
      expect(warnings.join).to include("manifest entry for 'a' must be a map")
      expect(gate.targets).to eq(["*"])
      expect(gate.versions).to be_nil
    end

    it "warns and resolves ungated on an entry gem: with an unusable value" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gem:\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
      expect(warnings.join).to include("gem: must name a gem")
    end

    it "warns and resolves ungated on a malformed gem: map, ignoring the defaults" do
      write("hyperdrive.yml", <<~YAML)
        gem: railties
        skills:
          both:
            gem:
              any: [sidekiq]
              all: [devise]
          neither:
            gem:
              some: [sidekiq]
          unknown:
            gem:
              all: [devise]
              extra: true
          unusable:
            gem:
              all:
          nested:
            gem:
              all:
                - [devise]
      YAML
      manifest, warnings = load_manifest
      %w[both neither unknown unusable nested].each do |key|
        expect(manifest.skill_gate(key).to_h).to include(targets: ["*"], versions: nil, match_mode: :any)
      end
      expect(warnings.grep(/gem: must name a gem/).size).to eq(5)
      expect(warnings.join).to include("or an any:/all: map")
    end

    it "warns and resolves ungated on a malformed list member" do
      write("hyperdrive.yml", <<~YAML)
        gem: railties
        skills:
          multi_pair:
            gems:
              - sidekiq: ">= 7.0"
                solid_queue: ">= 1.0"
          bad_requirement:
            gems:
              - sidekiq: garbage
          nested:
            gems:
              - [sidekiq]
          nil_member:
            gems:
              - sidekiq
              -
          nested_value:
            gems:
              - sidekiq:
                  any: ">= 7.0"
      YAML
      manifest, warnings = load_manifest
      %w[multi_pair bad_requirement nested nil_member nested_value].each do |key|
        expect(manifest.skill_gate(key).to_h).to include(targets: ["*"], versions: nil, match_mode: :any)
      end
      expect(warnings.grep(/gem: must name a gem/).size).to eq(5)
      expect(warnings.join).to include("name: requirement pairs")
    end

    it "warns and resolves ungated on a non-mode-key map, never reading it as name: requirement" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gem:\n      railties: \">= 7.0\"\n")
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["*"], versions: nil)
      expect(warnings.join).to include("gem: must name a gem")
    end

    it "warns and resolves ungated on a map used as an any:/all: value" do
      write("hyperdrive.yml", <<~YAML)
        gem: railties
        skills:
          one_pair:
            gems:
              any:
                sidekiq: ">= 7.0"
          two_pairs:
            gems:
              all:
                devise: ">= 4.9"
                pundit: ">= 2.0"
      YAML
      manifest, warnings = load_manifest
      %w[one_pair two_pairs].each do |key|
        expect(manifest.skill_gate(key).to_h).to include(targets: ["*"], versions: nil)
      end
      expect(warnings.grep(/gem: must name a gem/).size).to eq(2)
    end

    it "warns and resolves ungated on a malformed member in the gem-wide defaults" do
      write("hyperdrive.yml", "gems:\n  - sidekiq: garbage\nskills:\n  a: {}\n")
      manifest, warnings = load_manifest
      expect(warnings.grep(/top-level gem: default is unusable/).size).to eq(1)
      expect(manifest.skill_gate("a").targets).to eq(["*"])
    end

    it "warns and resolves ungated on an unparsable hyperdrive_version:, scalar or map" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            gem: sidekiq
            hyperdrive_version: garbage
          b:
            gem: sidekiq
            hyperdrive_version:
              rails-hyperdrive: ">= 0.8"
      YAML
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").to_h).to include(targets: ["*"], versions: nil, hyperdrive_version: nil)
      expect(manifest.skill_gate("b").to_h).to include(targets: ["*"], versions: nil, hyperdrive_version: nil)
      expect(warnings.grep(/unparsable hyperdrive_version:/).size).to eq(2)
    end

    it "warns once and ignores an unusable gem-wide gem: default" do
      write("hyperdrive.yml", "gem:\nskills:\n  a:\n    gem: sidekiq\n")
      manifest, warnings = load_manifest
      expect(warnings.grep(/top-level gem: default is unusable/).size).to eq(1)
      expect(manifest.skill_gate("unlisted").targets).to eq(["*"])
      expect(manifest.skill_gate("a").to_h).to include(targets: ["sidekiq"], versions: nil)
    end

    it "warns once and ignores a malformed gem: map in the gem-wide defaults" do
      write("hyperdrive.yml", "gem:\n  any: [sidekiq]\n  all: [devise]\nskills:\n  a: {}\n")
      manifest, warnings = load_manifest
      expect(warnings.grep(/top-level gem: default is unusable/).size).to eq(1)
      expect(manifest.skill_gate("a").targets).to eq(["*"])
    end

    it "warns and reads nothing from malformed YAML" do
      write("hyperdrive.yml", "skills: [unterminated\n")
      manifest, warnings = load_manifest
      expect(warnings.join).to include("malformed YAML")
      expect(manifest.skill_gate("a").targets).to eq(["*"])
    end

    it "warns and reads nothing from a non-map root" do
      write("hyperdrive.yml", "- a\n- b\n")
      manifest, warnings = load_manifest
      expect(warnings.join).to include("root must be a YAML map")
      expect(manifest.skill_keys).to be_empty
    end

    it "reads an empty file as an empty manifest with no warning" do
      write("hyperdrive.yml", "")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").targets).to eq(["*"])
    end

    it "warns and ignores a non-map skills: or guidelines: section" do
      write("hyperdrive.yml", "skills: nope\nguidelines:\n  - g.md\n")
      manifest, warnings = load_manifest
      expect(warnings.join).to include("manifest skills: must be a map")
      expect(warnings.join).to include("manifest guidelines: must be a map")
      expect(manifest.skill_keys).to be_empty
      expect(manifest.guideline_keys).to be_empty
    end
  end

  describe "path resolution (rails_hyperdrive_manifest)" do
    it "reads the manifest from the metadata path" do
      write("config/gating.yml", "gem: railties\n")
      manifest, warnings = load_manifest(metadata: { "rails_hyperdrive_manifest" => "config/gating.yml" })
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").targets).to eq(["railties"])
    end

    it "falls back to the conventional path on a ..-containing value" do
      write("hyperdrive.yml", "gem: railties\n")
      manifest, = load_manifest(metadata: { "rails_hyperdrive_manifest" => "../outside.yml" })
      expect(manifest.skill_gate("a").targets).to eq(["railties"])
    end

    it "falls back to the conventional path on a blank value" do
      write("hyperdrive.yml", "gem: railties\n")
      manifest, = load_manifest(metadata: { "rails_hyperdrive_manifest" => "  " })
      expect(manifest.skill_gate("a").targets).to eq(["railties"])
    end
  end

  describe ".opt_in?" do
    it "is true when the conventional file exists" do
      write("hyperdrive.yml", "")
      expect(described_class.opt_in?(spec_double)).to be true
    end

    it "is true when the metadata key is present, even without the file" do
      expect(described_class.opt_in?(spec_double("rails_hyperdrive_manifest" => "config/gating.yml"))).to be true
    end

    it "is false with neither signal" do
      expect(described_class.opt_in?(spec_double)).to be false
    end
  end
end
