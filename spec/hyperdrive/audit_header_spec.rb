require "spec_helper"
require "digest"
require "rails/hyperdrive/audit_header"

RSpec.describe Rails::Hyperdrive::AuditHeader do
  describe ".build (YAML variant)" do
    it "builds source/sha256/installed_at comment lines" do
      header = described_class.build(source_gem: "rails-hyperdrive-sidekiq", version: "1.2.0",
        sha256: Digest::SHA256.hexdigest("hello"))
      expect(header).to include("# hyperdrive: source=rails-hyperdrive-sidekiq@1.2.0")
      expect(header).to match(/# hyperdrive: sha256=[a-f0-9]{64}/)
      expect(header).to match(/# hyperdrive: installed_at=\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe ".build_html (HTML variant)" do
    it "builds HTML-comment provenance lines" do
      header = described_class.build_html(source_gem: "internal", version: "0.2.0",
        sha256: Digest::SHA256.hexdigest("hi"))
      expect(header).to include("<!-- hyperdrive: source=internal@0.2.0 -->")
      expect(header).to match(%r{<!-- hyperdrive: sha256=[a-f0-9]{64} -->})
    end
  end

  describe "skill round-trip (inject_into_frontmatter / strip)" do
    let(:body) { "---\nname: x\ndescription: d\ngem: sidekiq\nversions: \">= 7\"\n---\n\n# Heading\n\nbody text\n" }

    it "injects into existing frontmatter then strips back to the original" do
      header = described_class.build(source_gem: "sidekiq", version: "7.3.4",
        sha256: Digest::SHA256.hexdigest(body))
      injected = described_class.inject_into_frontmatter(body, header)
      expect(injected).to include("# hyperdrive: source=sidekiq@7.3.4")
      expect(described_class.strip(injected)).to eq(body)
    end
  end

  describe "guideline/stack round-trip (prepend_html / strip)" do
    let(:body) { "# Stack\n\n- **Rails:** 8.0.1\n" }

    it "prepends an HTML header then strips back to the original" do
      header = described_class.build_html(source_gem: "internal", version: "0.2.0",
        sha256: Digest::SHA256.hexdigest(body))
      prepended = described_class.prepend_html(body, header)
      expect(prepended).to start_with("<!-- hyperdrive: source=internal@0.2.0 -->")
      expect(described_class.strip(prepended)).to eq(body)
    end
  end

  describe "inject_into_frontmatter fallback (body without frontmatter)" do
    it "wraps a frontmatter-less body in fresh frontmatter carrying the header" do
      header = described_class.build(source_gem: "g", version: "1.0",
        sha256: Digest::SHA256.hexdigest("x"))
      out = described_class.inject_into_frontmatter("# Heading\n\nbody text\n", header)
      expect(out).to start_with("---\n# hyperdrive: source=g@1.0")
      expect(out).to include("---\n\n# Heading")
    end
  end

  describe "strip safety" do
    it "leaves stray hyperdrive-looking lines in the body untouched" do
      body = "# Title\n\nSee `# hyperdrive: example` in docs.\n"
      expect(described_class.strip(body)).to eq(body)
    end
  end
end
