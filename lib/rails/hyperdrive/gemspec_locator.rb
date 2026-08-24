module Rails
  module Hyperdrive
    # Resolves the gemspec of the companion gem repo a dev task is running in,
    # plus the directories its metadata declares. Companion-repo dev tooling:
    # problems raise rather than fail open.
    module GemspecLocator
      Error = Class.new(StandardError)

      module_function

      # Returns the loaded spec and the repo root its relative paths resolve
      # against — the gemspec's own directory, not an installed gem path.
      def load_spec(explicit, dir)
        path = resolve(explicit, dir)
        spec = Gem::Specification.load(path)
        raise Error, "could not load gemspec #{path}" unless spec

        [spec, File.dirname(File.expand_path(path))]
      end

      def resolve(explicit, dir)
        if explicit && !explicit.to_s.strip.empty?
          path = File.expand_path(explicit.to_s, dir)
          raise Error, "gemspec not found: #{path}" unless File.file?(path)
          return path
        end

        found = Dir.glob(File.join(dir, "*.gemspec"))
        case found.size
        when 1 then File.expand_path(found.first)
        when 0 then raise Error, "no .gemspec found in #{dir}; pass an explicit path as the task " \
                                 "argument, e.g. rake \"<task>[path/to/name.gemspec]\""
        else raise Error, "multiple gemspecs found in #{dir} " \
                          "(#{found.map { |f| File.basename(f) }.join(", ")}); pass an explicit path"
        end
      end

      # The default differs per key — content and templates share a root only
      # when a gem declares it — so every caller names its own.
      def metadata_dir(spec, key, default:)
        declared_dir(spec, key) || default
      end

      def declared_dir(spec, key)
        raw = spec.metadata && spec.metadata[key]
        return nil if raw.nil? || raw.to_s.strip.empty?
        raise Error, "gemspec metadata #{key} must not contain '..' segments" if
          raw.to_s.split(%r{[/\\]}).include?("..")
        raw.to_s
      end
    end
  end
end
