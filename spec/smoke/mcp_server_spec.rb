require "json"
require "sqlite3"
require_relative "smoke_helper"

RSpec.describe "MCP server smoke", :smoke do
  let(:app_dir) { Smoke.copy_fixture("full_stack") }

  let(:log_lines) do
    [
      %(I, [smoke] INFO -- : Started GET "/first"),
      %(I, [smoke] INFO -- : Started GET "/second"),
      %(I, [smoke] INFO -- : Started GET "/third")
    ]
  end

  # The model, the schema, and the log file are all read by the booted server,
  # so they have to exist before it starts.
  def prepare_app!
    File.write(File.join(app_dir, "app/models/widget.rb"), <<~RUBY)
      class Widget < ApplicationRecord
        validates :name, presence: true
      end
    RUBY

    FileUtils.mkdir_p(File.join(app_dir, "db"))
    SQLite3::Database.new(File.join(app_dir, "db/development.sqlite3")) do |db|
      db.execute("CREATE TABLE IF NOT EXISTS widgets (id INTEGER PRIMARY KEY, name VARCHAR)")
    end

    FileUtils.mkdir_p(File.join(app_dir, "log"))
    File.write(File.join(app_dir, "log/development.log"), log_lines.join("\n") + "\n")
  end

  describe "against a booted development server" do
    around do |ex|
      Smoke.add_path_gem!(app_dir)
      Smoke.add_companion_gem!(app_dir, "rails-hyperdrive-alpha")
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      raise "hyperdrive:init failed:\n#{out}" unless status.success?
      prepare_app!
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

    it "run_ruby evaluates in the booted process and captures stdout" do
      resp = Smoke.mcp_call(@port, "tools/call",
        {name: "run_ruby", arguments: {code: %(puts "hi"; 21 * 2)}})
      result = JSON.parse(resp.dig("result", "content", 0, "text"))
      expect(result["result"]).to eq("42")
      expect(result["stdout"]).to eq("hi\n")
      expect(result["exception"]).to be_nil
    end

    it "tail_logs returns the trailing lines and refuses a path outside log/" do
      resp = Smoke.mcp_call(@port, "tools/call", {name: "tail_logs", arguments: {lines: 2}})
      text = resp.dig("result", "content", 0, "text")
      expect(text).to eq(log_lines.last(2).join("\n") + "\n")

      escape = Smoke.mcp_call(@port, "tools/call",
        {name: "tail_logs", arguments: {file: "../config/database.yml"}})
      expect(escape.dig("result", "isError")).to be(true)
      expect(escape.dig("result", "content", 0, "text"))
        .to include("log not allowed: path escapes Rails.root/log/")
    end

    it "list_models describes the app's models and their validations" do
      resp = Smoke.mcp_call(@port, "tools/call", {name: "list_models", arguments: {}})
      models = JSON.parse(resp.dig("result", "content", 0, "text"))
      widget = models.find { |m| m["class"] == "Widget" }
      expect(widget).not_to be_nil, "Widget missing from list_models: #{models.inspect}"
      expect(widget["table"]).to eq("widgets")
      expect(widget["validators"]).to include(a_hash_including("attribute" => "name", "kind" => "presence"))
    end

    it "locate_source resolves a constant, a gem, and reports an unresolvable reference" do
      # const_source_location on an unloaded autoload reports Zeitwerk's
      # registration site, so the app's own file is the answer only once the
      # constant is resolved.
      Smoke.mcp_call(@port, "tools/call", {name: "run_ruby", arguments: {code: "ApplicationController"}})

      const = Smoke.mcp_call(@port, "tools/call",
        {name: "locate_source", arguments: {reference: "ApplicationController"}})
      expect(const.dig("result", "content", 0, "text"))
        .to end_with("app/controllers/application_controller.rb:1")

      gem = Smoke.mcp_call(@port, "tools/call",
        {name: "locate_source", arguments: {reference: "dep:puma"}})
      expect(gem.dig("result", "content", 0, "text")).to include("/gems/puma-")

      missing = Smoke.mcp_call(@port, "tools/call",
        {name: "locate_source", arguments: {reference: "Nope::Missing"}})
      expect(missing.dig("result", "isError")).to be(true)
      expect(missing.dig("result", "content", 0, "text")).to include("could not resolve: Nope::Missing")
    end

    it "list_routes reports the mounted engine" do
      resp = Smoke.mcp_call(@port, "tools/call", {name: "list_routes", arguments: {}})
      routes = JSON.parse(resp.dig("result", "content", 0, "text"))
      mount = routes.find { |r| r["path"] == "/_hyperdrive" }
      expect(mount).not_to be_nil, "engine mount missing from list_routes: #{routes.inspect}"
      expect(mount["name"]).to eq("rails_hyperdrive")
      expect(mount["controller_action"]).to be_nil
    end

    it "serves both resource families and reports an unknown URI as invalid params" do
      listed = Smoke.mcp_call(@port, "resources/list")
      uris = listed.dig("result", "resources").map { |r| r["uri"] }
      expect(uris).to include(
        "hyperdrive://stack-profile",
        "hyperdrive://skills/alpha-skill",
        "hyperdrive://skills/shared-skill"
      )

      templates = Smoke.mcp_call(@port, "resources/templates/list")
      expect(templates.dig("result", "resourceTemplates").map { |t| t["uriTemplate"] })
        .to include("hyperdrive://skills/{name}")

      skill = Smoke.mcp_call(@port, "resources/read", {uri: "hyperdrive://skills/alpha-skill"})
      body = skill.dig("result", "contents", 0, "text")
      expect(body).to start_with("---")
      expect(body).to include("name: alpha-skill")

      profile = Smoke.mcp_call(@port, "resources/read", {uri: "hyperdrive://stack-profile"})
      expect(JSON.parse(profile.dig("result", "contents", 0, "text")).dig("rails", "version"))
        .to match(/\A\d+\.\d+/)

      unknown = Smoke.mcp_call(@port, "resources/read", {uri: "hyperdrive://nope"})
      expect(unknown.dig("error", "code")).to eq(-32602)
      expect(unknown.dig("error", "message")).to eq("Invalid params")
      expect(unknown.dig("error", "data")).to include("Resource not found: hyperdrive://nope")
    end

    it "refuses a request whose Origin is outside the allowlist" do
      status, body = Smoke.mcp_post(@port, "tools/list", origin: "http://evil.example")
      expect(status).to eq(403)
      expect(JSON.parse(body))
        .to eq("error" => "forbidden", "reason" => "origin not allowed: http://evil.example")
    end
  end

  describe "against a server booted outside development" do
    let(:app_dir) { Smoke.copy_fixture("minimal") }

    around do |ex|
      Smoke.add_path_gem!(app_dir)
      Smoke.bundle_install!(app_dir)
      out, status = Smoke.run_hyperdrive_init!(app_dir)
      raise "hyperdrive:init failed:\n#{out}" unless status.success?
      # The generator guards the mount with Rails.env.development?, so the
      # middleware's own refusal is only reachable once the route exists.
      routes = File.join(app_dir, "config/routes.rb")
      File.write(routes, File.read(routes).sub(" if Rails.env.development?", ""))
      pid, port = Smoke.boot_server!(app_dir, env: {
        "RAILS_ENV" => "production",
        "SECRET_KEY_BASE" => "smoke",
        "DATABASE_URL" => "sqlite3:db/production.sqlite3"
      })
      @port = port
      begin
        ex.run
      ensure
        Smoke.stop_server!(pid)
      end
    end

    it "refuses every request" do
      status, body = Smoke.mcp_post(@port, "tools/list")
      expect(status).to eq(403)
      expect(JSON.parse(body))
        .to eq("error" => "forbidden", "reason" => "hyperdrive is dev-only (Rails.env=production)")
    end
  end
end
