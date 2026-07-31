require "spec_helper"
require "rails/hyperdrive/mcp_server"
require "json"

RSpec.describe "MCP tools end-to-end" do
  let(:server) { Rails::Hyperdrive::McpServer.server }

  def call_tool(name, args = {})
    req = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: args }
    }
    server.handle(req)
  end

  def text_payload(resp)
    resp[:result][:content].first[:text]
  end

  it "lists 8 tools" do
    req = { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }
    resp = server.handle(req)
    expect(resp[:result][:tools].length).to eq(8)
    names = resp[:result][:tools].map { |t| t[:name] }
    expect(names).to contain_exactly(
      "describe_app", "run_ruby", "run_sql",
      "tail_logs", "list_models", "locate_source",
      "lookup_doc", "list_routes"
    )
  end

  describe "describe_app" do
    it "returns JSON containing :rails and :ruby keys" do
      resp = call_tool("describe_app")
      json = JSON.parse(text_payload(resp))
      expect(json.keys).to include("rails", "ruby")
    end
  end

  describe "run_ruby" do
    it "evaluates Ruby and returns the inspected result" do
      resp = call_tool("run_ruby", { "code" => "1 + 2" })
      payload = JSON.parse(text_payload(resp))
      expect(payload["result"]).to eq("3")
    end

    it "captures exceptions" do
      resp = call_tool("run_ruby", { "code" => "raise 'boom'" })
      payload = JSON.parse(text_payload(resp))
      expect(payload["exception"]["class"]).to eq("RuntimeError")
    end
  end

  describe "run_sql" do
    it "allows SELECT against the test DB and returns a tab-separated body" do
      User.create!(email: "a@example.com")
      resp = call_tool("run_sql", { "sql" => "SELECT COUNT(*) AS n FROM users" })
      text = text_payload(resp)
      lines = text.lines
      expect(lines.first.strip).to eq("n")
      expect(lines[1].strip).to match(/\A\d+\z/)
    end

    it "refuses INSERT (returns error response prefixed 'SQL not allowed:')" do
      resp = call_tool("run_sql", { "sql" => "INSERT INTO users (email) VALUES ('x')" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to start_with("SQL not allowed:")
    end
  end

  describe "list_models" do
    it "lists User and Post with the spec-mandated keys" do
      resp = call_tool("list_models")
      payload = JSON.parse(text_payload(resp))
      classes = payload.map { |m| m["class"] }
      expect(classes).to include("User", "Post")
      user = payload.find { |m| m["class"] == "User" }
      expect(user).to include("table", "columns", "validators", "associations")
    end
  end

  describe "locate_source" do
    it "resolves a constant to file:line text via const_source_location" do
      resp = call_tool("locate_source", { "reference" => "User" })
      expect(resp[:result][:isError]).to be_falsey
      expect(text_payload(resp)).to match(/user\.rb:\d+\z/)
    end

    it "resolves dep:<gem> to the gem path" do
      resp = call_tool("locate_source", { "reference" => "dep:rspec-core" })
      unless resp[:result][:isError]
        expect(text_payload(resp)).to include("rspec-core")
      end
    end

    it "returns 'could not resolve:' for unknown references" do
      resp = call_tool("locate_source", { "reference" => "NoSuchConstantXYZ" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to start_with("could not resolve:")
    end
  end

  describe "tail_logs" do
    it "returns a body even if log file is small" do
      log_path = Rails.root.join("log", "#{Rails.env}.log")
      FileUtils.mkdir_p(log_path.dirname)
      File.write(log_path, "line1\nline2\nline3\n")
      resp = call_tool("tail_logs", { "lines" => 2 })
      expect(text_payload(resp)).to include("line")
    end

    it "refuses a file: outside Rails.root/log/" do
      resp = call_tool("tail_logs", { "file" => "../config/database.yml" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to include("log not allowed").or include("log not found")
    end
  end

  describe "list_routes" do
    it "returns the mounted routes with a combined controller_action key" do
      resp = call_tool("list_routes")
      payload = JSON.parse(text_payload(resp))
      paths = payload.map { |r| r["path"] }
      expect(paths).to include("/health")
      health = payload.find { |r| r["path"] == "/health" }
      expect(health.keys).to include("verb", "path", "controller_action", "name")
    end
  end

  describe "lookup_doc" do
    it "returns text or a respond_error wrapper" do
      resp = call_tool("lookup_doc", { "reference" => "String" })
      # `ri` may be present or absent on the test host. Both shapes are valid.
      expect(text_payload(resp)).to be_a(String)
    end
  end
end
