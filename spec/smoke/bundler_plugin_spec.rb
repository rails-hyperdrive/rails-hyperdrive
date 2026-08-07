require_relative "smoke_helper"

# End-to-end smoke for the bundler-rails-hyperdrive plugin: a newly bundled
# companion's artifacts land during `bundle install` itself, with no explicit
# sync and no ruby invocation.
RSpec.describe "bundler-rails-hyperdrive plugin smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("minimal") }

  def bundle!(env = {})
    Smoke.bundle_install!(app_dir, env)
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
      .scan(/^\s*plugin\s+["']bundler-rails-hyperdrive["']/)
    expect(plugin_lines.length).to eq(1)

    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    out = bundle!

    expect(out).to include("[hyperdrive] installed")
    guide = File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md")
    expect(File.exist?(guide)).to be(true), "beta-guide not installed:\n#{out}"
    expect(File.read(guide)).to start_with("# Beta Guideline")
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

  it "reports an upgraded companion's artifacts without touching them" do
    # The shared fixture must stay pristine across scenarios, so the upgrade
    # happens on a per-app copy of the companion.
    fixture = File.join(Smoke::COMPANIONS_ROOT, "rails-hyperdrive-alpha")
    upgraded = File.join(app_dir, "vendor/rails-hyperdrive-alpha")
    FileUtils.mkdir_p(File.dirname(upgraded))
    FileUtils.cp_r(fixture, upgraded)

    gemfile = File.join(app_dir, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(fixture.inspect, upgraded.inspect))

    gemspec = File.join(upgraded, "rails-hyperdrive-alpha.gemspec")
    File.write(gemspec, File.read(gemspec).sub('"0.1.0"', '"0.2.0"'))
    guide_src = File.join(upgraded, "lib/rails-hyperdrive-alpha/hyperdrive/guidelines/alpha-guide.md")
    File.write(guide_src, File.read(guide_src) + "\nUpgraded content.\n")

    out = bundle!

    expect(out).to match(/\[hyperdrive\] \d+ artifact\(s\) need attention — run bin\/rails hyperdrive:sync/)
    expect(out).to include(
      ".claude/hyperdrive/guidelines/alpha-guide.md " \
      "(rails-hyperdrive-alpha@0.1.0 → rails-hyperdrive-alpha@0.2.0)"
    )
    expect(out).not_to include("[hyperdrive] installed")
    installed = File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md")
    expect(File.read(installed)).not_to include("Upgraded content.")
  end

  it "installs nothing outside development" do
    Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-beta")
    out = bundle!("RAILS_ENV" => "production")

    expect(out).not_to include("[hyperdrive]")
    expect(File).not_to exist(File.join(app_dir, ".claude/hyperdrive/guidelines/beta-guide.md"))
  end
end
