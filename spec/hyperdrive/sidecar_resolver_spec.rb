require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"
require "rails/hyperdrive/install_pipeline"
require "rails/hyperdrive/install_shell"
require "rails/hyperdrive/sidecar_resolver"

RSpec.describe Rails::Hyperdrive::SidecarResolver do
  around do |example|
    Dir.mktmpdir { |dir| @root = dir; example.run }
  end

  attr_reader :root

  let(:dest) { ".claude/hyperdrive/guidelines/auth-pundit.md" }
  let(:sidecar) { "#{dest}.new" }
  let(:live_body) { "# auth-pundit\n\nrule.\nMY LOCAL EDIT\n" }
  let(:upstream_body) { "# auth-pundit\n\nrule v2.\n" }
  let(:io) { StringIO.new }
  let(:shell) { Rails::Hyperdrive::InstallShell.new(root: root, io: io) }

  def write(rel, body)
    file = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, body)
    file
  end

  def install_sidecar(body: upstream_body, locked: nil, ancestor: false)
    write(dest, live_body)
    write(sidecar, body)
    entry = {
      "path" => dest, "artifact" => "guideline", "source" => "rails-hyperdrive-pundit@2.0.0",
      "source_sha" => Rails::Hyperdrive::DriftVerdict.body_sha(locked || body),
      "installed_at" => "2026-01-01T00:00:00Z"
    }
    if ancestor
      entry.merge!("ancestor_source" => "rails-hyperdrive-pundit@1.0.0", "ancestor_sha" => "aa11",
        "ancestor_relpath" => "lib/x/hyperdrive/guidelines/auth-pundit.md")
    end
    write(".hyperdrive/lock.yml",
      { "version" => Rails::Hyperdrive::LockFile::SCHEMA_VERSION, "files" => [entry] }.to_yaml)
  end

  def lock
    Rails::Hyperdrive::LockFile.load(File.join(root, ".hyperdrive/lock.yml"))
  end

  def script(name, body)
    file = write(name, "#!/usr/bin/env ruby\n#{body}")
    File.chmod(0o755, file)
    file
  end

  def resolve(command:, sidecars: [], prompt_path: nil, dry_run: false)
    described_class.new(
      root: root, shell: shell, command: command, lock: lock,
      sidecars: sidecars, prompt_path: prompt_path, dry_run: dry_run
    ).call
  end

  def sidecar_entry(ancestor: nil, previous_source: nil)
    Rails::Hyperdrive::InstallPipeline::Sidecar.new(
      dest: dest, ancestor: ancestor, previous_source: previous_source
    )
  end

  # Copies the upstream body over the live file, the minimum a real resolver does.
  def accept_script
    script("bin/accept", %(File.write(ENV.fetch("HYPERDRIVE_MERGED"), File.read(ENV.fetch("HYPERDRIVE_REMOTE")))))
  end

  def dump_script
    script("bin/dump", <<~RUBY)
      require "yaml"
      File.write(File.join(__dir__, "..", "dump.yml"),
        { "argv" => ARGV, "env" => ENV.to_h.select { |k, _| k.start_with?("HYPERDRIVE_") }, "cwd" => Dir.pwd }.to_yaml)
    RUBY
  end

  def dump = YAML.safe_load(File.read(File.join(root, "dump.yml")))

  describe "the exit status contract" do
    it "deletes the sidecar and reports resolved when the command exits 0" do
      install_sidecar
      accept_script

      outcome = resolve(command: "bin/accept")

      expect(outcome.resolved).to eq([dest])
      expect(outcome.unresolved).to be_empty
      expect(File.read(File.join(root, dest))).to eq(upstream_body)
      expect(File).not_to exist(File.join(root, sidecar))
      expect(io.string).to match(/\bresolved.*auth-pundit\.md/)
    end

    it "deletes the sidecar even when the command wrote nothing" do
      install_sidecar
      script("bin/noop", "exit 0")

      expect(resolve(command: "bin/noop").resolved).to eq([dest])
      expect(File.read(File.join(root, dest))).to eq(live_body)
      expect(File).not_to exist(File.join(root, sidecar))
    end

    it "leaves the live file, the sidecar, and the lock alone when the command fails" do
      install_sidecar
      script("bin/fail", %($stderr.puts "not confident\\nsecond line"; exit 3))
      lock_before = File.read(File.join(root, ".hyperdrive/lock.yml"))

      outcome = resolve(command: "bin/fail")

      expect(outcome.resolved).to be_empty
      expect(outcome.unresolved).to eq([{ dest: dest, reason: "exit 3: not confident" }])
      expect(File.read(File.join(root, dest))).to eq(live_body)
      expect(File.read(File.join(root, sidecar))).to eq(upstream_body)
      expect(File.read(File.join(root, ".hyperdrive/lock.yml"))).to eq(lock_before)
      expect(io.string).to match(/unresolved.*exit 3/)
    end

    it "reports a missing executable instead of raising" do
      install_sidecar

      outcome = resolve(command: "bin/nope --flag")

      expect(outcome.unresolved.first[:dest]).to eq(dest)
      expect(outcome.unresolved.first[:reason]).to include("No such file")
      expect(File).to exist(File.join(root, sidecar))
    end

    it "reports a command that names no program" do
      install_sidecar

      expect(resolve(command: "   ").unresolved.first[:reason]).to include("names no program")
    end

    it "reports a command that cannot be split into words" do
      install_sidecar

      expect(resolve(command: %(bin/tool "unclosed)).unresolved.first[:reason])
        .to include("not a valid command line")
      expect(File).to exist(File.join(root, sidecar))
    end
  end

  describe "the knobs" do
    before do
      install_sidecar
      dump_script
    end

    it "substitutes every token and exports every HYPERDRIVE_ variable" do
      resolve(
        command: "bin/dump $LOCAL $REMOTE $MERGED $SOURCE $PREVIOUS_SOURCE $KIND --at=$LOCAL",
        sidecars: [sidecar_entry(previous_source: "rails-hyperdrive-pundit@1.0.0")]
      )

      argv, env = dump.values_at("argv", "env")
      live = File.join(root, dest)
      expect(argv).to eq([live, File.join(root, sidecar), live, "rails-hyperdrive-pundit@2.0.0",
        "rails-hyperdrive-pundit@1.0.0", "guideline", "--at=#{live}"])
      expect(env).to include(
        "HYPERDRIVE_LOCAL" => live,
        "HYPERDRIVE_REMOTE" => File.join(root, sidecar),
        "HYPERDRIVE_MERGED" => live,
        "HYPERDRIVE_SOURCE" => "rails-hyperdrive-pundit@2.0.0",
        "HYPERDRIVE_PREVIOUS_SOURCE" => "rails-hyperdrive-pundit@1.0.0",
        "HYPERDRIVE_KIND" => "guideline"
      )
      expect(env["HYPERDRIVE_PROMPT"]).to include(live)
      expect(dump["cwd"]).to eq(File.realpath(root))
    end

    it "passes the whole prompt as one argument" do
      resolve(command: "bin/dump $PROMPT")

      expect(dump["argv"].size).to eq(1)
      expect(dump["argv"].first).to include("You are resolving one file")
      expect(dump["argv"].first).to eq(dump["env"]["HYPERDRIVE_PROMPT"])
    end

    it "leaves an empty previous source when the lock had no earlier entry" do
      resolve(command: "bin/dump $PREVIOUS_SOURCE", sidecars: [sidecar_entry])

      expect(dump["argv"]).to eq([""])
      expect(dump["env"]["HYPERDRIVE_PREVIOUS_SOURCE"]).to eq("")
    end
  end

  describe "$BASE" do
    before do
      install_sidecar
      dump_script
    end

    it "materialises the ancestor in the system tmpdir for a sidecar written this run" do
      resolve(command: "bin/dump $BASE", sidecars: [sidecar_entry(ancestor: "# auth-pundit\n\nrule.\n")])

      base = dump["argv"].first
      expect(base).to start_with(Dir.tmpdir)
      expect(base).not_to start_with(File.realpath(root))
      expect(dump["env"]["HYPERDRIVE_BASE"]).to eq(base)
      expect(File).not_to exist(base)
    end

    it "rebuilds the base a leftover sidecar's lock entry recorded" do
      allow(Rails::Hyperdrive::AncestorLocator).to receive(:locate).and_return("# auth-pundit\n\nrule.\n")
      install_sidecar(ancestor: true)

      resolve(command: "bin/dump $BASE")

      base = dump["argv"].first
      expect(base).to start_with(Dir.tmpdir)
      expect(dump["env"]["HYPERDRIVE_BASE"]).to eq(base)
      expect(dump["env"]["HYPERDRIVE_PREVIOUS_SOURCE"]).to eq("rails-hyperdrive-pundit@1.0.0")
    end

    it "drops the token and the variable for a leftover sidecar with no ancestor" do
      resolve(command: "bin/dump $BASE --after")

      expect(dump["argv"]).to eq(["--after"])
      expect(dump["env"]).not_to have_key("HYPERDRIVE_BASE")
    end

    it "substitutes empty for a token that only embeds $BASE" do
      resolve(command: "bin/dump --base=$BASE")

      expect(dump["argv"]).to eq(["--base="])
    end

    it "unsets a HYPERDRIVE_BASE inherited from the caller" do
      ENV["HYPERDRIVE_BASE"] = "/somewhere/stale"

      resolve(command: "bin/dump $LOCAL")

      expect(dump["env"]).not_to have_key("HYPERDRIVE_BASE")
    ensure
      ENV.delete("HYPERDRIVE_BASE")
    end
  end

  describe "an edited sidecar" do
    it "is skipped, warned about, and left on disk" do
      install_sidecar(body: "my half-finished reconcile\n", locked: upstream_body)
      accept_script

      outcome = resolve(command: "bin/accept")

      expect(outcome.skipped).to eq([dest])
      expect(outcome.resolved).to be_empty
      expect(File.read(File.join(root, sidecar))).to eq("my half-finished reconcile\n")
      expect(File.read(File.join(root, dest))).to eq(live_body)
      expect(io.string).to include("sidecar locally modified")
    end
  end

  describe "a dry run" do
    it "prints what it would run and spawns nothing" do
      install_sidecar
      script("bin/marker", %(File.write(File.join(__dir__, "..", "ran"), "yes")))

      outcome = resolve(command: "bin/marker $PROMPT", dry_run: true)

      expect(io.string).to include("#{dest} (would run bin/marker)")
      expect(File).not_to exist(File.join(root, "ran"))
      expect(File).to exist(File.join(root, sidecar))
      expect(outcome.resolved).to be_empty
      expect(outcome.unresolved).to be_empty
    end
  end

  describe "the prompt" do
    before do
      install_sidecar
      dump_script
    end

    it "describes the ancestor when one is available" do
      resolve(command: "bin/dump $PROMPT", sidecars: [sidecar_entry(ancestor: "old\n")])

      expect(dump["argv"].first).to include("The common ancestor")
    end

    it "says the ancestor is unavailable when there is none" do
      resolve(command: "bin/dump $PROMPT")

      expect(dump["argv"].first).to include("BASE:   not available")
    end

    it "uses a template from the app when one is configured" do
      write("prompts/mine.md.erb", "Reconcile <%= local %> with <%= remote %> (<%= kind %>).\n")

      resolve(command: "bin/dump $PROMPT", prompt_path: "prompts/mine.md.erb")

      expect(dump["argv"].first)
        .to eq("Reconcile #{File.join(root, dest)} with #{File.join(root, sidecar)} (guideline).\n")
    end

    it "never substitutes knobs into the rendered prompt itself" do
      write("prompts/dollar.md.erb", "literal $LOCAL stays\n")

      resolve(command: "bin/dump $PROMPT", prompt_path: "prompts/dollar.md.erb")

      expect(dump["argv"].first).to eq("literal $LOCAL stays\n")
    end

    it "warns and falls back to the default when the app template will not render" do
      write("prompts/broken.md.erb", "<%= nope.boom %>\n")

      resolve(command: "bin/dump $PROMPT", prompt_path: "prompts/broken.md.erb")

      expect(io.string).to include("could not be rendered", "using the default prompt")
      expect(dump["argv"].first).to include("You are resolving one file")
    end

    it "warns and falls back to the default when the app template is unreadable" do
      resolve(command: "bin/dump $PROMPT", prompt_path: "prompts/missing.md.erb")

      expect(io.string).to include("could not be read", "using the default prompt")
      expect(dump["argv"].first).to include("You are resolving one file")
    end
  end

  it "keeps a value holding spaces as one argument" do
    Dir.mktmpdir("with space") do |spaced|
      @root = spaced
      install_sidecar
      dump_script

      resolve(command: "bin/dump $LOCAL")

      expect(dump["argv"]).to eq([File.join(spaced, dest)])
    end
  end

  it "ignores a <dest>.new the lock does not record" do
    install_sidecar
    write(".claude/hyperdrive/guidelines/stray.md.new", "orphan\n")
    accept_script

    outcome = resolve(command: "bin/accept")

    expect(outcome.resolved).to eq([dest])
    expect(File).to exist(File.join(root, ".claude/hyperdrive/guidelines/stray.md.new"))
  end
end
