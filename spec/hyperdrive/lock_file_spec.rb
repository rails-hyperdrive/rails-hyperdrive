require "spec_helper"
require "rails/hyperdrive/lock_file"
require "tmpdir"

RSpec.describe Rails::Hyperdrive::LockFile do
  it "round-trips through YAML" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      lock = described_class.new(path)
      lock.claude_md_state = described_class::STATE_PRESENT
      lock.upsert(
        path: ".claude/hyperdrive/guidelines/jobs-sidekiq.md",
        artifact: "guideline",
        source: "rails-hyperdrive-sidekiq@1.2.0",
        source_sha: "ab12cd34",
        installed_at: "2026-05-29T14:22:08Z"
      )
      File.write(path, lock.to_yaml)

      reloaded = described_class.load(path)
      expect(reloaded.claude_md_state).to eq("present")
      entry = reloaded.entry(".claude/hyperdrive/guidelines/jobs-sidekiq.md")
      expect(entry[:source]).to eq("rails-hyperdrive-sidekiq@1.2.0")
      expect(entry[:source_sha]).to eq("ab12cd34")
      expect(reloaded.guideline_paths).to eq([".claude/hyperdrive/guidelines/jobs-sidekiq.md"])
      expect(reloaded.known?(".claude/hyperdrive/guidelines/jobs-sidekiq.md")).to be(true)
      expect(reloaded.known?(".claude/hyperdrive/guidelines/absent.md")).to be(false)
    end
  end

  it "recovers from a malformed lock file (returns empty state, never raises)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      File.write(path, "files: [unterminated\n  : :\n")
      lock = nil
      expect { lock = described_class.load(path) }.not_to raise_error
      expect(lock.claude_md_state).to be_nil
      expect(lock.guideline_paths).to eq([])
    end
  end

  it "reports an absent lock as having no claude_md state" do
    lock = described_class.load("/no/such/lock.yml")
    expect(lock.claude_md_state).to be_nil
    expect(lock.exists?).to be(false)
  end

  it "defaults claude_md.state to present when serialized without one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      yaml = described_class.new(path).to_yaml
      expect(yaml).to include("state: present")
    end
  end

  describe "the disabled list" do
    it "serializes an empty list for both artifact types" do
      yaml = YAML.safe_load(described_class.new("/no/such/lock.yml").to_yaml)
      expect(yaml["disabled"]).to eq("skills" => [], "guidelines" => [])
    end

    it "reads a hand-written list and reports names as disabled" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, <<~YAML)
          version: 1
          claude_md:
            state: present
          disabled:
            skills:
              - vcr-cassettes
            guidelines:
              - service-objects
          files: []
        YAML

        lock = described_class.load(path)
        expect(lock.disabled?(:skill, "vcr-cassettes")).to be(true)
        expect(lock.disabled?(:guideline, "service-objects")).to be(true)
        expect(lock.disabled?(:skill, "service-objects")).to be(false)
        expect(lock.disabled?(:guideline, "vcr-cassettes")).to be(false)
        expect(lock.disabled(:skill)).to eq(["vcr-cassettes"])
      end
    end

    it "survives a read/write round-trip" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, "disabled:\n  skills:\n    - vcr-cassettes\n")

        rewritten = described_class.new(path).carry_settings(described_class.load(path))
        File.write(path, rewritten.to_yaml)

        expect(described_class.load(path).disabled?(:skill, "vcr-cassettes")).to be(true)
      end
    end

    it "ignores blank entries and reads a bare name as a one-entry list" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, "disabled:\n  skills:\n    - ''\n    - '  spaced  '\n  guidelines: service-objects\n")

        lock = described_class.load(path)
        expect(lock.disabled(:skill)).to eq(["spaced"])
        expect(lock.disabled(:guideline)).to eq(["service-objects"])
      end
    end

    it "tolerates a disabled key that is not a mapping" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, "disabled: nonsense\n")

        lock = described_class.load(path)
        expect(lock.disabled(:skill)).to eq([])
        expect(lock.disabled(:guideline)).to eq([])
      end
    end
  end

  it "preserves top-level keys it does not recognize" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      File.write(path, "version: 1\nfuture_key:\n  kept: yes\nfiles: []\n")

      rewritten = described_class.new(path).carry_settings(described_class.load(path))
      File.write(path, rewritten.to_yaml)

      expect(YAML.safe_load(File.read(path))["future_key"]).to eq("kept" => true)
    end
  end
end
