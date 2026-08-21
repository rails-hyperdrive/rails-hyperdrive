require "json"
require_relative "smoke_helper"

# These fixture apps ship no companion gems, so init is a zero-companion install.
RSpec.describe "hyperdrive:init smoke", :smoke do
  %w[minimal services full_stack].each do |fixture|
    context "with the #{fixture} fixture" do
      let(:app_dir) { Smoke.copy_fixture(fixture) }

      before do
        Smoke.add_path_gem!(app_dir)
        Smoke.bundle_install!(app_dir)
      end

      it "writes the expected files exactly once and mounts the engine" do
        out, status = Smoke.run_hyperdrive_init!(app_dir)

        expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"

        # The banner prints once per run, so a count > 1 means the generator was invoked twice.
        expect(out.scan("hyperdrive initialized").length).to eq(1), "hyperdrive:init ran more than once:\n#{out}"

        expect(File.exist?(File.join(app_dir, ".mcp.json"))).to be(true)
        expect(File.exist?(File.join(app_dir, ".hyperdrive/lock.yml"))).to be(true)

        # Nothing an agent would read: the eager chain waits for a companion guideline.
        expect(File.exist?(File.join(app_dir, "CLAUDE.md"))).to be(false)
        expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/index.md"))).to be(false)
        expect(File.exist?(File.join(app_dir, ".claude/hyperdrive/stack.md"))).to be(false)
        expect(Dir.exist?(File.join(app_dir, ".claude/skills"))).to be(false)

        mcp_json = JSON.parse(File.read(File.join(app_dir, ".mcp.json")))
        expect(mcp_json.dig("mcpServers", "rails-hyperdrive", "url")).to include("/_hyperdrive/mcp")

        routes = File.read(File.join(app_dir, "config/routes.rb"))
        expect(routes).to include("Rails::Hyperdrive::Engine")
        expect(routes).to include("/_hyperdrive")

        out2, status2 = Smoke.run_hyperdrive_init!(app_dir)
        expect(status2.success?).to be(true), out2
        expect(out2).to match(/identical|unchanged/)
        routes_after = File.read(File.join(app_dir, "config/routes.rb"))
        expect(routes_after.scan("Rails::Hyperdrive::Engine").length).to eq(1)
      end

      it "honors --dry-run" do
        out, status = Smoke.run_hyperdrive_init!(app_dir, "--dry-run")
        expect(status.success?).to be(true), out
        expect(File.exist?(File.join(app_dir, ".mcp.json"))).to be(false)
        expect(File.exist?(File.join(app_dir, "CLAUDE.md"))).to be(false)
        expect(File.exist?(File.join(app_dir, ".hyperdrive/lock.yml"))).to be(false)
        routes = File.read(File.join(app_dir, "config/routes.rb"))
        expect(routes).not_to include("Rails::Hyperdrive::Engine")
      end
    end
  end

  context "with a flag behind the legacy `--` separator" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }

    before do
      Smoke.add_path_gem!(app_dir)
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      raise "hyperdrive:init failed:\n#{out}" unless status.success?
    end

    it "reaches the generator" do
      out, status = Smoke.run_hyperdrive_sync!(app_dir, "--", "--dry-run")
      expect(status.success?).to be(true), "hyperdrive:sync failed:\n#{out}"
      expect(out).to include("hyperdrive synced")
    end
  end
end
