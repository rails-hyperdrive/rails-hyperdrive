require "json"
require_relative "smoke_helper"

RSpec.describe "MCP server smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("full_stack") }

  around do |ex|
    Smoke.add_path_gem!(app_dir)
    Smoke.bundle_install!(app_dir)
    Smoke.run_hyperdrive_init!(app_dir)
    pid, port = Smoke.boot_server!(app_dir)
    @port = port
    begin
      ex.run
    ensure
      Smoke.stop_server!(pid)
    end
  end

  it "lists all eight tools via tools/list" do
    resp = Smoke.mcp_call(@port, "tools/list")
    names = resp.dig("result", "tools").map { |t| t["name"] }
    expect(names).to contain_exactly(
      "describe_app", "run_ruby", "run_sql", "tail_logs",
      "list_models", "locate_source", "lookup_doc", "list_routes"
    )
  end

  it "describe_app reports direct dependencies from the resolved Gemfile.lock" do
    resp = Smoke.mcp_call(@port, "tools/call", {name: "describe_app", arguments: {}})
    text = resp.dig("result", "content", 0, "text")
    info = JSON.parse(text)
    expect(info.dig("rails", "version")).to match(/\A\d+\.\d+/)
    names = info["direct_dependencies"].map { |g| g["name"] }
    expect(names).to include("devise", "sidekiq", "pundit")
    # minitest is always resolved transitively via activesupport.
    expect(names).not_to include("minitest")
  end

  it "lookup_doc returns a structured response (not a crash) for a stdlib symbol" do
    resp = Smoke.mcp_call(@port, "tools/call", {name: "lookup_doc", arguments: {reference: "String#strip"}})
    content = resp.dig("result", "content", 0, "text")
    expect(content).to be_a(String)
    expect(content).not_to be_empty
  end

  it "run_sql accepts a SELECT" do
    resp = Smoke.mcp_call(@port, "tools/call", {name: "run_sql", arguments: {sql: "SELECT 1 AS one"}})
    text = resp.dig("result", "content", 0, "text")
    expect(text).to include("one")
  end

  it "run_sql rejects a write" do
    resp = Smoke.mcp_call(@port, "tools/call", {name: "run_sql", arguments: {sql: "DELETE FROM users"}})
    is_error = resp.dig("result", "isError")
    expect(is_error).to be(true)
  end
end
