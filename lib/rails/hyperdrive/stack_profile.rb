require "bundler"
require "yaml"
require "digest"

module Rails
  module Hyperdrive
    class StackProfile
      CATEGORIES_PATH = File.expand_path("data/gem_categories.yml", __dir__)

      class << self
        def categories
          @categories ||= YAML.load_file(CATEGORIES_PATH).each_with_object({}) do |(cat, gems), acc|
            gems.each { |g| acc[g] = cat.to_sym }
          end
        end

        def current
          @current ||= from_lockfile(default_lockfile_path)
        end

        def reset!
          @current = nil
        end

        def from_lockfile(path, app_root: nil)
          new(path: path, app_root: app_root).tap(&:parse!)
        end

        def default_lockfile_path
          if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
            ::Rails.root.join("Gemfile.lock").to_s
          else
            File.expand_path("Gemfile.lock", Dir.pwd)
          end
        end
      end

      attr_reader :path, :data

      def initialize(path:, app_root: nil)
        @path = path
        @app_root = app_root
        @data = empty_profile
      end

      def parse!
        unless File.exist?(@path)
          @data = empty_profile.merge(error: "Gemfile.lock not found at #{@path}")
          return self
        end

        contents = File.read(@path)
        parser   = ::Bundler::LockfileParser.new(contents)
        specs    = parser.specs.each_with_object({}) { |s, h| h[s.name] = s.version.to_s }

        @data = {
          rails:      rails_info(specs),
          ruby:       ruby_info(parser),
          database:   database_info(specs),
          test:       bucket(specs, :test),
          jobs:       bucket(specs, :jobs),
          frontend:   frontend_info(specs),
          auth:       bucket(specs, :auth),
          authz:      bucket(specs, :authz),
          db_gems:    bucket(specs, :db),
          gem_skills: gem_skills_info
        }
        self
      end

      def to_h
        @data
      end

      private

      def empty_profile
        {
          rails: {}, ruby: {}, database: {},
          test: [], jobs: [], frontend: [],
          auth: [], authz: [], db_gems: [], gem_skills: []
        }
      end

      def rails_info(specs)
        version = specs["rails"] || specs["railties"]
        return {} unless version
        { version: version, major: version.to_s.split(".").first.to_i }
      end

      def ruby_info(parser)
        version = parser.ruby_version || (RUBY_VERSION if defined?(RUBY_VERSION))
        version ? { version: version.to_s.sub(/^ruby /, "") } : {}
      end

      # database.yml takes precedence: a Rails app can ship `pg` for a
      # secondary store while running on sqlite3, and the declared adapter is
      # what we want to report.
      def database_info(specs)
        if (yml_adapter = adapter_from_database_yml)
          return { adapter: yml_adapter }
        end
        adapter = if specs["pg"] then "postgresql"
        elsif specs["mysql2"] then "mysql2"
        elsif specs["trilogy"] then "trilogy"
        elsif specs["sqlite3"] then "sqlite3"
        end
        adapter ? { adapter: adapter } : {}
      end

      def adapter_from_database_yml
        yml_path = database_yml_path
        return nil unless yml_path && File.exist?(yml_path)
        # ERB-rendered config is common; permissive parse keeps us out of the
        # business of evaluating user code at generator time.
        raw = File.read(yml_path)
        raw = raw.gsub(/<%.*?%>/m, '""')
        parsed = YAML.safe_load(raw, aliases: true) || {}
        env = (defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.to_s) || "development"
        section = parsed[env] || parsed["development"]
        return nil unless section.is_a?(Hash)
        adapter = section["adapter"] || section.values.grep(Hash).map { |h| h["adapter"] }.compact.first
        adapter&.to_s
      rescue StandardError
        nil
      end

      # An explicit app_root keeps the adapter resolvable with no Rails booted,
      # so stack.md renders identically in every process that generates it.
      def database_yml_path
        return File.join(@app_root.to_s, "config", "database.yml") if @app_root
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.join("config", "database.yml").to_s
      end

      def bucket(specs, category)
        gem_names = self.class.categories.select { |_, c| c == category }.keys
        gem_names.filter_map do |name|
          version = specs[name]
          next unless version
          { key: name.to_sym, version: version }
        end
      end

      # Frontend gets a special shape because Hotwire is actually two gems.
      def frontend_info(specs)
        bucket(specs, :frontend).map do |entry|
          if entry[:key] == :"turbo-rails" || entry[:key] == :"stimulus-rails"
            turbo = specs["turbo-rails"]
            stim  = specs["stimulus-rails"]
            { key: :hotwire, versions: { turbo: turbo, stimulus: stim }.compact }
          else
            entry
          end
        end.uniq
      end

      # Loaded lazily and rescued broadly so StackProfile stays usable where
      # Bundler is absent or refuses to resolve.
      def gem_skills_info
        require "rails/hyperdrive/bundler_artifact_discovery"
        ::Rails::Hyperdrive::BundlerArtifactDiscovery.discover.select(&:skill?).map do |skill|
          {
            name: skill.name,
            gem: skill.target_gem,
            source: skill.source_gem,
            version: skill.spec_version,
            path: skill.path,
            sha256: Digest::SHA256.hexdigest(skill.body.to_s)
          }
        end
      rescue StandardError
        []
      end
    end
  end
end
