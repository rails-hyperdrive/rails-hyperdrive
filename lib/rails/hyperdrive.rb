require "rails/hyperdrive/version"

module Rails
  module Hyperdrive
    class Configuration
      DEFAULT_MOUNT_AT = "/_hyperdrive".freeze

      attr_accessor :mount_at

      def initialize
        @mount_at = DEFAULT_MOUNT_AT
      end
    end

    def self.root
      @root ||= File.expand_path("..", __dir__)
    end

    def self.dev_mode?
      defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.development?
    end

    def self.configuration
      @configuration ||= Configuration.new
    end

    def self.configure
      yield(configuration)
    end

    def self.reset_configuration!
      @configuration = nil
    end
  end
end

require "rails/hyperdrive/engine" if defined?(::Rails::Engine)
