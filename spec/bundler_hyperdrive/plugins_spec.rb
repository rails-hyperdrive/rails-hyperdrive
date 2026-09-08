require "spec_helper"
require "bundler/plugin"
require_relative "../../bundler-hyperdrive/lib/bundler/hyperdrive"

RSpec.describe "bundler-hyperdrive/plugins.rb" do
  # `load`, not `require_relative`: the file may already be in $LOADED_FEATURES.
  # Loaded once for the group — each `load` recompiles the file and resets its
  # coverage counters to whatever that copy happened to run.
  captured = nil
  original_add_hook = Bundler::Plugin.method(:add_hook)
  Bundler::Plugin.define_singleton_method(:add_hook) { |name, &block| captured = [name, block] }
  load File.expand_path("../../bundler-hyperdrive/plugins.rb", __dir__)
  Bundler::Plugin.define_singleton_method(:add_hook, original_add_hook)

  let(:registered_hook) { captured }

  it "registers the after-install-all hook" do
    name, block = registered_hook

    expect(name).to eq("after-install-all")
    expect(block).to be_a(Proc)
  end

  it "is packaged by the plugin gemspec" do
    gemspec = File.expand_path("../../bundler-hyperdrive/bundler-hyperdrive.gemspec", __dir__)

    expect(Gem::Specification.load(gemspec).files)
      .to include("plugins.rb", "lib/bundler/hyperdrive.rb")
  end

  it "degrades a ScriptError escaping auto_install to one printed line" do
    _name, block = registered_hook
    allow(Bundler::Hyperdrive).to receive(:auto_install)
      .and_raise(LoadError, "cannot load such file -- rails/hyperdrive/auto_install")

    expect { block.call(nil) }.to output(
      "[hyperdrive] auto-install skipped (LoadError: cannot load such file -- " \
      "rails/hyperdrive/auto_install); run bin/rails hyperdrive:sync manually\n"
    ).to_stdout
  end

  it "degrades a StandardError escaping auto_install to one printed line" do
    _name, block = registered_hook
    allow(Bundler::Hyperdrive).to receive(:auto_install)
      .and_raise(NoMethodError, "undefined method `auto_install'")

    expect { block.call(nil) }.to output(
      "[hyperdrive] auto-install skipped (NoMethodError: undefined method `auto_install'); " \
      "run bin/rails hyperdrive:sync manually\n"
    ).to_stdout
  end
end
