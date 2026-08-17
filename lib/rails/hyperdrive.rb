require "rails/hyperdrive/version"

module Rails
  module Hyperdrive
    def self.root
      @root ||= File.expand_path("..", __dir__)
    end

    def self.dev_mode?
      defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.development?
    end
  end
end

require "rails/hyperdrive/engine" if defined?(::Rails::Engine)
