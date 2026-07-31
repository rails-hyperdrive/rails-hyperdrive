module Rails
  module Generators
    module Hyperdrive
      # Included as a module so its methods are not registered as Thor commands —
      # Thor's method_added hook fires only for methods defined directly on the
      # generator class.
      module GitignoreSupport
        GITIGNORE = ".gitignore".freeze

        # The rule must name a specific file, never a directory — the lockfile
        # in the same directory stays tracked.
        def ensure_gitignored(rule)
          abs = ::Rails.root.join(GITIGNORE)
          unless File.exist?(abs)
            create_file GITIGNORE, "#{rule}\n"
            return
          end

          body = File.read(abs)
          return if body.split("\n").any? { |line| line.strip == rule }

          prefix = body.end_with?("\n") || body.empty? ? "" : "\n"
          append_to_file GITIGNORE, "#{prefix}#{rule}\n"
        end
      end
    end
  end
end
