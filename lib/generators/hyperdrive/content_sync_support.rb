require "generators/hyperdrive/sync_runner"

module Rails
  module Generators
    module Hyperdrive
      # Thor registers every public method defined directly on a generator
      # class as a runnable command, so these shared helpers must stay in an
      # included module or private.
      module ContentSyncSupport
        # Routes InstallPipeline's writes through Thor, so its output and
        # `--dry-run` handling cover installed content too.
        class ThorShell
          def initialize(generator)
            @generator = generator
          end

          def create_file(path, content)
            @generator.create_file(path, content, force: true)
          end

          def append_to_file(path, content)
            @generator.append_to_file(path, content)
          end

          def remove_file(path)
            @generator.remove_file(path)
          end

          def say_status(kind, message, color = nil)
            @generator.say_status(kind, message, color)
          end

          def say(message = "")
            @generator.say(message)
          end
        end

        # Thor's file-writing helpers all read options[:pretend], so mapping
        # --dry-run on read keeps it in force for every step regardless of
        # which one runs first.
        def options
          opts = super
          opts[:dry_run] ? opts.merge(pretend: true) : opts
        end

        private

        def runner
          @runner ||= SyncRunner.new(shell: ThorShell.new(self))
        end
      end
    end
  end
end
