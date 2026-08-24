require "spec_helper"
require "bundler/plugin"
require_relative "../../bundler-hyperdrive/lib/bundler/hyperdrive"

RSpec.describe "bundler-hyperdrive/plugins.rb" do
  # `load`, not `require_relative`: the file may already be in $LOADED_FEATURES.
  def registered_hook
    captured = nil
    allow(Bundler::Plugin).to receive(:add_hook) { |name, &block| captured = [name, block] }
    load File.expand_path("../../bundler-hyperdrive/plugins.rb", __dir__)
    captured
  end

  it "registers the after-install-all hook" do
    name, block = registered_hook

    expect(name).to eq("after-install-all")
    expect(block).to be_a(Proc)
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
