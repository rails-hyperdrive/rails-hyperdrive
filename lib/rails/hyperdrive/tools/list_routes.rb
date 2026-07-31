require_relative "base"

module Rails
  module Hyperdrive
    module Tools
      class ListRoutes < Base
        tool_name "list_routes"
        description "List all routes: {verb, path, controller_action, name}."

        input_schema(properties: {})

        def self.call(server_context: nil)
          with_dev_guard do
            list = ::Rails.application.routes.routes.map do |r|
              reqs = r.requirements
              controller = reqs[:controller]
              action     = reqs[:action]
              # Engine mounts have no controller/action, so the pair is nil.
              controller_action = (controller && action) ? "#{controller}##{action}" : nil
              {
                verb: r.verb.to_s,
                path: r.path.spec.to_s.sub(/\(\.:format\)\z/, ""),
                controller_action: controller_action,
                name: r.name
              }
            end
            respond_json(list)
          end
        end
      end
    end
  end
end
