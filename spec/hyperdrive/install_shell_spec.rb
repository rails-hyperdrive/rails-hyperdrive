require "spec_helper"
require "rails/hyperdrive/install_shell"
require "tmpdir"
require "fileutils"

RSpec.describe Rails::Hyperdrive::InstallShell do
  let(:root) { Dir.mktmpdir("hyperdrive-shell") }
  let(:io) { StringIO.new }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  subject(:shell) { described_class.new(root: root, io: io) }

  def read(rel) = File.read(File.join(root, rel))

  describe "#create_file" do
    it "writes the content, creating missing directories" do
      shell.create_file(".claude/agents/reviewer.md", "# reviewer\n")

      expect(read(".claude/agents/reviewer.md")).to eq("# reviewer\n")
      expect(io.string).to eq("      create  .claude/agents/reviewer.md\n")
    end

    it "overwrites an existing file" do
      shell.create_file("a.md", "first\n")
      shell.create_file("a.md", "second\n")

      expect(read("a.md")).to eq("second\n")
    end
  end

  describe "#append_to_file" do
    it "adds to the end of an existing file" do
      shell.create_file("CLAUDE.md", "# mine\n")

      shell.append_to_file("CLAUDE.md", "@.claude/hyperdrive/index.md\n")

      expect(read("CLAUDE.md")).to eq("# mine\n@.claude/hyperdrive/index.md\n")
      expect(io.string).to include("      append  CLAUDE.md")
    end
  end

  describe "#remove_file" do
    it "removes a file and reports it" do
      shell.create_file("a.md", "x\n")

      shell.remove_file("a.md")

      expect(File).not_to exist(File.join(root, "a.md"))
      expect(io.string).to include("      remove  a.md")
    end

    it "removes a directory whole" do
      shell.create_file("skills/x/SKILL.md", "x\n")

      shell.remove_file("skills/x")

      expect(File).not_to exist(File.join(root, "skills/x"))
    end
  end

  describe "with pretend: true" do
    subject(:shell) { described_class.new(root: root, io: io, pretend: true) }

    it "reports every write without touching the tree" do
      File.write(File.join(root, "CLAUDE.md"), "# mine\n")

      shell.create_file("a.md", "x\n")
      shell.append_to_file("CLAUDE.md", "appended\n")
      shell.remove_file("CLAUDE.md")

      expect(File).not_to exist(File.join(root, "a.md"))
      expect(read("CLAUDE.md")).to eq("# mine\n")
      expect(io.string.scan(/create|append|remove/)).to eq(%w[create append remove])
    end
  end

  describe "with no io" do
    subject(:shell) { described_class.new(root: root) }

    it "writes silently" do
      expect { shell.create_file("a.md", "x\n") }.not_to output.to_stdout

      expect(read("a.md")).to eq("x\n")
    end

    it "still accepts say and say_status" do
      expect { shell.say_status(:create, "a.md") }.not_to raise_error
      expect { shell.say("hello") }.not_to raise_error
    end
  end

  it "reports a plain message through say" do
    shell.say("hello")
    shell.say

    expect(io.string).to eq("hello\n\n")
  end

  it "expands the root it was given" do
    expect(described_class.new(root: "#{root}/./sub/..").root).to eq(File.expand_path(root))
  end
end
