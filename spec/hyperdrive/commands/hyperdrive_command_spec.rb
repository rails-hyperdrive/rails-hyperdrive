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
      expect(sync).to have_received(:start).with(["--merge"])
    end

    it "forwards flag values, whether space- or equals-separated" do
      perform("init", ["--mount-at", "/x"])
      perform("init", ["--mount-at=/x"])
      expect(install).to have_received(:start).with(["--mount-at", "/x"])
      expect(install).to have_received(:start).with(["--mount-at=/x"])
    end

    it "forwards flags it does not declare" do
      perform("sync", ["--not-a-hyperdrive-flag"])
      expect(sync).to have_received(:start).with(["--not-a-hyperdrive-flag"])
    end

    it "forwards nothing when no flags are given" do
      perform("sync", [])
      expect(sync).to have_received(:start).with([])
    end
  end

  describe "the legacy `--`-separated form" do
    it "strips a leading separator" do
      perform("sync", ["--", "--merge"])
      expect(sync).to have_received(:start).with(["--merge"])
    end

    it "strips only one separator" do
      perform("sync", ["--", "--", "--merge"])
      expect(sync).to have_received(:start).with(["--", "--merge"])
    end

    it "leaves a separator that is not leading alone" do
      perform("sync", ["--merge", "--", "--dry-run"])
      expect(sync).to have_received(:start).with(["--merge", "--", "--dry-run"])
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

  describe "subcommand dispatch" do
    it "routes init to the install generator" do
      perform("init", ["--skip-content"])
      expect(install).to have_received(:start).with(["--skip-content"])
      expect(sync).not_to have_received(:start)
      expect(discover).not_to have_received(:start)
    end

    it "routes sync to the sync generator" do
      perform("sync", ["--sidecar"])
      expect(sync).to have_received(:start).with(["--sidecar"])
      expect(install).not_to have_received(:start)
      expect(discover).not_to have_received(:start)
    end

    it "routes discover to the discover generator" do
      perform("discover", ["--refresh"])
      expect(discover).to have_received(:start).with(["--refresh"])
      expect(install).not_to have_received(:start)
      expect(sync).not_to have_received(:start)
    end
  end
end
