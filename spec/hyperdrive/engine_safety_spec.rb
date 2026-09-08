require "spec_helper"

# The load-bearing safety guarantee that lets us ship an `eval` tool: the
# middleware refuses traffic whenever the engine boots outside development.
RSpec.describe "Engine safety in non-development" do
  let(:app) { Rails.application }

  it "returns 403 when an MCP request comes in under Rails.env=production" do
    allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    env = Rack::MockRequest.env_for("http://localhost/_hyperdrive/mcp",
      method: "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_HOST" => "localhost",
      input: '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    )
    status, _h, _body = app.call(env)
    expect(status).to eq(403)
  end

  it "serves MCP requests in development with no Origin (loopback case)" do
    env = Rack::MockRequest.env_for("http://localhost/_hyperdrive/mcp",
      method: "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_HOST" => "localhost",
      input: '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    )
    status, _h, body = app.call(env)
    expect(status).to eq(200)
    payload = JSON.parse(body.each.to_a.join)
    names = payload.dig("result", "tools").map { |t| t["name"] }
    expect(names.length).to eq(8)
  end

  it "returns 403 when Origin is not on the allowlist" do
    env = Rack::MockRequest.env_for("http://localhost/_hyperdrive/mcp",
      method: "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_HOST" => "localhost",
      "HTTP_ORIGIN" => "https://evil.example",
      input: '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    )
    status, _h, _body = app.call(env)
    expect(status).to eq(403)
  end
end

RSpec.describe "Engine load-time warning" do
  subject(:initializer) do
    Rails::Hyperdrive::Engine.initializers.find { |i| i.name == "hyperdrive.warn_outside_development" }
  end

  let(:message) { "[hyperdrive] loaded outside development (Rails.env=production); MCP endpoints will return 403" }

  before { allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production")) }

  it "warns through the Rails logger when the engine loads outside development" do
    logger = instance_double(Logger)
    allow(::Rails).to receive(:logger).and_return(logger)

    expect(logger).to receive(:warn).with(message)
    initializer.run(Rails.application)
  end

  it "falls back to Kernel#warn before a logger exists" do
    allow(::Rails).to receive(:logger).and_return(nil)

    expect { initializer.run(Rails.application) }.to output("#{message}\n").to_stderr
  end

  it "stays silent in development" do
    allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    logger = instance_double(Logger)
    allow(::Rails).to receive(:logger).and_return(logger)

    expect(logger).not_to receive(:warn)
    expect { initializer.run(Rails.application) }.not_to output.to_stderr
  end
end
