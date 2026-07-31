require "fileutils"

module Rails
  module Hyperdrive
    # The filesystem and reporting surface InstallPipeline writes through.
    class InstallShell
      attr_reader :root

      def initialize(root:, io: nil, pretend: false)
        @root = File.expand_path(root.to_s)
        @io = io
        @pretend = pretend
      end

      def create_file(path, content)
        abs = File.join(@root, path)
        unless @pretend
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, content)
        end
        say_status(:create, path)
      end

      def append_to_file(path, content)
        abs = File.join(@root, path)
        File.open(abs, "a") { |f| f.write(content) } unless @pretend
        say_status(:append, path)
      end

      def say_status(kind, message, _color = nil)
        @io&.puts(format("%12s  %s", kind, message))
      end

      def say(message = "")
        @io&.puts(message)
      end
    end
  end
end
