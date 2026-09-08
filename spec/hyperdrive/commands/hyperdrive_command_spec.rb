require "spec_helper"
require "rails/generators"
require "generators/hyperdrive/install/install_generator"
require "generators/hyperdrive/sync/sync_generator"
require "generators/hyperdrive/discover/discover_generator"
require "rails/commands/hyperdrive/hyperdrive_command"

RSpec.describe Rails::Command::HyperdriveCommand do
  let(:install)  { Rails::Generators::Hyperdrive::InstallGenerator }
  let(:sync)     { Rails::Generators::Hyperdrive::SyncGenerator }
  let(:discover) { Rails::Generators::Hyperdrive::DiscoverGenerator }

  before do
    allow(install).to receive(:start)
    allow(sync).to receive(:start)
    allow(discover).to receive(:start)
  end

  def perform(command, argv)
    described_class.perform(command, argv, {})
  end

  describe "argv forwarding" do
    it "forwards bare flags verbatim" do
      perform("sync", ["--merge"])
      expect(sync).to have_received(:start).with(["--merge"], destination_root: Rails.root.to_s)
    end

    it "forwards flag values, whether space- or equals-separated" do
      perform("init", ["--mount-at", "/x"])
      perform("init", ["--mount-at=/x"])
      expect(install).to have_received(:start).with(["--mount-at", "/x"], destination_root: Rails.root.to_s)
      expect(install).to have_received(:start).with(["--mount-at=/x"], destination_root: Rails.root.to_s)
    end

    it "forwards flags it does not declare" do
      perform("sync", ["--not-a-hyperdrive-flag"])
      expect(sync).to have_received(:start).with(["--not-a-hyperdrive-flag"], destination_root: Rails.root.to_s)
    end

    it "forwards nothing when no flags are given" do
      perform("sync", [])
      expect(sync).to have_received(:start).with([], destination_root: Rails.root.to_s)
    end
  end

  describe "the legacy `--`-separated form" do
    it "strips a leading separator" do
      perform("sync", ["--", "--merge"])
      expect(sync).to have_received(:start).with(["--merge"], destination_root: Rails.root.to_s)
    end

    it "strips only one separator" do
      perform("sync", ["--", "--", "--merge"])
      expect(sync).to have_received(:start).with(["--", "--merge"], destination_root: Rails.root.to_s)
    end

    it "leaves a separator that is not leading alone" do
      perform("sync", ["--merge", "--", "--dry-run"])
      expect(sync).to have_received(:start).with(["--merge", "--", "--dry-run"], destination_root: Rails.root.to_s)
    end
  end

  describe "the help surface" do
    def declared(command) = described_class.commands[command].options.keys.map(&:to_s)

    it "mirrors each generator's own flags" do
      expect(declared("init")).to contain_exactly("mount_at", "skip_content", "skip_mcp", "dry_run")
      expect(declared("sync")).to contain_exactly("overwrite", "merge", "sidecar", "dry_run", "resolve")
      expect(declared("discover")).to contain_exactly("refresh")
    end

    it "carries the generator's own default rather than a restated one" do
      expect(described_class.commands["init"].options[:mount_at].default)
        .to eq(install::DEFAULT_MOUNT_AT)
    end

    it "leaves Thor's inherited runtime options out" do
      expect(declared("init")).not_to include("force", "pretend", "quiet", "skip",
        "skip_namespace", "skip_collision_check")
    end
  end

  describe "the CLI surface" do
    it "exposes exactly the three hyperdrive commands" do
      # Thor registers every public method defined on the class as a command,
      # so a helper that escapes `no_commands` would show up in `bin/rails help`.
      expect(described_class.printing_commands.map(&:first))
        .to contain_exactly("hyperdrive:init", "hyperdrive:sync", "hyperdrive:discover")
    end
  end

  describe "the destination root" do
    # Reads all go through ::Rails.root; Thor would default the destination to
    # the cwd, so a run from a subdirectory would write outside the app.
    it "starts every generator at the app root" do
      perform("init", [])
      perform("sync", [])
      perform("discover", [])

      [install, sync, discover].each do |generator|
        expect(generator).to have_received(:start).with([], destination_root: Rails.root.to_s)
      end
    end
  end

  describe "subcommand dispatch" do
    it "routes init to the install generator" do
      perform("init", ["--skip-content"])
      expect(install).to have_received(:start).with(["--skip-content"], destination_root: Rails.root.to_s)
      expect(sync).not_to have_received(:start)
      expect(discover).not_to have_received(:start)
    end

    it "routes sync to the sync generator" do
      perform("sync", ["--sidecar"])
      expect(sync).to have_received(:start).with(["--sidecar"], destination_root: Rails.root.to_s)
      expect(install).not_to have_received(:start)
      expect(discover).not_to have_received(:start)
    end

    it "routes discover to the discover generator" do
      perform("discover", ["--refresh"])
      expect(discover).to have_received(:start).with(["--refresh"], destination_root: Rails.root.to_s)
      expect(install).not_to have_received(:start)
      expect(sync).not_to have_received(:start)
    end
  end
end
