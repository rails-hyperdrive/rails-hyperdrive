require "spec_helper"
require "rails/hyperdrive/config_file"
require "tmpdir"

RSpec.describe Rails::Hyperdrive::ConfigFile do
  def with_config(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, body)
      yield described_class.load(path)
    end
  end

  describe "an absent or empty file" do
    it "reads as empty with no warning when the file does not exist" do
      config = described_class.load("/no/such/config.yml")
      expect(config.exist?).to be(false)
      expect(config.enabled_gems).to eq([])
      expect(config.disabled?(:skill, "anything")).to be(false)
      expect(config.warnings).to be_empty
    end

    it "reads an empty file as a valid empty config" do
      with_config("") do |config|
        expect(config.exist?).to be(true)
        expect(config.enabled_gems).to eq([])
        expect(config.warnings).to be_empty
      end
    end

    it "reads a comments-only file as a valid empty config" do
      with_config("# nothing here yet\n") do |config|
        expect(config.enabled_gems).to eq([])
        expect(config.warnings).to be_empty
      end
    end
  end

  describe "a file that will not parse" do
    it "warns once and reads as empty" do
      with_config("disabled:\n  skills:\n   - a\n  - b\n") do |config|
        expect(config.warnings.size).to eq(1)
        expect(config.warnings.first).to start_with(".hyperdrive/config.yml could not be parsed (")
        expect(config.enabled_gems).to eq([])
        expect(config.disabled?(:skill, "a")).to be(false)
      end
    end

    it "warns once and reads as empty when the root is a list" do
      with_config("- one\n- two\n") do |config|
        expect(config.warnings).to eq([".hyperdrive/config.yml root is not a map; reading it as empty"])
        expect(config.enabled_gems).to eq([])
      end
    end

    it "warns once and reads as empty when the root is a scalar" do
      with_config("nonsense\n") do |config|
        expect(config.warnings).to eq([".hyperdrive/config.yml root is not a map; reading it as empty"])
      end
    end

    it "warns once and reads as empty when the file cannot be read at all" do
      allow(File).to receive(:read).and_raise(Errno::EACCES, "config.yml")

      with_config("enabled:\n  - some_gem\n") do |config|
        expect(config.warnings.size).to eq(1)
        expect(config.warnings.first).to start_with(".hyperdrive/config.yml could not be parsed (")
        expect(config.enabled_gems).to eq([])
      end
    end
  end

  describe "disabled:" do
    it "reads a per-kind list for every kind" do
      with_config(<<~YAML) do |config|
        disabled:
          skills:
            - vcr-cassettes
          guidelines:
            - service-objects
          agents:
            - reviewer
          commands:
            - analyze
      YAML
        expect(config.disabled?(:skill, "vcr-cassettes")).to be(true)
        expect(config.disabled?(:guideline, "service-objects")).to be(true)
        expect(config.disabled?(:agent, "reviewer")).to be(true)
        expect(config.disabled?(:command, "analyze")).to be(true)
        expect(config.disabled?(:skill, "service-objects")).to be(false)
        expect(config.warnings).to be_empty
      end
    end

    it "honours a collision-postfixed name" do
      with_config("disabled:\n  skills:\n    - vcr--gem_a\n") do |config|
        expect(config.disabled?(:skill, "vcr--gem_a")).to be(true)
        expect(config.disabled?(:skill, "vcr")).to be(false)
      end
    end

    it "strips names, drops blanks, and dedupes" do
      with_config("disabled:\n  skills:\n    - '  spaced  '\n    - ''\n    - spaced\n") do |config|
        expect(config.disabled?(:skill, "spaced")).to be(true)
        expect(config.disabled?(:skill, "")).to be(false)
        expect(config.warnings).to be_empty
      end
    end

    it "warns and ignores the whole section when it is not a map" do
      with_config("disabled: nonsense\n") do |config|
        expect(config.warnings)
          .to eq([".hyperdrive/config.yml disabled: must be a map of kind to list; ignoring it"])
        expect(config.disabled?(:skill, "anything")).to be(false)
      end
    end

    it "warns about one non-list kind and still reads its siblings" do
      with_config("disabled:\n  skills: vcr\n  guidelines:\n    - service-objects\n") do |config|
        expect(config.warnings)
          .to eq([".hyperdrive/config.yml disabled: skills: must be a list of names; ignoring it"])
        expect(config.disabled?(:skill, "vcr")).to be(false)
        expect(config.disabled?(:guideline, "service-objects")).to be(true)
      end
    end

    it "reads an explicitly empty kind without warning" do
      with_config("disabled:\n  skills:\n  guidelines: []\n") do |config|
        expect(config.warnings).to be_empty
        expect(config.disabled?(:skill, "anything")).to be(false)
      end
    end

    it "ignores an unknown kind silently" do
      with_config("disabled:\n  widgets:\n    - one\n  skills:\n    - vcr\n") do |config|
        expect(config.warnings).to be_empty
        expect(config.disabled?(:skill, "vcr")).to be(true)
      end
    end
  end

  describe "enabled:" do
    it "reads a flat list of gem names, stripped, blank-free, and deduped" do
      with_config("enabled:\n  - some_gem\n  - '  spaced  '\n  - ''\n  - some_gem\n") do |config|
        expect(config.enabled_gems).to eq(%w[some_gem spaced])
        expect(config.warnings).to be_empty
      end
    end

    it "warns and ignores a map" do
      with_config("enabled:\n  some_gem: true\n") do |config|
        expect(config.warnings)
          .to eq([".hyperdrive/config.yml enabled: must be a list of gem names; ignoring it"])
        expect(config.enabled_gems).to eq([])
      end
    end

    it "warns and ignores a bare string" do
      with_config("enabled: some_gem\n") do |config|
        expect(config.warnings)
          .to eq([".hyperdrive/config.yml enabled: must be a list of gem names; ignoring it"])
        expect(config.enabled_gems).to eq([])
      end
    end

    it "reads an explicitly empty list without warning" do
      with_config("enabled:\n") do |config|
        expect(config.enabled_gems).to eq([])
        expect(config.warnings).to be_empty
      end
    end
  end

  it "ignores unknown top-level keys silently" do
    with_config("future_key:\n  kept: yes\nenabled:\n  - some_gem\n") do |config|
      expect(config.warnings).to be_empty
      expect(config.enabled_gems).to eq(["some_gem"])
    end
  end
end
