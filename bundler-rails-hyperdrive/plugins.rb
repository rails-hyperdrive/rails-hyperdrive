require_relative "lib/bundler/hyperdrive"

# An exception escaping this block fails the user's `bundle install`, so this
# rescue backs up auto_install's own.
Bundler::Plugin.add_hook("after-install-all") do |_dependencies|
  Bundler::Hyperdrive.auto_install
rescue StandardError, ScriptError => e
  puts "[hyperdrive] auto-install skipped (#{e.class}: #{e.message}); run bin/rails hyperdrive:sync manually"
end
