require_relative "smoke_helper"

# The companion-repo dev tooling: `rake hyperdrive:skills:*` runs in a plain gem
# repo with no Rails and no app bundle at all.
RSpec.describe "hyperdrive:skills rake tasks smoke", :smoke do
  let(:companion_dir) { Smoke.copy_companion("rails-hyperdrive-alpha") }
  let(:template) do
    File.join(companion_dir, "lib/rails-hyperdrive-alpha/hyperdrive/skills/alpha-skill/SKILL.md.erb")
  end
  let(:face) { File.join(companion_dir, "skills/alpha-skill/SKILL.md") }

  before do
    File.write(File.join(companion_dir, "Rakefile"), %(require "hyperdrive/skill_tasks"\n))
  end

  it "check passes on a fresh checkout, fails on a stale face, and render fixes it" do
    out, status = Smoke.run_rake_in_companion!(companion_dir, "hyperdrive:skills:check")
    expect(status.success?).to be(true), "check failed on a pristine companion:\n#{out}"
    expect(out).to include("canonical skill files up to date")

    File.write(template, File.read(template) + "\nAdded line.\n")

    out_stale, status_stale = Smoke.run_rake_in_companion!(companion_dir, "hyperdrive:skills:check")
    expect(status_stale.success?).to be(false), "check passed on a stale face:\n#{out_stale}"
    expect(out_stale).to include("stale: #{face}")
    expect(out_stale).to include("1 canonical skill file(s) stale; run `rake hyperdrive:skills:render`")
    expect(File.read(face)).not_to include("Added line.")

    out_render, status_render = Smoke.run_rake_in_companion!(companion_dir, "hyperdrive:skills:render")
    expect(status_render.success?).to be(true), "render failed:\n#{out_render}"
    expect(out_render).to include("render #{face}")
    expect(File.read(face)).to include("Added line.")

    out_again, status_again = Smoke.run_rake_in_companion!(companion_dir, "hyperdrive:skills:check")
    expect(status_again.success?).to be(true), "check still failing after render:\n#{out_again}"
    expect(out_again).to include("canonical skill files up to date")
  end
end
