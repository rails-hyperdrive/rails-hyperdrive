require "spec_helper"
require "rails/hyperdrive/mcp_server"

RSpec.describe Rails::Hyperdrive::Tools::Base do
  def text(response)
    response.to_h[:content].first[:text]
  end

  describe ".with_dev_guard" do
    it "yields and returns the block's response in development" do
      response = described_class.with_dev_guard { described_class.respond_text("ran") }
      expect(response.to_h[:isError]).to be_falsey
      expect(text(response)).to eq("ran")
    end

    it "refuses to yield outside development" do
      allow(Rails::Hyperdrive).to receive(:dev_mode?).and_return(false)
      yielded = false

      response = described_class.with_dev_guard { yielded = true }

      expect(yielded).to be false
      expect(response.to_h[:isError]).to be true
      expect(text(response)).to eq("hyperdrive tools are disabled outside Rails.env.development?")
    end

    it "shapes an exception raised in the block into an error response" do
      response = described_class.with_dev_guard { raise ArgumentError, "bad input" }

      expect(response.to_h[:isError]).to be true
      expect(text(response)).to eq("ArgumentError: bad input")
    end
  end

  describe "every registered tool" do
    it "refuses to run outside development" do
      allow(Rails::Hyperdrive).to receive(:dev_mode?).and_return(false)
      arguments = {
        "run_ruby" => { code: "1" }, "run_sql" => { sql: "SELECT 1" },
        "locate_source" => { reference: "User" }, "lookup_doc" => { reference: "String" }
      }

      Rails::Hyperdrive::McpServer::TOOLS.each do |tool|
        response = tool.call(**arguments.fetch(tool.tool_name, {}))
        expect(response.to_h[:isError]).to(be(true), "expected #{tool.tool_name} to refuse")
        expect(text(response)).to eq("hyperdrive tools are disabled outside Rails.env.development?")
      end
    end
  end
end
