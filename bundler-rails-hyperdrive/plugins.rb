require_relative "lib/bundler/hyperdrive"

Bundler::Plugin.add_hook("after-install-all") do |_dependencies|
  Bundler::Hyperdrive.auto_install
end
