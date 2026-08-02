module Rails
  module Hyperdrive
    # Renders index.md — the list of `@`-includes that decides which guidelines
    # load eagerly. Pure: the caller supplies the existing content and writes
    # the result.
    module IndexDocument
      GUIDELINE_PREFIX = "@guidelines/".freeze

      Rendered = Struct.new(:content, :guidelines, keyword_init: true)

      module_function

      # previously_installed are the guideline basenames the lock already
      # records. A guideline whose line the user deleted from an existing
      # index.md is not re-added.
      def render(guidelines:, existing:, previously_installed:)
        included = guidelines.select do |g|
          next true if existing.nil?
          next true unless previously_installed.include?(g[:base])
          existing.include?("#{GUIDELINE_PREFIX}#{g[:base]}")
        end

        lines = included.map { |g| "#{GUIDELINE_PREFIX}#{g[:base]}" }.sort

        Rendered.new(
          content: lines.empty? ? "" : lines.join("\n") + "\n",
          # Only guidelines referenced by index.md load into context, so they
          # alone make up the eager footprint.
          guidelines: included.map { |g| { name: g[:base], body: g[:body] } }
        )
      end

      # Amends an existing index in place, returning nil when there is nothing
      # to add. Existing lines carry over untouched, so an orphan keeps its
      # inclusion.
      def amend(existing:, added:)
        return nil if existing.nil?

        lines = added.map { |base| "#{GUIDELINE_PREFIX}#{base}" }
        return nil if lines.empty?

        current = existing.split("\n").map(&:strip).reject(&:empty?)
        return nil if (lines - current).empty?

        (current + lines).uniq.sort.join("\n") + "\n"
      end
    end
  end
end
