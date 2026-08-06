require "open3"
require "tmpdir"

module Rails
  module Hyperdrive
    # Tempfiles live in the system tmpdir, never in the app, so a dry run
    # stays write-free. Fail-open: a missing or erroring git reads as
    # :unavailable, never an exception.
    module ThreeWayMerge
      Outcome = Struct.new(:status, :body, keyword_init: true) do
        def clean?
          status == :clean
        end
      end

      module_function

      def merge(ours:, base:, theirs:)
        return Outcome.new(status: :unavailable) if [ours, base, theirs].any? { |b| binary?(b) }

        Dir.mktmpdir("hyperdrive-merge") do |dir|
          paths = { "ours" => ours, "base" => base, "theirs" => theirs }.map do |name, content|
            File.join(dir, name).tap { |p| File.binwrite(p, content) }
          end

          out, _err, status = Open3.capture3("git", "merge-file", "-p", *paths)
          if status.success?
            Outcome.new(status: :clean, body: out)
          elsif status.exited? && status.exitstatus.between?(1, 127)
            # git merge-file exits with the conflict count.
            Outcome.new(status: :conflicted)
          else
            Outcome.new(status: :unavailable)
          end
        end
      rescue SystemCallError, IOError
        Outcome.new(status: :unavailable)
      end

      def binary?(content)
        s = content.to_s
        return true if s.include?("\0".b)
        !s.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end
    end
  end
end
