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
    let(:lockfile) { File.expand_path("../fixtures/gemfile_lock/standard.lock", __dir__) }

    before do
      allow(Rails::Hyperdrive::StackProfile).to receive(:default_lockfile_path).and_return(lockfile)
    end

    it "reports the stack facts parsed from the app's lockfile" do
      json = JSON.parse(text_payload(call_tool("describe_app")))

      expect(json["rails"]).to eq("version" => "8.0.1", "major" => 8)
      expect(json["ruby"]["version"]).to start_with("3.3.6")
      expect(json["database"]["adapter"]).to eq("sqlite3")
      expect(json).not_to have_key("error")
    end

    it "reports direct dependencies and omits resolved-but-transitive gems" do
      json = JSON.parse(text_payload(call_tool("describe_app")))
      names = json["direct_dependencies"].map { |d| d["name"] }

      expect(json["direct_dependencies"]).to include("name" => "devise", "version" => "4.9.4")
      expect(names).to include("pundit", "sidekiq")
      expect(names).not_to include("minitest", "actionpack")
    end
  end

  describe "run_ruby" do
    it "evaluates Ruby and returns the inspected result" do
      resp = call_tool("run_ruby", { "code" => "1 + 2" })
      payload = JSON.parse(text_payload(resp))
      expect(payload["result"]).to eq("3")
    end

    it "clamps a timeout above the maximum" do
      expect(Rails::Hyperdrive::ConsoleExecutor)
        .to receive(:eval)
        .with("1", timeout: Rails::Hyperdrive::Tools::RunRuby::MAX_TIMEOUT_SECONDS)
        .and_call_original

      call_tool("run_ruby", { "code" => "1", "timeout" => 999 })
    end

    it "clamps a timeout below one second" do
      expect(Rails::Hyperdrive::ConsoleExecutor)
        .to receive(:eval).with("1", timeout: 1).and_call_original

      call_tool("run_ruby", { "code" => "1", "timeout" => 0 })
    end

    it "uses the default timeout when none is given" do
      expect(Rails::Hyperdrive::ConsoleExecutor)
        .to receive(:eval)
        .with("1", timeout: Rails::Hyperdrive::ConsoleExecutor::DEFAULT_TIMEOUT_SECONDS)
        .and_call_original

      call_tool("run_ruby", { "code" => "1" })
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

    it "caps oversized results and reports how many of the total are shown" do
      cap = Rails::Hyperdrive::Tools::RunSql::ROW_CAP
      total = cap + 5
      resp = call_tool("run_sql", {
        "sql" => "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < #{total}) SELECT n FROM seq"
      })
      lines = text_payload(resp).lines

      expect(lines.length).to eq(cap + 2)
      expect(lines.last.strip).to eq("(showing first #{cap} of #{total} rows)")
    end

    it "returns only the header line for a zero-row result" do
      resp = call_tool("run_sql", { "sql" => "SELECT * FROM users WHERE 1 = 0" })

      expect(text_payload(resp)).to eq(User.column_names.join("\t"))
    end

    it "refuses INSERT (returns error response prefixed 'SQL not allowed:')" do
      resp = call_tool("run_sql", { "sql" => "INSERT INTO users (email) VALUES ('x')" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to start_with("SQL not allowed:")
    end

    it "reports an allowed statement the database rejects" do
      resp = call_tool("run_sql", { "sql" => "SELECT * FROM no_such_table" })

      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to start_with("ActiveRecord::StatementInvalid:")
      expect(text_payload(resp)).to include("no_such_table")
    end
  end

  describe "list_models" do
    subject(:payload) { JSON.parse(text_payload(call_tool("list_models"))) }

    # Columns come back empty until the process has opened a connection.
    before { User.count }

    it "describes every model's table, columns, validators, and associations" do
      user = payload.find { |m| m["class"] == "User" }
      post = payload.find { |m| m["class"] == "Post" }

      expect(payload.map { |m| m["class"] }).to include("Post", "User")
      expect(user["table"]).to eq("users")
      expect(user["columns"]).to include(hash_including("name" => "email", "type" => "string"))
      expect(user["validators"]).to include(hash_including("attribute" => "email", "kind" => "presence"))
      expect(user["associations"]).to include(
        { "name" => "posts", "macro" => "has_many", "class_name" => "Post" }
      )
      expect(post["associations"]).to include(
        { "name" => "user", "macro" => "belongs_to", "class_name" => "User" }
      )
    end

    it "sorts models by class name" do
      classes = payload.map { |m| m["class"] }
      expect(classes).to eq(classes.sort)
    end

    it "reports a model whose description blows up without dropping the rest" do
      allow(Rails::Hyperdrive::Tools::ListModels).to receive(:describe).and_call_original
      allow(Rails::Hyperdrive::Tools::ListModels)
        .to receive(:describe).with(User).and_raise(TypeError, "broken class")

      user = payload.find { |m| m["class"] == "User" }
      expect(user).to eq("class" => "User", "errors" => ["TypeError: broken class"])
      expect(payload.find { |m| m["class"] == "Post" }).to include("table" => "posts")
    end

    describe "per-facet failures" do
      let(:tool) { Rails::Hyperdrive::Tools::ListModels }
      let(:model) { class_double(ActiveRecord::Base, name: "Broken") }

      it "inlines the error when a scalar attribute raises" do
        allow(model).to receive(:table_name).and_raise(RuntimeError, "no table")
        expect(tool.safe(model, :table_name)).to eq("<error: RuntimeError: no table>")
      end

      it "reports the error as the sole column when columns raise" do
        allow(model).to receive(:connected?).and_return(true)
        allow(model).to receive(:columns).and_raise(ActiveRecord::StatementInvalid, "no such table")

        expect(tool.safe_columns(model)).to eq([{ error: "ActiveRecord::StatementInvalid: no such table" }])
      end

      it "reports no columns before a connection exists" do
        allow(model).to receive(:connected?).and_return(false)
        allow(ActiveRecord::Base).to receive(:connected?).and_return(false)

        expect(tool.safe_columns(model)).to eq([])
      end

      it "falls back to an empty list when validators raise" do
        allow(model).to receive(:validators).and_raise(NoMethodError, "nope")
        expect(tool.safe_validators(model)).to eq([])
      end

      it "falls back to an empty list when associations raise" do
        allow(model).to receive(:reflect_on_all_associations).and_raise(NoMethodError, "nope")
        expect(tool.safe_associations(model)).to eq([])
      end

      it "reports a nil class_name for an association that cannot name its class" do
        association = double("reflection", name: :things, macro: :has_many)
        allow(association).to receive(:class_name).and_raise(NameError, "uninitialized constant Thing")
        allow(model).to receive(:reflect_on_all_associations).and_return([association])

        expect(tool.safe_associations(model))
          .to eq([{ name: "things", macro: "has_many", class_name: nil }])
      end
    end
  end

  describe "locate_source" do
    def resolve(reference)
      resp = call_tool("locate_source", { "reference" => reference })
      [resp[:result][:isError], text_payload(resp)]
    end

    it "resolves a bare constant through const_source_location" do
      error, text = resolve("User")
      expect(error).to be_falsey
      expect(text).to match(%r{/user\.rb:\d+\z})
    end

    it "resolves a namespaced constant against its owning module" do
      error, text = resolve("Rails::Hyperdrive::Safety::RackMiddleware::DEFAULT_ALLOWED_HOSTS")
      expect(error).to be_falsey
      expect(text).to match(%r{/lib/rails/hyperdrive/safety/rack_middleware\.rb:\d+\z})
    end

    it "resolves Const#instance_method" do
      error, text = resolve("Rails::Hyperdrive::StackProfile#parse!")
      expect(error).to be_falsey
      expect(text).to match(%r{/lib/rails/hyperdrive/stack_profile\.rb:\d+\z})
    end

    it "resolves Const.class_method" do
      error, text = resolve("Rails::Hyperdrive::StackProfile.from_lockfile")
      expect(error).to be_falsey
      expect(text).to match(%r{/lib/rails/hyperdrive/stack_profile\.rb:\d+\z})
    end

    it "resolves dep:<gem> to the gem's full path" do
      error, text = resolve("dep:rspec-core")
      expect(error).to be_falsey
      expect(text).to match(%r{/rspec-core-\d+\.\d+})
      expect(File.directory?(text)).to be true
    end

    it "refuses an instance method the class does not define" do
      expect(resolve("User#no_such_method")).to eq([true, "could not resolve: User#no_such_method"])
    end

    it "refuses a class method the class does not respond to" do
      expect(resolve("User.no_such_method")).to eq([true, "could not resolve: User.no_such_method"])
    end

    it "refuses a method defined in C, which reports no source location" do
      expect(resolve("String#strip")).to eq([true, "could not resolve: String#strip"])
      expect(resolve("String.new")).to eq([true, "could not resolve: String.new"])
    end

    it "refuses an unknown constant" do
      expect(resolve("NoSuchConstantXYZ")).to eq([true, "could not resolve: NoSuchConstantXYZ"])
    end

    it "refuses a method reference whose namespace does not exist" do
      expect(resolve("NoSuch::Thing#call")).to eq([true, "could not resolve: NoSuch::Thing#call"])
    end

    it "refuses an unbundled dep:<gem>" do
      expect(resolve("dep:no_such_gem_xyz")).to eq([true, "could not resolve: dep:no_such_gem_xyz"])
    end

    it "constantizes without ActiveSupport's String#constantize" do
      allow(String).to receive(:method_defined?).with(:constantize).and_return(false)

      expect(Rails::Hyperdrive::Tools::LocateSource.constantize("Rails::Hyperdrive::StackProfile"))
        .to equal(Rails::Hyperdrive::StackProfile)
    end
  end

  describe "tail_logs" do
    let(:log_path) { Rails.root.join("log", "#{Rails.env}.log") }

    before do
      FileUtils.mkdir_p(log_path.dirname)
      File.write(log_path, (1..5).map { |n| "line#{n}\n" }.join)
    end

    after { FileUtils.rm_f(log_path) }

    it "returns only the trailing lines asked for" do
      expect(text_payload(call_tool("tail_logs", { "lines" => 2 }))).to eq("line4\nline5\n")
    end

    it "returns the whole file when it holds fewer lines than requested" do
      expect(text_payload(call_tool("tail_logs", { "lines" => 100 })))
        .to eq("line1\nline2\nline3\nline4\nline5\n")
    end

    it "clamps a line count above the maximum" do
      max = Rails::Hyperdrive::Tools::TailLogs::MAX_LINES
      File.write(log_path, (1..(max + 5)).map { |n| "line#{n}\n" }.join)

      lines = text_payload(call_tool("tail_logs", { "lines" => 5000 })).lines

      expect(lines.length).to eq(max)
      expect(lines.first).to eq("line6\n")
      expect(lines.last).to eq("line#{max + 5}\n")
    end

    it "clamps a line count below one" do
      expect(text_payload(call_tool("tail_logs", { "lines" => 0 }))).to eq("line5\n")
    end

    it "reads a named file under log/" do
      File.write(Rails.root.join("log", "other.log"), "other\n")

      expect(text_payload(call_tool("tail_logs", { "file" => "other.log" }))).to eq("other\n")
    ensure
      FileUtils.rm_f(Rails.root.join("log", "other.log"))
    end

    it "refuses a file: that escapes Rails.root/log/" do
      resp = call_tool("tail_logs", { "file" => "../config/database.yml" })

      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to eq("log not allowed: path escapes Rails.root/log/")
    end

    it "reports a log file that does not exist" do
      resp = call_tool("tail_logs", { "file" => "absent.log" })

      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to start_with("log not found:")
      expect(text_payload(resp)).to end_with("log/absent.log")
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
    let(:tool) { Rails::Hyperdrive::Tools::LookupDoc }

    def stub_ri(stdout:, stderr:, status:)
      allow(Open3).to receive(:popen3) do |*args, &block|
        expect(args).to eq(["ri", "-T", "--format=markdown", "String#strip"])
        block.call(nil, StringIO.new(stdout), StringIO.new(stderr), double(pid: 4321, value: status))
      end
    end

    it "returns ri's markdown on success" do
      stub_ri(stdout: "# String#strip\n", stderr: "", status: double(success?: true))

      resp = call_tool("lookup_doc", { "reference" => "String#strip" })
      expect(resp[:result][:isError]).to be_falsey
      expect(text_payload(resp)).to eq("# String#strip\n")
    end

    it "reports ri's exit status and first stderr line on failure" do
      stub_ri(stdout: "", stderr: "Nothing known about String#strip\nmore\n",
        status: double(success?: false, exitstatus: 1))

      resp = call_tool("lookup_doc", { "reference" => "String#strip" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to eq("ri exited 1: Nothing known about String#strip")
    end

    it "reports a missing ri executable" do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, "ri")

      resp = call_tool("lookup_doc", { "reference" => "String#strip" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp)).to eq("ri not available")
    end

    it "TERMs a hung ri and reports the timeout" do
      stub_ri(stdout: "", stderr: "", status: double(success?: true))
      allow(::Timeout).to receive(:timeout).and_raise(::Timeout::Error)
      expect(Process).to receive(:kill).with("TERM", 4321).and_raise(Errno::ESRCH)

      resp = call_tool("lookup_doc", { "reference" => "String#strip" })
      expect(resp[:result][:isError]).to be true
      expect(text_payload(resp))
        .to eq("ri exited 124: ri timeout after #{tool::RI_TIMEOUT_SECONDS}s")
    end
  end
end
