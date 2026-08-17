require "spec_helper"
require "rails/generators"
require "generators/hyperdrive/install/install_generator"
require "generators/hyperdrive/sync/sync_generator"

RSpec.describe Rails::Generators::Hyperdrive::ContentSyncSupport do
  describe "the steps Thor registers" do
    it "runs init's steps in order, with nothing the shared module contributes" do
      expect(Rails::Generators::Hyperdrive::InstallGenerator.commands.keys).to eq(%w[
        verify_environment discover_artifacts write_mcp_json ignore_discover_cache
        register_bundler_plugin mount_engine sync_content print_summary
      ])
    end

    it "runs sync's steps in order, with nothing the shared module contributes" do
      expect(Rails::Generators::Hyperdrive::SyncGenerator.commands.keys)
        .to eq(%w[verify_options verify_environment discover_artifacts sync_content print_summary])
    end
  end

  describe "#options" do
    def generator(argv) = Rails::Generators::Hyperdrive::SyncGenerator.new([], argv)

    it "maps --dry-run onto the pretend flag Thor's file actions read" do
      expect(generator(["--dry-run"]).options[:pretend]).to be true
    end

    it "leaves pretend unset without --dry-run" do
      expect(generator([]).options[:pretend]).to be_nil
    end
  end
end
