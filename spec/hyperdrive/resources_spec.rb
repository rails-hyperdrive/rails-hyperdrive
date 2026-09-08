require "spec_helper"
require "rails/hyperdrive/mcp_server"
require "json"

RSpec.describe "MCP resources end-to-end" do
  let(:server) { Rails::Hyperdrive::McpServer.server }

  def call_read(uri)
    req = {
      jsonrpc: "2.0",
      id: 1,
      method: "resources/read",
      params: { uri: uri }
    }
    server.handle(req)
  end

  describe "hyperdrive://stack-profile" do
    let(:lockfile) { File.expand_path("../fixtures/gemfile_lock/standard.lock", __dir__) }

    before do
      allow(Rails::Hyperdrive::StackProfile).to receive(:default_lockfile_path).and_return(lockfile)
    end

    it "returns the resolved stack facts as JSON" do
      contents = call_read("hyperdrive://stack-profile")[:result][:contents].first
      payload = JSON.parse(contents[:text])

      expect(contents[:uri]).to eq("hyperdrive://stack-profile")
      expect(contents[:mimeType]).to eq("application/json")
      expect(payload["rails"]).to eq("version" => "8.0.1", "major" => 8)
      expect(payload["ruby"]["version"]).to start_with("3.3.6")
      expect(payload["database"]["adapter"]).to eq("sqlite3")
      expect(payload).not_to have_key("error")
    end

    it "lists the app's direct dependencies only" do
      payload = JSON.parse(call_read("hyperdrive://stack-profile")[:result][:contents].first[:text])
      names = payload["direct_dependencies"].map { |d| d["name"] }

      expect(names).to include("devise", "pundit", "sidekiq")
      expect(names).not_to include("minitest", "actionpack")
    end
  end

  describe "hyperdrive://skills/{name}" do
    it "returns the body of an installed SKILL.md" do
      resp = call_read("hyperdrive://skills/sample")
      contents = resp[:result][:contents].first
      expect(contents[:mimeType]).to eq("text/markdown")
      expect(contents[:text]).to include("hello body")
    end

    it "reports an unknown skill via JSON-RPC error (resource-not-found)" do
      resp = call_read("hyperdrive://skills/no-such-skill")
      expect(resp[:error][:data]).to include("Resource not found")
    end

    it "rejects path-traversal attempts via JSON-RPC error" do
      resp = call_read("hyperdrive://skills/..%2F..%2Fetc%2Fpasswd")
      expect(resp[:error][:data]).to include("Resource not found")
    end
  end

  describe "an URI belonging to no resource family" do
    it "reports invalid params naming the URI" do
      resp = call_read("hyperdrive://nope")

      expect(resp[:error][:code]).to eq(-32602)
      expect(resp[:error][:data]).to include("Resource not found: hyperdrive://nope")
      expect(resp[:result]).to be_nil
    end

    it "reports a missing uri param the same way" do
      req = { jsonrpc: "2.0", id: 1, method: "resources/read", params: {} }

      expect(server.handle(req)[:error][:data]).to include("Resource not found:")
    end
  end

  describe "resources/list" do
    it "advertises hyperdrive://stack-profile and any installed hyperdrive://skills/* URIs" do
      req = { jsonrpc: "2.0", id: 1, method: "resources/list", params: {} }
      resp = Rails::Hyperdrive::McpServer.server.handle(req)
      uris = resp[:result][:resources].map { |r| r[:uri] }
      expect(uris).to include("hyperdrive://stack-profile")
      expect(uris).to include("hyperdrive://skills/sample")
    end
  end

  describe "resources/templates/list" do
    it "advertises the skill template" do
      req = { jsonrpc: "2.0", id: 1, method: "resources/templates/list", params: {} }
      resp = Rails::Hyperdrive::McpServer.server.handle(req)

      expect(resp[:result][:resourceTemplates].map { |t| t[:uriTemplate] })
        .to include("hyperdrive://skills/{name}")
    end
  end
end
