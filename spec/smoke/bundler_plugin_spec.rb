require_relative "smoke_helper"

# End-to-end smoke for the bundler-hyperdrive plugin: a newly bundled
# companion's artifacts land during `bundle install` itself, with no explicit
# sync and no ruby invocation.
RSpec.describe "bundler-hyperdrive plugin smoke", :smoke do
  # A CI variable inherited from the runner would trip the plugin's
  # environment guard; these scenarios simulate a developer machine.
  DEV_ENV = {"CI" => nil}.freeze

  let(:app_dir) { Smoke.copy_fixture("minimal") }

  def bundle!(env = {})
    Smoke.bundle_install!(app_dir, DEV_ENV.merge(env))
  end

  before do
    Smoke.add_path_gem!(app_dir)
    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
    bundle!

    out, status = Smoke.run_hyperdrive_init!(app_dir)
    expect(status.success?).to be(true), "hyperdrive:init failed:\n#{out}"
  end

  it "installs a newly bundled companion's artifacts during bundle install" do
    plugin_lines = File.read(File.join(app_dir, "Gemfile"))
      .scan(/^\s*plugin\s+["']bundler-hyperdrive["']/)
    expect(plugin_lines.length).to eq(1)

    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    out = bundle!

    expect(out).to include("[hyperdrive] installed")
    guide = File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md")
    expect(File.exist?(guide)).to be(true), "beta-guide not installed:\n#{out}"
    expect(File.read(guide)).to start_with("<!-- hyperdrive: source=rails-hyperdrive-beta@")
    expect(File.read(File.join(app_dir, ".claude/hyperdrive/index.md")))
      .to include("@guidelines/beta-guide.md")
    expect(File.read(File.join(app_dir, ".hyperdrive/lock.yml"))).to include("beta-guide")
  end

  it "leaves a locally-edited artifact alone while installing what is new" do
    edited = File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md")
    File.write(edited, File.read(edited) + "\nMY LOCAL EDIT\n")

    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    bundle!

    expect(File.read(edited)).to include("MY LOCAL EDIT")
    expect(File).to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
  end

  it "installs nothing outside development" do
    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    out = bundle!("RAILS_ENV" => "production")

    expect(out).not_to include("[hyperdrive]")
    expect(File).not_to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
  end
end
