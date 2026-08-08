require_relative "base"
require_relative "../stack_profile"

module Rails
  module Hyperdrive
    module Tools
      class DescribeApp < Base
        tool_name "describe_app"
        description "Snapshot of Rails/Ruby/DB versions plus the app's direct gem dependencies and installed gem skills."

        input_schema(properties: {})

        def self.call(server_context: nil)
          with_dev_guard do
            respond_json(Rails::Hyperdrive::StackProfile.current.to_h)
          end
        end
      end
    end
  end
end
