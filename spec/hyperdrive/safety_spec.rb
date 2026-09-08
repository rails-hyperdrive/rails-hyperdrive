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

  it "reports the environment it refused under" do
    allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
    _s, _h, body = mw.call({})
    expect(JSON.parse(body.first)).to eq(
      "error" => "forbidden", "reason" => "hyperdrive is dev-only (Rails.env=staging)"
    )
  end
end
