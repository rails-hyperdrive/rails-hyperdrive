require_relative "base"
require_relative "../sql_safety"

module Rails
  module Hyperdrive
    module Tools
      class RunSql < Base
        tool_name "run_sql"
        description "Read-only SQL via ActiveRecord::Base.connection. Rejects INSERT/UPDATE/DELETE/DROP/etc. at the parser level. Caps results at 100 rows."

        ROW_CAP = 100

        input_schema(
          properties: {
            sql: { type: "string", description: "A SELECT / WITH / EXPLAIN / SHOW / PRAGMA statement." }
          },
          required: ["sql"]
        )

        def self.call(sql:, server_context: nil)
          with_dev_guard do
            begin
              Rails::Hyperdrive::SqlSafety.assert_read_only!(sql)
            rescue Rails::Hyperdrive::SqlSafety::Error => e
              return respond_error("SQL not allowed: #{e.message}")
            end

            begin
              result = ActiveRecord::Base.connection.exec_query(sql)
            rescue ActiveRecord::ActiveRecordError => e
              return respond_error("#{e.class}: #{e.message}")
            end

            respond_text(format_table(result))
          end
        end

        def self.format_table(result)
          rows = result.rows
          shown = rows.first(ROW_CAP)
          lines = [result.columns.join("\t")]
          shown.each { |row| lines << row.map { |v| v.to_s }.join("\t") }
          lines << "(showing first #{ROW_CAP} of #{rows.length} rows)" if rows.length > ROW_CAP
          lines.join("\n")
        end
      end
    end
  end
end
