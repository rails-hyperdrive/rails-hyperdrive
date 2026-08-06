namespace :hyperdrive do
  desc "Install Rails Hyperdrive into this app (writes .mcp.json, CLAUDE.md, skills, guidelines, mounts engine)"
  task :init do
    require "rails/generators"
    require "generators/hyperdrive/install/install_generator"
    Rails::Generators::Hyperdrive::InstallGenerator.start(ARGV.drop(1))
  end

  desc "Sync Rails Hyperdrive content (skills, guidelines, index.md, lockfile); locally-edited files are preserved — pass --merge (three-way merge), --sidecar (deliver upstream to <file>.new), or --overwrite (restore gem-shipped content)"
  task :sync do
    require "rails/generators"
    require "generators/hyperdrive/sync/sync_generator"
    Rails::Generators::Hyperdrive::SyncGenerator.start(ARGV.drop(1))
  end

  desc "Suggest uninstalled rails-hyperdrive companion gems for this app's stack (networked, cached; pass --refresh to re-query)"
  task :discover do
    require "rails/generators"
    require "generators/hyperdrive/discover/discover_generator"
    Rails::Generators::Hyperdrive::DiscoverGenerator.start(ARGV.drop(1))
  end
end
