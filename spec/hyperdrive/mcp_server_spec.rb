require "spec_helper"

RSpec.describe Rails::Hyperdrive::McpServer do
  describe ".rack_app" do
    it "memoizes the built app" do
      expect(described_class.rack_app).to equal(described_class.rack_app)
    end

    it "builds a new app after reset!" do
      first = described_class.rack_app
      described_class.reset!
      expect(described_class.rack_app).not_to equal(first)
    end

    it "takes no arguments" do
      expect { described_class.rack_app(allowed_hosts: ["example.com"]) }.to raise_error(ArgumentError)
    end
  end
end
