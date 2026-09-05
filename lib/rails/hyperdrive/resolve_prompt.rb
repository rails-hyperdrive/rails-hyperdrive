require "erb"

module Rails
  module Hyperdrive
    # Renders the text bound to $PROMPT for the resolver command. The binding
    # is an ordinary object rather than a sandbox: a user-supplied template
    # runs arbitrary Ruby with the privileges of whoever ran the sync.
    module ResolvePrompt
      DEFAULT_PATH = File.expand_path("resolve/prompt.md.erb", __dir__).freeze

      KNOBS = %i[local remote base merged source previous_source kind].freeze

      class Context
        attr_reader(*KNOBS)

        def initialize(local:, remote:, base:, merged:, source:, previous_source:, kind:)
          @local = local
          @remote = remote
          @base = base
          @merged = merged
          @source = source
          @previous_source = previous_source
          @kind = kind
        end

        def template_binding
          binding
        end
      end

      module_function

      def render(template, **knobs)
        ERB.new(template, trim_mode: "-").result(Context.new(**knobs).template_binding)
      end

      def default_template
        File.read(DEFAULT_PATH)
      end
    end
  end
end
