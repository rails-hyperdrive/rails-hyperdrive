require_relative "hyperdrive/version"

module Bundler
  module Hyperdrive
    HOST_GEM = "rails-hyperdrive".freeze
    SUPPORTED_RAILS_HYPERDRIVE = Gem::Requirement.new(">= 0.2")
    PREFIX = "[hyperdrive] ".freeze
    DEVELOPMENT = "development".freeze

    module_function

    # Runs inside `bundle install`: every failure must degrade to a printed
    # line, never a raised error that fails the install.
    def auto_install
      return unless development_environment?

      spec = ::Bundler.load.specs.find { |s| s.name == HOST_GEM }
      unless spec
        report "#{HOST_GEM} is not in the bundle; nothing to auto-install"
        return
      end

      unless SUPPORTED_RAILS_HYPERDRIVE.satisfied_by?(spec.version)
        report "auto-install skipped: #{HOST_GEM} #{spec.version} is outside " \
               "the supported range (#{SUPPORTED_RAILS_HYPERDRIVE}); run bin/rails hyperdrive:sync manually"
        return
      end

      lib = File.join(spec.full_gem_path, "lib")
      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require "rails/hyperdrive/auto_install"

      result = ::Rails::Hyperdrive::AutoInstall.run(root: ::Bundler.root.to_s)
      result.messages.each do |line|
        line.match?(/\A\s/) ? $stdout.puts(line) : report(line)
      end
    rescue StandardError, ScriptError => e
      report "auto-install skipped (#{e.class}: #{e.message}); run bin/rails hyperdrive:sync manually"
      nil
    end

    # The hook fires on every install — CI and deploys included — where any
    # output would be noise, so outside development it returns silently
    # before touching the host application's code.
    def development_environment?
      env = ENV["RAILS_ENV"] || ENV["RACK_ENV"] || DEVELOPMENT
      return false unless env == DEVELOPMENT
      ENV["CI"].nil? || ENV["CI"].empty?
    end

    def report(message)
      $stdout.puts("#{PREFIX}#{message}")
    end
  end
end
