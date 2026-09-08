require "spec_helper"
require "rails/hyperdrive"

RSpec.describe Rails::Hyperdrive do
  describe ".root" do
    it "points at the gem's lib directory" do
      expect(File.file?(File.join(described_class.root, "rails/hyperdrive.rb"))).to be true
    end

    it "is memoized" do
      expect(described_class.root).to equal(described_class.root)
    end
  end

  describe ".dev_mode?" do
    it "is true under Rails.env.development?" do
      expect(described_class.dev_mode?).to be true
    end

    it "is false in any other environment" do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      expect(described_class.dev_mode?).to be false
    end
  end
end
