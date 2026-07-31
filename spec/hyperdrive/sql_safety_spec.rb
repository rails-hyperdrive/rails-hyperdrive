require "spec_helper"
require "rails/hyperdrive/sql_safety"

RSpec.describe Rails::Hyperdrive::SqlSafety do
  describe ".assert_read_only!" do
    %w[
      SELECT\ *\ FROM\ users
      \ \ SELECT\ 1
      EXPLAIN\ SELECT\ 1
      SHOW\ TABLES
      PRAGMA\ table_info(users)
    ].each do |sql|
      it "allows #{sql.inspect}" do
        expect { described_class.assert_read_only!(sql.tr('\\', " ").gsub(/  +/, " ")) }.not_to raise_error
      end
    end

    it "allows a WITH...SELECT CTE" do
      sql = "WITH x AS (SELECT 1 AS n) SELECT * FROM x"
      expect { described_class.assert_read_only!(sql) }.not_to raise_error
    end

    %w[INSERT UPDATE DELETE DROP ALTER TRUNCATE CREATE GRANT REVOKE REPLACE MERGE].each do |verb|
      it "refuses #{verb}" do
        expect { described_class.assert_read_only!("#{verb} FROM users") }
          .to raise_error(described_class::Error)
      end
    end

    it "refuses empty SQL" do
      expect { described_class.assert_read_only!("") }
        .to raise_error(described_class::Error, /empty/)
    end

    it "refuses a CTE that smuggles in a mutation" do
      sql = "WITH x AS (DELETE FROM users RETURNING *) SELECT * FROM x"
      expect { described_class.assert_read_only!(sql) }.to raise_error(described_class::Error)
    end
  end
end
