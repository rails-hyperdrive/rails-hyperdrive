require "rails/hyperdrive/install_layout"

module Rails
  module Generators
    module Hyperdrive
      module InstallSummary
        KIND_ORDER = ::Rails::Hyperdrive::InstallLayout.content_kinds.map(&:lock_kind).freeze
        KIND_WIDTH = KIND_ORDER.map(&:length).max

        module_function

        # The lock is the authoritative set: it includes untouched,
        # locally-modified, and orphaned files.
        def lines(entries)
          entries = entries.to_a
          return [] if entries.empty?

          support, listed = entries.partition { |e| e.kind.to_s == "skill_support" }
          # A carried SKILL.md entry can record an older source than its
          # supporting files, so counts key on the installed directory name,
          # which is unique across sources.
          support_counts = support
            .group_by { |e| ::Rails::Hyperdrive::InstallLayout.installed_name(:skill_support, e.path.to_s) }
            .transform_values(&:size)

          out = ["  #{installed_counts(listed)}", ""]
          group_by_source(listed).each do |source, group|
            out << "    #{source}"
            group.each do |entry|
              name = display_name(entry)
              count = entry.kind.to_s == "skill" ? support_counts[name].to_i : 0
              suffix = count.positive? ? " (+#{quantify(count, "file")})" : ""
              out << "      #{entry.kind.to_s.ljust(KIND_WIDTH)}  #{name}#{suffix}"
            end
          end
          out
        end

        def installed_counts(entries)
          counts = entries.group_by { |e| e.kind.to_s }.transform_values(&:size)
          "Installed #{KIND_ORDER.map { |kind| quantify(counts[kind].to_i, kind) }.join(", ")}"
        end

        def group_by_source(entries)
          entries
            .group_by { |e| e.source_label.to_s }
            .sort_by { |source, group| [group.first.source_gem == "internal" ? 1 : 0, source] }
            .map do |source, group|
              [source, group.sort_by { |e| [KIND_ORDER.index(e.kind.to_s) || KIND_ORDER.size, display_name(e)] }]
            end
        end

        def display_name(entry)
          path = entry.path.to_s

          # A kind outside the install layout can only come from a hand-edited
          # lock, so it degrades to the filename instead of printing nothing.
          type = ::Rails::Hyperdrive::InstallLayout::ARTIFACT_TYPES[entry.kind.to_s]
          type ? ::Rails::Hyperdrive::InstallLayout.installed_name(type, path) : File.basename(path, ".md")
        end

        def quantify(count, noun)
          "#{count} #{noun}#{"s" unless count == 1}"
        end

        private_class_method :installed_counts, :group_by_source, :display_name, :quantify
      end
    end
  end
end
