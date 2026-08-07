require "json"
require_relative "smoke_helper"

# End-to-end smoke for topping up an application from a process with no Rails
# application booted, against a real app, a real bundle, and a real companion gem.
RSpec.describe "hyperdrive auto-install smoke", :smoke do
  SNIPPET = <<~RUBY.freeze
    require "json"
    require "rails/hyperdrive/auto_install"
    raise "Rails should not be booted" if defined?(::Rails::Application) && ::Rails.respond_to?(:application) && ::Rails.application
    result = Rails::Hyperdrive::AutoInstall.run(root: Dir.pwd)
    puts JSON.dump(
      installed: result.installed,
      outdated: result.outdated.map(&:path),
      orphaned: result.orphaned.map(&:path),
      skipped: result.skipped
    )
  RUBY

  let(:app_dir) { Smoke.copy_fixture("minimal") }

  def auto_install(env = {})
    out, status = Smoke.run_ruby!(app_dir, SNIPPET, env)
    expect(status.success?).to be(true), "auto-install failed:\n#{out}"
    JSON.parse(out.lines.last, symbolize_names: true)
  end

  # Every install disables Bundler's plugin system: with the bundler-rails-hyperdrive
  # hook active, `bundle install` would land the artifacts first and the
  # entry-point assertions below would see nothing left to install.
  before do
    Smoke.add_path_gem!(app_dir)
    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
    Smoke.bundle_install!(app_dir, {"BUNDLE_PLUGINS" => "false"})

    out, status = Smoke.run_hyperdrive_init!(app_dir)
    expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
  end

  it "installs a newly bundled companion's artifacts without booting Rails" do
    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    Smoke.bundle_install!(app_dir, {"BUNDLE_PLUGINS" => "false"})

    result = auto_install

    expect(result[:installed]).to include(".claude/hyperdrive/guidelines/beta-guide.md")
    expect(File).to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
    expect(File.read(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md")))
      .to start_with("# Beta Guideline")
    expect(File.read(File.join(app_dir, ".claude/hyperdrive/index.md")))
      .to include("@guidelines/beta-guide.md")
    expect(File.read(File.join(app_dir, ".hyperdrive/lock.yml"))).to include("beta-guide")
  end

  it "writes nothing when the bundle offers nothing new" do
    expect(auto_install[:installed]).to be_empty
  end

  it "leaves a locally-edited artifact alone while installing what is new" do
    edited = File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md")
    File.write(edited, File.read(edited) + "\nMY LOCAL EDIT\n")

    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    Smoke.bundle_install!(app_dir, {"BUNDLE_PLUGINS" => "false"})
    auto_install

    expect(File.read(edited)).to include("MY LOCAL EDIT")
    expect(File).to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
  end

  it "installs nothing outside development" do
    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    Smoke.bundle_install!(app_dir, {"BUNDLE_PLUGINS" => "false"})

    result = auto_install("RAILS_ENV" => "production")

    expect(result[:skipped]).to eq("not_development")
    expect(File).not_to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
  end
end
