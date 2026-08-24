require "rails/command"
require "rails/generators"
require "generators/hyperdrive/install/install_generator"
require "generators/hyperdrive/sync/sync_generator"
require "generators/hyperdrive/discover/discover_generator"

module Rails
  module Command
    # The generators are the sole authority on option parsing, defaults, and
    # validation; this class only forwards argv and renders `--help`.
    class HyperdriveCommand < Base
      namespace "hyperdrive"

      # Mirrors a generator's own flags so the help surface cannot drift from
      # what the generator actually accepts. Thor's runtime options are
      # excluded: they are inherited plumbing, not part of this command.
      def self.mirror_generator_options(klass)
        klass.class_options.each do |name, option|
          next if ::Rails::Generators::Base.class_options.key?(name)
          method_options[name] = option
        end
      end

      # Thor treats a leading `--` as an options terminator, so with `-- --merge`
      # the flag lands in positional args and `options[:merge]` is false. Both
      # spellings must reach the generator identically.
      def initialize(args = [], local_options = {}, config = {})
        super
        @argv = args + (local_options.is_a?(Array) ? local_options : [])
        @argv = @argv.drop(1) if @argv.first == "--"
      end

      desc "init", "Install Rails Hyperdrive into this app (writes .mcp.json, CLAUDE.md, skills, guidelines, mounts engine)"
      mirror_generator_options ::Rails::Generators::Hyperdrive::InstallGenerator
      def init(*)
        start_generator("install", "InstallGenerator")
      end

      desc "sync", "Sync Rails Hyperdrive content (skills, guidelines, index.md, lockfile); locally-edited files are preserved"
      mirror_generator_options ::Rails::Generators::Hyperdrive::SyncGenerator
      def sync(*)
        start_generator("sync", "SyncGenerator")
      end

      desc "discover", "Suggest uninstalled rails-hyperdrive companion gems for this app's stack (networked, cached)"
      mirror_generator_options ::Rails::Generators::Hyperdrive::DiscoverGenerator
      def discover(*)
        start_generator("discover", "DiscoverGenerator")
      end

      no_commands do
        def start_generator(name, generator)
          require_application!
          ::Rails::Generators::Hyperdrive.const_get(generator).start(@argv)
        end
      end
    end
  end
end
