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
        kind: "guideline",
        source_gem: "rails-hyperdrive-sidekiq",
        source_version: "1.2.0",
        source_sha: "ab12cd34",
        installed_at: "2026-05-29T14:22:08Z"
      )
      File.write(path, lock.to_yaml)

      reloaded = described_class.load(path)
      expect(reloaded.claude_md_state).to eq("present")
      entry = reloaded.entry(".claude/hyperdrive/guidelines/jobs-sidekiq.md")
      expect(entry.kind).to eq("guideline")
      expect(entry.source_gem).to eq("rails-hyperdrive-sidekiq")
      expect(entry.source_version).to eq("1.2.0")
      expect(entry.source_label).to eq("rails-hyperdrive-sidekiq@1.2.0")
      expect(entry.source_sha).to eq("ab12cd34")
      expect(entry.installed_at).to eq("2026-05-29T14:22:08Z")
      expect(reloaded.guideline_paths).to eq([".claude/hyperdrive/guidelines/jobs-sidekiq.md"])
      expect(reloaded.entry(".claude/hyperdrive/guidelines/absent.md")).to be_nil
    end
  end

  it "writes a byte-stable lock file" do
    lock = described_class.new("/no/such/lock.yml")
    lock.claude_md_state = described_class::STATE_PRESENT
    lock.upsert(
      path: ".claude/skills/vcr/SKILL.md",
      kind: "skill",
      source_gem: "gem-a",
      source_version: "2.0.0",
      source_sha: "ff00",
      installed_at: "2026-05-29T14:22:09Z"
    )
    lock.upsert(
      path: ".claude/hyperdrive/guidelines/jobs-sidekiq.md",
      kind: "guideline",
      source_gem: "rails-hyperdrive-sidekiq",
      source_version: "1.2.0",
      source_sha: "ab12cd34",
      installed_at: "2026-05-29T14:22:08Z"
    )

    expect(lock.to_yaml).to eq(<<~YAML)
      ---
      version: 3
      claude_md:
        state: present
      files:
      - path: ".claude/hyperdrive/guidelines/jobs-sidekiq.md"
        artifact: guideline
        source: rails-hyperdrive-sidekiq@1.2.0
        source_sha: ab12cd34
        installed_at: '2026-05-29T14:22:08Z'
      - path: ".claude/skills/vcr/SKILL.md"
        artifact: skill
        source: gem-a@2.0.0
        source_sha: ff00
        installed_at: '2026-05-29T14:22:09Z'
    YAML
  end

  it "restores every Entry field after an Entry → YAML → Entry round-trip" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      lock = described_class.new(path)
      lock.upsert(
        path: ".claude/skills/vcr/SKILL.md",
        kind: "skill",
        source_gem: "gem-a",
        source_version: "2.0.0",
        source_sha: "ff00",
        installed_at: "2026-05-29T14:22:09Z"
      )
      original = lock.entry(".claude/skills/vcr/SKILL.md")
      File.write(path, lock.to_yaml)

      reloaded = described_class.load(path).entry(".claude/skills/vcr/SKILL.md")
      expect(reloaded).to eq(original)
    end
  end

  it "loads a hand-written lock file into Entries" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      File.write(path, <<~YAML)
        version: 1
        claude_md:
          state: present
        disabled:
          skills: []
          guidelines: []
        files:
        - path: ".claude/hyperdrive/guidelines/service-objects.md"
          artifact: guideline
          source: rails-hyperdrive-alpha@0.3.0
          source_sha: deadbeef
          installed_at: '2026-05-29T14:22:08Z'
      YAML

      entry = described_class.load(path).entry(".claude/hyperdrive/guidelines/service-objects.md")
      expect(entry.kind).to eq("guideline")
      expect(entry.source_gem).to eq("rails-hyperdrive-alpha")
      expect(entry.source_version).to eq("0.3.0")
      expect(entry.source_sha).to eq("deadbeef")
      expect(entry.installed_at).to eq("2026-05-29T14:22:08Z")
    end
  end

  it "carries degenerate hand-edited sources through unchanged" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      File.write(path, <<~YAML)
        version: 1
        files:
        - path: no-at-sign.md
          artifact: guideline
          source: some-gem
          source_sha: aa
          installed_at: '2026-05-29T14:22:08Z'
        - path: no-source.md
          artifact: guideline
          source_sha: bb
          installed_at: '2026-05-29T14:22:08Z'
      YAML

      lock = described_class.load(path)

      no_at = lock.entry("no-at-sign.md")
      expect(no_at.source_gem).to eq("some-gem")
      expect(no_at.source_version).to be_nil
      expect(no_at.source_label).to eq("some-gem")

      no_source = lock.entry("no-source.md")
      expect(no_source.source_gem).to be_nil
      expect(no_source.source_version).to be_nil
      expect(no_source.source_label).to be_nil

      yaml = lock.to_yaml
      expect(yaml).to include("source: some-gem\n")
      expect(yaml).to include("- path: no-source.md\n  artifact: guideline\n  source:\n")
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
  end

  describe "the claude_md key" do
    it "is omitted entirely when no import line is being managed" do
      yaml = YAML.safe_load(described_class.new("/no/such/lock.yml").to_yaml)
      expect(yaml).not_to have_key("claude_md")
    end

    it "is dropped even when a stale state was carried in from disk" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, "version: 1\nclaude_md:\n  state: present\nfiles: []\n")

        rewritten = described_class.new(path).carry_document(described_class.load(path))
        expect(YAML.safe_load(rewritten.to_yaml)).not_to have_key("claude_md")
      end
    end

    it "is emitted for every recorded state" do
      [described_class::STATE_PRESENT, described_class::STATE_REMOVED].each do |state|
        lock = described_class.new("/no/such/lock.yml")
        lock.claude_md_state = state
        expect(YAML.safe_load(lock.to_yaml)["claude_md"]).to eq("state" => state)
      end
    end
  end

  describe "settings left behind by an older lock" do
    def write_lock(dir, body)
      File.join(dir, "lock.yml").tap { |path| File.write(path, body) }
    end

    it "reports them and names where they moved" do
      Dir.mktmpdir do |dir|
        path = write_lock(dir, "version: 2\ndisabled:\n  skills:\n    - vcr\nfiles: []\n")

        lock = described_class.load(path)
        expect(lock.legacy_settings?).to be(true)
        expect(lock.legacy_settings_message(".hyperdrive/lock.yml"))
          .to eq(".hyperdrive/lock.yml carries disabled:/enabled:; those settings now live in " \
                 ".hyperdrive/config.yml and are ignored here")
      end
    end

    it "reports an enabled: list too" do
      Dir.mktmpdir do |dir|
        path = write_lock(dir, "version: 2\nenabled:\n  - some_gem\nfiles: []\n")
        expect(described_class.load(path).legacy_settings?).to be(true)
      end
    end

    it "reports nothing for a lock carrying neither key" do
      Dir.mktmpdir do |dir|
        path = write_lock(dir, "version: 2\nfiles: []\n")
        expect(described_class.load(path).legacy_settings?).to be(false)
      end
      expect(described_class.load("/no/such/lock.yml").legacy_settings?).to be(false)
    end

    it "drops them on rewrite while other unknown keys still round-trip" do
      Dir.mktmpdir do |dir|
        path = write_lock(dir, <<~YAML)
          version: 2
          disabled:
            skills:
              - vcr
          enabled:
            - some_gem
          future_key:
            kept: yes
          files: []
        YAML

        rewritten = described_class.new(path).carry_document(described_class.load(path))
        document = YAML.safe_load(rewritten.to_yaml)
        expect(document).not_to have_key("disabled")
        expect(document).not_to have_key("enabled")
        expect(document["future_key"]).to eq("kept" => true)
      end
    end

    it "never emits either key for a lock that never had them" do
      document = YAML.safe_load(described_class.new("/no/such/lock.yml").to_yaml)
      expect(document).not_to have_key("disabled")
      expect(document).not_to have_key("enabled")
    end
  end

  describe "the schema version" do
    def load_with(version_line)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, "#{version_line}files: []\n")
        yield described_class.load(path)
      end
    end

    it "reads a lock written by a newer installer as ahead" do
      load_with("version: 4\n") do |lock|
        expect(lock.schema_ahead?).to be(true)
        expect(lock.schema_version).to eq(4)
        expect(lock.schema_ahead_message(".hyperdrive/lock.yml"))
          .to eq(".hyperdrive/lock.yml was written by a newer rails-hyperdrive (lock schema 4, " \
                 "this installer supports 3); upgrade rails-hyperdrive")
      end
    end

    it "still reads the rest of a schema-ahead lock, so the guard can report it" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "lock.yml")
        File.write(path, "version: 4\nclaude_md:\n  state: present\nfiles: []\n")

        expect(described_class.load(path).claude_md_state).to eq("present")
      end
    end

    it "is not ahead at the supported version, an older one, a missing one, or a non-numeric one" do
      load_with("version: 3\n") { |lock| expect(lock.schema_ahead?).to be(false) }
      load_with("version: 2\n") { |lock| expect(lock.schema_ahead?).to be(false) }
      load_with("version: 1\n") { |lock| expect(lock.schema_ahead?).to be(false) }
      load_with("") { |lock| expect(lock.schema_ahead?).to be(false) }
      load_with("version: two\n") { |lock| expect(lock.schema_ahead?).to be(false) }
    end

    it "is not ahead for an absent lock" do
      expect(described_class.load("/no/such/lock.yml").schema_ahead?).to be(false)
    end
  end

  it "preserves top-level keys it does not recognize" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.yml")
      File.write(path, "version: 1\nfuture_key:\n  kept: yes\nfiles: []\n")

      rewritten = described_class.new(path).carry_document(described_class.load(path))
      File.write(path, rewritten.to_yaml)

      expect(YAML.safe_load(File.read(path))["future_key"]).to eq("kept" => true)
    end
  end
end
