require "spec_helper"
require "rails/hyperdrive/safety/rack_middleware"

RSpec.describe Rails::Hyperdrive::Safety::RackMiddleware do
  let(:inner) { ->(_env) { [200, {}, ["ok"]] } }
  subject(:mw) { described_class.new(inner) }

  it "passes through requests in development with allowed origin" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://localhost:3000"})
    expect(status).to eq(200)
    expect(body.first).to eq("ok")
  end

  it "passes through requests in development with no Origin header" do
    status, _h, _body = mw.call({})
    expect(status).to eq(200)
  end

  it "403s when Rails.env != development" do
    allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    status, _h, body = mw.call({})
    expect(status).to eq(403)
    expect(body.first).to include("dev-only")
  end

  it "403s when Origin is not on the allowlist" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "https://evil.example"})
    expect(status).to eq(403)
    expect(body.first).to include("origin not allowed")
  end

  it "403s when the Origin header is not a parseable URI" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://exa mple.com"})
    expect(status).to eq(403)
    expect(body.first).to include("origin not allowed: http://exa mple.com")
  end

  it "allows the loopback IPv4 origin" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://127.0.0.1:3000"})
    expect(status).to eq(200)
    expect(body.first).to eq("ok")
  end

  it "allows the loopback IPv6 origin" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://[::1]:3000"})
    expect(status).to eq(200)
    expect(body.first).to eq("ok")
  end

  it "403s an Origin of null" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "null"})
    expect(status).to eq(403)
    expect(JSON.parse(body.first)).to eq(
      "error" => "forbidden", "reason" => "origin not allowed: null"
    )
  end

  it "403s an Origin with an unterminated IPv6 literal" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://["})
    expect(status).to eq(403)
    expect(JSON.parse(body.first)).to eq(
      "error" => "forbidden", "reason" => "origin not allowed: http://["
    )
  end

  it "403s an uppercase host, because the allowlist check is case-sensitive" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://LOCALHOST:3000"})
    expect(status).to eq(403)
    expect(JSON.parse(body.first)).to eq(
      "error" => "forbidden", "reason" => "origin not allowed: http://LOCALHOST:3000"
    )
  end

  it "403s a host that merely starts with an allowed one" do
    status, _h, body = mw.call({"HTTP_ORIGIN" => "http://localhost.evil.com"})
    expect(status).to eq(403)
    expect(JSON.parse(body.first)).to eq(
      "error" => "forbidden", "reason" => "origin not allowed: http://localhost.evil.com"
    )
  end

  it "reports the environment it refused under" do
    allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
    _s, _h, body = mw.call({})
    expect(JSON.parse(body.first)).to eq(
      "error" => "forbidden", "reason" => "hyperdrive is dev-only (Rails.env=staging)"
    )
  end
end
