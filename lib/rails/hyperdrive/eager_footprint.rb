require "rails/hyperdrive/install_layout"

module Rails
  module Hyperdrive
    # Sizes the always-in-context set — the index-included guidelines plus
    # stack.md — and returns the report as lines for a shell to print.
    module EagerFootprint
      # Soft cap on the assembled eager set — roughly six at-the-limit
      # guidelines, or ~5% of a 200k context window.
      TOTAL_WARN_TOKENS = 10_000

      Line = Struct.new(:status, :message, :color, keyword_init: true)

      module_function

      def approx_tokens(body)
        (body.to_s.length / 4.0).ceil
      end

      def lines(guidelines:, stack_body:)
        entries = guidelines.dup
        entries << { name: File.basename(InstallLayout::STACK_PATH), body: stack_body } if stack_body
        tokens = entries.sum { |e| approx_tokens(e[:body]) }

        result = [Line.new(
          status: :eager,
          message: "#{guidelines.size} guideline(s) + stack.md, ~#{tokens} tokens always in context",
          color: :cyan
        )]
        result << over_budget_line(entries) if tokens > TOTAL_WARN_TOKENS
        result
      end

      def over_budget_line(entries)
        top = entries.sort_by { |e| -approx_tokens(e[:body]) }.first(2)
          .map { |e| "#{e[:name]} ~#{approx_tokens(e[:body])}" }
        Line.new(
          status: :warn,
          message: "eager context is over the ~#{TOTAL_WARN_TOKENS} token budget (largest: #{top.join(", ")}); " \
            "trim them, or drop a line from #{InstallLayout::INDEX_PATH} to opt one out",
          color: :yellow
        )
      end

      private_class_method :over_budget_line
    end
  end
end
