require "spec_helper"
require "rails/hyperdrive/auto_install"
require_relative "../../bundler-hyperdrive/lib/bundler/hyperdrive"

RSpec.describe Bundler::Hyperdrive do
  def result(**attrs)
    Rails::Hyperdrive::AutoInstall::Result.new(**attrs)
  end

  def with_env(vars)
    original = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  def run(env = {})
    with_env({"RAILS_ENV" => nil, "RACK_ENV" => nil, "CI" => nil}.merge(env)) do
      described_class.auto_install
    end
  end

  def stub_bundle(specs)
    allow(::Bundler).to receive(:load).and_return(double(specs: specs))
  end

  # Defaults to this repository so the happy path adds no phantom entry to
  # $LOAD_PATH — lib/ is already on it.
  def host_spec(version, gem_path: File.expand_path("../..", __dir__))
    instance_double(
      Gem::Specification,
      name: "rails-hyperdrive",
      version: Gem::Version.new(version),
      full_gem_path: gem_path
    )
  end

  describe "environment guard" do
    %w[RAILS_ENV RACK_ENV].each do |var|
      it "returns silently when #{var} is not development, never touching the bundle" do
        expect(::Bundler).not_to receive(:load)
        expect { run(var => "production") }.not_to output.to_stdout
      end
    end

    it "returns silently when CI is set" do
      expect(::Bundler).not_to receive(:load)
      expect { run("CI" => "true") }.not_to output.to_stdout
    end

    it "treats an empty CI as unset" do
      stub_bundle([])
      expect { run("CI" => "") }.to output(/\[hyperdrive\]/).to_stdout
    end
  end

  describe "resolving rails-hyperdrive from the bundle" do
    it "reports one line when the gem is absent" do
      stub_bundle([])
      expect { run }
        .to output("[hyperdrive] rails-hyperdrive is not in the bundle; nothing to auto-install\n").to_stdout
    end

    it "reports one line naming the range for an unsupported version, without loading the gem" do
      stub_bundle([host_spec("0.1.0", gem_path: "/unsupported-hyperdrive")])
      expect(Rails::Hyperdrive::AutoInstall).not_to receive(:run)

      expect { run }
        .to output(/\A\[hyperdrive\] auto-install skipped: rails-hyperdrive 0\.1\.0 .*\(>= 0\.2\).*hyperdrive:sync manually\n\z/).to_stdout
      expect($LOAD_PATH).not_to include("/unsupported-hyperdrive/lib")
    end
  end

  describe "a compatible bundle" do
    before { stub_bundle([host_spec("0.2.0")]) }

    it "runs the entry point against Bundler.root and prints prefixed messages" do
      expect(Rails::Hyperdrive::AutoInstall)
        .to receive(:run).with(root: ::Bundler.root.to_s)
        .and_return(result(
          installed: [".claude/hyperdrive/guidelines/beta-guide.md"],
          outdated: [], orphaned: []
        ))

      expect { run }.to output(
        "[hyperdrive] installed 1 artifact(s):\n" \
        "  .claude/hyperdrive/guidelines/beta-guide.md\n"
      ).to_stdout
    end

    it "prints the needs-attention report for stale artifacts" do
      allow(Rails::Hyperdrive::AutoInstall).to receive(:run).and_return(
        result(installed: [], outdated: ["a.md (x@1 → x@2)"], orphaned: [])
      )

      expect { run }.to output(
        "[hyperdrive] 1 artifact(s) need attention — run bin/rails hyperdrive:sync\n" \
        "  a.md (x@1 → x@2)\n"
      ).to_stdout
    end

    it "prints nothing for a skipped result" do
      allow(Rails::Hyperdrive::AutoInstall).to receive(:run).and_return(
        result(installed: [], outdated: [], orphaned: [], skipped: :not_initialized)
      )

      expect { run }.not_to output.to_stdout
    end

    it "prints nothing when there is nothing to install and nothing stale" do
      allow(Rails::Hyperdrive::AutoInstall).to receive(:run).and_return(
        result(installed: [], outdated: [], orphaned: [])
      )

      expect { run }.not_to output.to_stdout
    end
  end

  describe "quiet failure" do
    it "rescues an exception into a single reported line and returns" do
      allow(::Bundler).to receive(:load).and_raise(RuntimeError, "boom")

      expect { run }.to output(
        "[hyperdrive] auto-install skipped (RuntimeError: boom); run bin/rails hyperdrive:sync manually\n"
      ).to_stdout
    end

    it "rescues a failure inside the entry point" do
      stub_bundle([host_spec("0.2.0")])
      allow(Rails::Hyperdrive::AutoInstall).to receive(:run).and_raise(ArgumentError, "bad root")

      expect { run }.to output(/\A\[hyperdrive\] auto-install skipped \(ArgumentError: bad root\).*\n\z/).to_stdout
    end

    # LoadError is a ScriptError, not a StandardError. `require` is stubbed
    # because the real file is already loaded here, so a bad path never raises.
    it "rescues a ScriptError raised while requiring the host gem" do
      stub_bundle([host_spec("0.2.0")])
      allow(described_class).to receive(:require)
        .and_raise(LoadError, "cannot load such file -- rails/hyperdrive/auto_install")

      expect { run }.to output(
        "[hyperdrive] auto-install skipped (LoadError: cannot load such file -- " \
        "rails/hyperdrive/auto_install); run bin/rails hyperdrive:sync manually\n"
      ).to_stdout
    end
  end
end
