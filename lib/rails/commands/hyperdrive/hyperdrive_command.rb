require "rails/command"

module Rails
  module Command
    # The generators are the sole authority on option parsing, defaults, and
    # validation; the declarations here exist only to render `--help`.
    class HyperdriveCommand < Base
      namespace "hyperdrive"

      # Thor treats a leading `--` as an options terminator, so with `-- --merge`
      # the flag lands in positional args and `options[:merge]` is false. Both
      # spellings must reach the generator identically.
      def initialize(args = [], local_options = {}, config = {})
        super
        @argv = args + (local_options.is_a?(Array) ? local_options : [])
        @argv = @argv.drop(1) if @argv.first == "--"
      end

      desc "init", "Install Rails Hyperdrive into this app (writes .mcp.json, CLAUDE.md, skills, guidelines, mounts engine)"
      option :mount_at, type: :string, default: "/_hyperdrive", desc: "Engine mount path."
      option :skip_content, type: :boolean, default: false, desc: "Skip all .claude content, CLAUDE.md, and the lockfile; write only .mcp.json and the mount."
      option :dry_run, type: :boolean, default: false, desc: "Show what would change; write nothing."
      def init(*)
        start_generator("install", "InstallGenerator")
      end

      desc "sync", "Sync Rails Hyperdrive content (skills, guidelines, index.md, lockfile); locally-edited files are preserved"
      option :overwrite, type: :boolean, default: false, desc: "Restore locally-modified managed files to the gem-shipped content."
      option :merge, type: :boolean, default: false, desc: "Three-way-merge upstream changes into locally-modified files; falls back to sidecar delivery."
      option :sidecar, type: :boolean, default: false, desc: "Deliver upstream changes for locally-modified files to <file>.new sidecars."
      option :dry_run, type: :boolean, default: false, desc: "Show what would change; write nothing."
      def sync(*)
        start_generator("sync", "SyncGenerator")
      end

      desc "discover", "Suggest uninstalled rails-hyperdrive companion gems for this app's stack (networked, cached)"
      option :refresh, type: :boolean, default: false, desc: "Ignore the cached results and re-query rubygems."
      def discover(*)
        start_generator("discover", "DiscoverGenerator")
      end

      no_commands do
        def start_generator(name, generator)
          require_application!
          require "rails/generators"
          require "generators/hyperdrive/#{name}/#{name}_generator"
          ::Rails::Generators::Hyperdrive.const_get(generator).start(@argv)
        end
      end
    end
  end
end
