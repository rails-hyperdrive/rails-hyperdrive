require "fileutils"
require "json"
require "yaml"
require_relative "smoke_helper"

RSpec.describe "hyperdrive:sync --merge smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("minimal") }
  let(:v1_dir) { File.join(app_dir, "companions/v1/rails-hyperdrive-alpha") }
  let(:v2_dir) { File.join(app_dir, "companions/v2/rails-hyperdrive-alpha") }
  let(:v3_dir) { File.join(app_dir, "companions/v3/rails-hyperdrive-alpha") }
  let(:guide_rel) { "lib/rails-hyperdrive-alpha/hyperdrive/guidelines/alpha-guide.md" }
  let(:guide_path) { File.join(app_dir, ".claude/hyperdrive/guidelines/alpha-guide.md") }
  let(:gem_home) { Smoke.gem_home }

  def copy_companion!(dest)
    FileUtils.mkdir_p(dest)
    Smoke.sh!("cp", "-a", "#{File.join(Smoke::COMPANIONS_ROOT, "rails-hyperdrive-alpha")}/.", dest)
  end

  before do
    # A crashed earlier run must not leave the v1 gem behind for the next one.
    Smoke.remove_from_gem_home!("rails-hyperdrive-alpha", "0.1.0")
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
    Smoke.remove_from_gem_home!("rails-hyperdrive-alpha", "0.1.0")
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
    expect(out).to include("Merged 1 file by three-way merge")

    merged = File.read(guide_path)
    expect(merged).to start_with("# Alpha Guideline (customized)")
    expect(merged).not_to include("hyperdrive:") # no audit header
    expect(merged).to include("## New in v2")
    expect(merged).not_to include("<<<<<<<")
    expect(File.exist?("#{guide_path}.new")).to be(false), "clean merge must not leave a sidecar"
    expect(File.read(File.join(app_dir, ".hyperdrive/lock.yml"))).to include("rails-hyperdrive-alpha@0.2.0")

    # A follow-up plain sync must not clobber the merge.
    out2, st2 = Smoke.run_hyperdrive_sync!(app_dir)
    expect(st2.success?).to be(true), out2
    expect(File.read(guide_path)).to eq(merged)
  end

  it "merges a third upstream over the ancestor a pending sidecar recorded" do
    install_v1_into_gem_home!

    gemfile = File.join(app_dir, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(v1_dir.inspect, v2_dir.inspect))
    Smoke.bundle_install!(app_dir)
    File.write(guide_path, File.read(guide_path).sub("# Alpha Guideline", "# Alpha Guideline (customized)"))

    out, st = Smoke.run_hyperdrive_sync!(app_dir, "--sidecar")
    expect(st.success?).to be(true), out
    expect(File.exist?("#{guide_path}.new")).to be(true)
    lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
    expect(lock).to include("ancestor_source: rails-hyperdrive-alpha@0.1.0")

    copy_companion!(v3_dir)
    gemspec = File.join(v3_dir, "rails-hyperdrive-alpha.gemspec")
    File.write(gemspec, File.read(gemspec).sub('"0.1.0"', '"0.3.0"'))
    v3_guide = File.join(v3_dir, guide_rel)
    File.write(v3_guide, File.read(v3_guide) + "\n## New in v2\n\nUpstream added this section.\n" \
                                              "\n## New in v3\n\nAnd this one.\n")
    File.write(gemfile, File.read(gemfile).sub(v2_dir.inspect, v3_dir.inspect))
    Smoke.bundle_install!(app_dir)

    out2, st2 = Smoke.run_hyperdrive_sync!(app_dir, "--merge")
    expect(st2.success?).to be(true), out2
    expect(out2).to match(/merged.*alpha-guide\.md/)

    merged = File.read(guide_path)
    expect(merged).to start_with("# Alpha Guideline (customized)")
    expect(merged).to include("## New in v2")
    expect(merged).to include("## New in v3")
    expect(merged).not_to include("<<<<<<<")
    expect(File.exist?("#{guide_path}.new")).to be(false), "a clean merge must sweep the pending sidecar"
    lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
    expect(lock).to include("rails-hyperdrive-alpha@0.3.0")
    expect(lock).not_to include("ancestor_source")
  end

  it "degrades to a sidecar when the local edit overlaps the upstream change" do
    install_v1_into_gem_home!

    v2_guide = File.join(v2_dir, guide_rel)
    File.write(v2_guide, File.read(v2_guide).sub(
      "This app uses the alpha convention.", "This app uses the alpha convention (v2)."
    ))
    gemfile = File.join(app_dir, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(v1_dir.inspect, v2_dir.inspect))
    Smoke.bundle_install!(app_dir)

    # The same line both sides rewrote: no textual merge exists.
    edited = File.read(guide_path).sub(
      "This app uses the alpha convention.", "This app uses the alpha convention (customized)."
    )
    File.write(guide_path, edited)

    out, st = Smoke.run_hyperdrive_sync!(app_dir, "--merge")
    expect(st.success?).to be(true), out
    expect(out).to match(%r{sidecar.*alpha-guide\.md.*new upstream delivered to .*alpha-guide\.md\.new; conflicting edits})
    expect(out).not_to include("Merged")

    expect(File.read(guide_path)).to eq(edited)
    expect(File.read(guide_path)).not_to include("<<<<<<<")

    sidecar = File.read("#{guide_path}.new")
    expect(sidecar).to include("This app uses the alpha convention (v2).")
    expect(sidecar).not_to include("(customized)")

    lock = File.read(File.join(app_dir, ".hyperdrive/lock.yml"))
    expect(lock).to include("rails-hyperdrive-alpha@0.2.0")
    expect(lock).to include("ancestor_source: rails-hyperdrive-alpha@0.1.0")
  end

  it "hands the resolver the reconstructed ancestor and the source it came from" do
    install_v1_into_gem_home!

    gemfile = File.join(app_dir, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(v1_dir.inspect, v2_dir.inspect))
    Smoke.bundle_install!(app_dir)
    File.write(guide_path, File.read(guide_path).sub("# Alpha Guideline", "# Alpha Guideline (customized)"))

    resolver = File.join(app_dir, "bin/probe-resolver")
    File.write(resolver, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      File.write("resolve-probe.json", JSON.dump(
        "base" => (b = ENV["HYPERDRIVE_BASE"]) && File.read(b),
        "previous_source" => ENV["HYPERDRIVE_PREVIOUS_SOURCE"],
        "source" => ENV["HYPERDRIVE_SOURCE"]
      ))
      File.write(ENV.fetch("HYPERDRIVE_MERGED"), File.read(ENV.fetch("HYPERDRIVE_REMOTE")))
    RUBY
    File.chmod(0o755, resolver)

    config_path = File.join(app_dir, ".hyperdrive/config.yml")
    config = YAML.safe_load(File.read(config_path)) || {}
    config["resolve"] = { "command" => "bin/probe-resolver $BASE" }
    File.write(config_path, config.to_yaml)

    out, st = Smoke.run_hyperdrive_sync!(app_dir, "--resolve")
    expect(st.success?).to be(true), out
    expect(out).to include("Sidecars: 1 resolved")
    expect(File.exist?("#{guide_path}.new")).to be(false)

    probe = JSON.parse(File.read(File.join(app_dir, "resolve-probe.json")))
    expect(probe["base"]).to start_with("# Alpha Guideline")
    expect(probe["base"]).not_to include("## New in v2")
    expect(probe["base"]).not_to include("description:") # install-ready form, frontmatter stripped
    expect(probe["previous_source"]).to eq("rails-hyperdrive-alpha@0.1.0")
    expect(probe["source"]).to eq("rails-hyperdrive-alpha@0.2.0")
  end
end
