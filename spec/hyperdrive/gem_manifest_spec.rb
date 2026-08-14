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
      write("hyperdrive.yml", "gem: railties\nversions: \">= 7.2\"\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: ["railties"], versions: ">= 7.2")
      expect(manifest.guideline_gate("g.md").to_h).to include(targets: ["railties"], versions: ">= 7.2")
    end

    it "overrides defaults per key, inheriting the keys an entry omits" do
      write("hyperdrive.yml", <<~YAML)
        gem: railties
        versions: ">= 7.2"
        skills:
          a:
            gem: sidekiq
          b:
            versions: ">= 8.0"
      YAML
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").to_h).to include(targets: ["sidekiq"], versions: ">= 7.2")
      expect(manifest.skill_gate("b").to_h).to include(targets: ["railties"], versions: ">= 8.0")
    end

    it "un-gates an entry declaring gem: \"*\" against a default" do
      write("hyperdrive.yml", "gem: railties\nskills:\n  a:\n    gem: \"*\"\n")
      manifest, = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
    end

    it "treats an explicitly nil versions: key as unconstrained, overriding the default" do
      write("hyperdrive.yml", "versions: \">= 7.2\"\nskills:\n  a:\n    versions:\n")
      manifest, warnings = load_manifest
      expect(warnings).to be_empty
      expect(manifest.skill_gate("a").versions).to be_nil
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

    it "lists the declared skill and guideline keys" do
      write("hyperdrive.yml", "skills:\n  a:\n    gem: alba\nguidelines:\n  g.md:\n    gem: alba\n")
      manifest, = load_manifest
      expect(manifest.skill_keys).to eq(["a"])
      expect(manifest.guideline_keys).to eq(["g.md"])
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

    it "warns and resolves ungated on an unparsable versions: requirement, scalar or map" do
      write("hyperdrive.yml", <<~YAML)
        skills:
          a:
            gem: sidekiq
            versions: garbage
          b:
            gem: sidekiq
            versions:
              sidekiq: also garbage
      YAML
      manifest, warnings = load_manifest
      expect(manifest.skill_gate("a").targets).to eq(["*"])
      expect(manifest.skill_gate("b").targets).to eq(["*"])
      expect(warnings.grep(/unparsable versions:/).size).to eq(2)
    end

    it "warns once and ignores unusable gem-wide defaults" do
      write("hyperdrive.yml", "gem:\nversions: garbage\nskills:\n  a:\n    gem: sidekiq\n")
      manifest, warnings = load_manifest
      expect(warnings.grep(/top-level gem:\/versions: defaults are unusable/).size).to eq(1)
      expect(manifest.skill_gate("unlisted").targets).to eq(["*"])
      expect(manifest.skill_gate("a").to_h).to include(targets: ["sidekiq"], versions: nil)
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
