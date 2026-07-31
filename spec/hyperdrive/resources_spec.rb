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
    it "returns JSON describing the resolved StackProfile" do
      resp = call_read("hyperdrive://stack-profile")
      contents = resp[:result][:contents].first
      expect(contents[:mimeType]).to eq("application/json")
      payload = JSON.parse(contents[:text])
      # spec/internal ships no Gemfile.lock, so the profile resolves to the :error sentinel.
      expect(payload.keys).to include("rails", "ruby")
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

  describe "resources/list" do
    it "advertises hyperdrive://stack-profile and any installed hyperdrive://skills/* URIs" do
      req = { jsonrpc: "2.0", id: 1, method: "resources/list", params: {} }
      resp = Rails::Hyperdrive::McpServer.server.handle(req)
      uris = resp[:result][:resources].map { |r| r[:uri] }
      expect(uris).to include("hyperdrive://stack-profile")
      expect(uris).to include("hyperdrive://skills/sample")
    end
  end
end
