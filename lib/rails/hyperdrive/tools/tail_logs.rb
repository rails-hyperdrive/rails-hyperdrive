require_relative "base"

module Rails
  module Hyperdrive
    module Tools
      class TailLogs < Base
        tool_name "tail_logs"
        description "Return the last N lines of a log file under Rails.root/log/. Defaults to <env>.log."

        DEFAULT_LINES = 200
        MAX_LINES = 2_000

        input_schema(
          properties: {
            lines: { type: "integer", description: "Number of trailing lines (default 200, max 2000)." },
            file:  { type: "string",  description: "Log file path. Default: log/<Rails.env>.log. Must resolve inside Rails.root/log/." }
          }
        )

        def self.call(lines: DEFAULT_LINES, file: nil, server_context: nil)
          with_dev_guard do
            n = [[lines.to_i, 1].max, MAX_LINES].min
            log_dir = ::Rails.root.join("log").expand_path
            requested = file.to_s.empty? ? "#{::Rails.env}.log" : file.to_s
            log_path = resolve_path(log_dir, requested)
            return respond_error("log not allowed: path escapes Rails.root/log/") unless log_path
            return respond_error("log not found: #{log_path}") unless File.exist?(log_path)
            respond_text(tail(log_path, n))
          end
        end

        # Path-traversal guard: the resolved target must stay inside log_dir.
        def self.resolve_path(log_dir, requested)
          base = Pathname.new(requested)
          target = base.absolute? ? base : (log_dir + base)
          target = Pathname.new(File.expand_path(target.to_s))
          return nil unless target.to_s == log_dir.to_s || target.to_s.start_with?(log_dir.to_s + File::SEPARATOR)
          target
        end

        # Pure-Ruby `tail -n` — portable and avoids shell-escaping risk.
        def self.tail(path, lines)
          block_size = 8 * 1024
          File.open(path, "rb") do |f|
            f.seek(0, IO::SEEK_END)
            file_size = f.pos
            buffer = +""
            newline_count = 0
            while f.pos > 0 && newline_count <= lines
              read_size = [block_size, f.pos].min
              f.seek(-read_size, IO::SEEK_CUR)
              chunk = f.read(read_size)
              f.seek(-read_size, IO::SEEK_CUR)
              buffer.prepend(chunk)
              newline_count = buffer.count("\n")
            end
            buffer.force_encoding(Encoding.default_external).scrub
            last = buffer.lines.last(lines).join
            last.empty? && file_size > 0 ? buffer : last
          end
        end
      end
    end
  end
end
