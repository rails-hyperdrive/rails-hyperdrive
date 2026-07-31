require "rails/engine"

module Rails
  module Hyperdrive
    # Loads in every environment so an accidental non-dev bundle group doesn't
    # break boot.
    class Engine < ::Rails::Engine
      isolate_namespace Rails::Hyperdrive

      initializer "hyperdrive.warn_outside_development" do
        unless Rails::Hyperdrive.dev_mode?
          msg = "[hyperdrive] loaded outside development (Rails.env=#{::Rails.env}); MCP endpoints will return 403"
          if ::Rails.logger
            ::Rails.logger.warn(msg)
          else
            warn(msg)
          end
        end
      end
    end
  end
end
