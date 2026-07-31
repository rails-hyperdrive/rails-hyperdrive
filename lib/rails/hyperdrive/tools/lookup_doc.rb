require "open3"
require "timeout"
require_relative "base"

module Rails
  module Hyperdrive
    module Tools
      class LookupDoc < Base
        tool_name "lookup_doc"
        description "Look up documentation for a Ruby/Rails symbol via `ri`. Returns markdown text."

        RI_TIMEOUT_SECONDS = 10

        input_schema(
          properties: {
            reference: { type: "string", description: "Symbol to document (e.g. 'String#strip', 'ActiveRecord::Base.find')." }
          },
          required: ["reference"]
        )

        def self.call(reference:, server_context: nil)
          with_dev_guard do
            ref = reference.to_s.strip
            stdout, stderr, status = run_ri(ref)
            return respond_error("ri not available") if status.nil?
            return respond_text(stdout) if status.success?
            first_stderr_line = stderr.to_s.lines.first.to_s.strip
            respond_error("ri exited #{status.exitstatus}: #{first_stderr_line}")
          end
        end

        # The manual timeout lets a hung ri be TERMed; a missing ri returns
        # [nil, nil, nil].
        def self.run_ri(reference)
          Open3.popen3("ri", "-T", "--format=markdown", reference) do |_in, out, err, wait_thr|
            begin
              ::Timeout.timeout(RI_TIMEOUT_SECONDS) do
                stdout = out.read
                stderr = err.read
                [stdout, stderr, wait_thr.value]
              end
            rescue ::Timeout::Error
              begin
                Process.kill("TERM", wait_thr.pid)
              rescue Errno::ESRCH
              end
              ["", "ri timeout after #{RI_TIMEOUT_SECONDS}s", FakeStatus.new(124)]
            end
          end
        rescue Errno::ENOENT
          [nil, nil, nil]
        end

        FakeStatus = Struct.new(:exitstatus) do
          def success?; false; end
        end
      end
    end
  end
end
