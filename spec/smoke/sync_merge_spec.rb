require "fileutils"
require_relative "smoke_helper"

RSpec.describe "hyperdrive:sync --merge smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("minimal") }
  let(:v1_dir) { File.join(app_dir, "companions/v1/rails-hyperdrive-alpha") }
  let(:v2_dir) { File.join(app_dir, "companions/v2/rails-hyperdrive-alpha") }
  let(:guide_rel) { "lib/rails-hyperdrive-alpha/hyperdrive/guidelines/alpha-guide.md" }
  let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }
  # Bundler runs the app subprocess with GEM_PATH scoped to BUNDLE_PATH's ruby
  # scope, so this is the one gem home the ancestor lookup can see.
  let(:gem_home) { File.join(Smoke::BUNDLE_PATH, Gem.ruby_engine, RbConfig::CONFIG["ruby_version"]) }

  def copy_companion!(dest)
    FileUtils.mkdir_p(dest)
    Smoke.sh!("cp", "-a", "#{File.join(Smoke::COMPANIONS_ROOT, "rails-hyperdrive-alpha")}/.", dest)
  end

  before do
    copy_companion!(v1_dir)

    # v2: bumped gemspec version + an upstream change appended to the guideline.
    copy_companion!(v2_dir)
    gemspec = File.join(v2_dir, "rails-hyperdrive-alpha.gemspec")
    File.write(gemspec, File.read(gemspec).sub('"0.1.0"', '"0.2.0"'))
    v2_guide = File.join(v2_dir, guide_rel)
    File.write(v2_guide, File.read(v2_guide) + "\n## New in v2\n\nUpstream added this section.\n")

    Smoke.add_path_gem!(app_dir)
    File.open(File.join(app_dir, "Gemfile"), "a") do |f|
      f.write(%(gem "rails-hyperdrive-alpha", path: #{v1_dir.inspect}\n))
    end
    Smoke.bundle_install!(app_dir)
    _out, status = Smoke.run_hyperdrive_init!(app_dir)
    expect(status.success?).to be(true)
  end

  after do
    FileUtils.rm_rf(File.join(gem_home, "gems", "rails-hyperdrive-alpha-0.1.0"))
    FileUtils.rm_f(File.join(gem_home, "specifications", "rails-hyperdrive-alpha-0.1.0.gemspec"))
  end

  def install_v1_into_gem_home!
    Bundler.with_unbundled_env do
      Smoke.sh!("gem", "build", "rails-hyperdrive-alpha.gemspec", chdir: v1_dir)
      Smoke.sh!(
        "gem", "install", "--local", "--install-dir", gem_home,
        "--ignore-dependencies", "--no-document",
        File.join(v1_dir, "rails-hyperdrive-alpha-0.1.0.gem")
      )
    end
  end

  it "three-way-merges a non-overlapping local edit with the v2 upstream, re-locks, and stays stable" do
    expect(Dir.exist?(gem_home)).to be(true), "expected bundler gem home at #{gem_home}"
    install_v1_into_gem_home!

    gemfile = File.join(app_dir, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(v1_dir.inspect, v2_dir.inspect))
    Smoke.bundle_install!(app_dir)

    # Local edit at the top of the body; the v2 change appends at the bottom.
    File.write(guide_path, File.read(guide_path).sub("# Alpha Guideline", "# Alpha Guideline (customized)"))

    out, st = Smoke.run_hyperdrive_sync!(app_dir, "--merge")
    expect(st.success?).to be(true), out
    expect(out).to match(/merged.*alpha-guide\.md/)

    merged = File.read(guide_path)
    expect(merged).to start_with("<!-- hyperdrive: source=rails-hyperdrive-alpha@0.2.0 -->")
    expect(merged).to include("# Alpha Guideline (customized)")
    expect(merged).to include("## New in v2")
    expect(merged).not_to include("<<<<<<<")
    expect(File.exist?("#{guide_path}.new")).to be(false), "clean merge must not leave a sidecar"
    expect(File.read(File.join(app_dir, ".hyperdrive/lock.yml"))).to include("rails-hyperdrive-alpha@0.2.0")

    # A follow-up plain sync must not clobber the merge.
    out2, st2 = Smoke.run_hyperdrive_sync!(app_dir)
    expect(st2.success?).to be(true), out2
    expect(File.read(guide_path)).to eq(merged)
  end
end
