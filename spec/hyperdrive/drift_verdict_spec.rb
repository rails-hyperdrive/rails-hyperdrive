require "spec_helper"
require "tmpdir"
require "rails/hyperdrive/audit_header"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/lock_file"

RSpec.describe Rails::Hyperdrive::DriftVerdict do
  let(:audit_header) { Rails::Hyperdrive::AuditHeader }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  let(:skill_body) { "---\nname: x\ndescription: d\ngem: sidekiq\nversions: \">= 7\"\n---\n\n# Heading\n\nbody text\n" }
  let(:skill_sha) { described_class.body_sha(skill_body) }
  let(:support_bytes) { "\xFF\x00PNG binary bytes".b }
  let(:support_sha) { described_class.body_sha(support_bytes) }

  def entry(kind:, sha:)
    Rails::Hyperdrive::LockFile::Entry.new(
      path: "irrelevant", kind: kind, source_gem: "g", source_version: "1.0",
      source_sha: sha, installed_at: "2026-01-01T00:00:00Z"
    )
  end

  def install_skill(body, sha, name: "SKILL.md")
    file = File.join(@dir, name)
    header = audit_header.build(source_gem: "g", version: "1.0", sha256: sha)
    File.write(file, audit_header.inject_into_frontmatter(body, header))
    file
  end

  describe ".verdict" do
    context "for an installed skill (stripped-markdown kind)" do
      it "returns :current when disk, lock, and gem agree" do
        file = install_skill(skill_body, skill_sha)
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:current)
      end

      it "returns :outdated when the gem now ships a different body" do
        file = install_skill(skill_body, skill_sha)
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha),
          gem_sha: described_class.body_sha(skill_body + "new upstream content\n")
        )
        expect(verdict).to eq(:outdated)
      end

      it "returns :edited when the file was modified after install" do
        file = install_skill(skill_body, skill_sha)
        File.write(file, File.read(file) + "\nuser addition\n")
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:edited)
      end

      it "returns :edited when the file exists with no lock entry" do
        file = install_skill(skill_body, skill_sha)
        verdict = described_class.verdict(file: file, kind: "skill", lock_entry: nil, gem_sha: skill_sha)
        expect(verdict).to eq(:edited)
      end

      it "returns :missing when the file is absent but locked and offered" do
        file = File.join(@dir, "gone.md")
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:missing)
      end

      it "returns :missing for a fresh install (no file, no lock entry)" do
        file = File.join(@dir, "fresh.md")
        verdict = described_class.verdict(file: file, kind: "skill", lock_entry: nil, gem_sha: skill_sha)
        expect(verdict).to eq(:missing)
      end

      it "returns :orphaned when the bundle no longer offers the dest and the file remains" do
        file = install_skill(skill_body, skill_sha)
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: nil
        )
        expect(verdict).to eq(:orphaned)
      end

      it "returns :missing when the bundle no longer offers the dest and the file is gone" do
        file = File.join(@dir, "gone.md")
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: nil
        )
        expect(verdict).to eq(:missing)
      end

      it "resolves :orphaned without hashing, so binary content at a markdown dest cannot raise" do
        file = File.join(@dir, "weird.md")
        File.binwrite(file, "\xFF\xFEnot utf8".b)
        verdict = described_class.verdict(
          file: file, kind: "skill", lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: nil
        )
        expect(verdict).to eq(:orphaned)
      end

      it "resolves :edited without hashing when no lock entry exists, so binary content cannot raise" do
        file = File.join(@dir, "weird.md")
        File.binwrite(file, "\xFF\xFEnot utf8".b)
        verdict = described_class.verdict(file: file, kind: "skill", lock_entry: nil, gem_sha: skill_sha)
        expect(verdict).to eq(:edited)
      end
    end

    context "for skill_support raw bytes (never stripped)" do
      it "returns :current for byte-identical binary content" do
        file = File.join(@dir, "asset.png")
        File.binwrite(file, support_bytes)
        verdict = described_class.verdict(
          file: file, kind: "skill_support",
          lock_entry: entry(kind: "skill_support", sha: support_sha), gem_sha: support_sha
        )
        expect(verdict).to eq(:current)
      end

      it "returns :edited for modified binary content" do
        file = File.join(@dir, "asset.png")
        File.binwrite(file, support_bytes + "\x01".b)
        verdict = described_class.verdict(
          file: file, kind: "skill_support",
          lock_entry: entry(kind: "skill_support", sha: support_sha), gem_sha: support_sha
        )
        expect(verdict).to eq(:edited)
      end
    end
  end

  describe "the round-trip invariant: disk_sha(installed file) == recorded body_sha" do
    it "holds for the YAML-comment skill form" do
      file = install_skill(skill_body, skill_sha)
      expect(described_class.disk_sha(file, kind: "skill")).to eq(skill_sha)
    end

    it "holds for the HTML-comment guideline/stack form" do
      body = "# Stack\n\n- **Rails:** 8.0.1\n"
      recorded = described_class.body_sha(body)
      header = audit_header.build_html(source_gem: "internal", version: "0.2.0", sha256: recorded)
      file = File.join(@dir, "stack.md")
      File.write(file, audit_header.prepend_html(body, header))
      expect(described_class.disk_sha(file, kind: "guideline")).to eq(recorded)
      expect(described_class.disk_sha(file, kind: "stack")).to eq(recorded)
    end

    it "holds for skill_support raw bytes written verbatim" do
      file = File.join(@dir, "asset.bin")
      File.binwrite(file, support_bytes)
      expect(described_class.disk_sha(file, kind: "skill_support")).to eq(support_sha)
    end
  end

  describe ".unedited?" do
    it "is true/false for a stripped-markdown kind" do
      file = install_skill(skill_body, skill_sha)
      expect(described_class.unedited?(file, lock_entry: entry(kind: "skill", sha: skill_sha))).to be true
      File.write(file, File.read(file) + "edit\n")
      expect(described_class.unedited?(file, lock_entry: entry(kind: "skill", sha: skill_sha))).to be false
    end

    it "is true/false for skill_support raw bytes" do
      file = File.join(@dir, "asset.bin")
      File.binwrite(file, support_bytes)
      expect(described_class.unedited?(file, lock_entry: entry(kind: "skill_support", sha: support_sha))).to be true
      File.binwrite(file, support_bytes + "\xFE".b)
      expect(described_class.unedited?(file, lock_entry: entry(kind: "skill_support", sha: support_sha))).to be false
    end
  end

  describe ".disk_sha kind dispatch" do
    it "accepts string and symbol kinds" do
      file = File.join(@dir, "asset.bin")
      File.binwrite(file, support_bytes)
      expect(described_class.disk_sha(file, kind: "skill_support")).to eq(support_sha)
      expect(described_class.disk_sha(file, kind: :skill_support)).to eq(support_sha)

      md = install_skill(skill_body, skill_sha)
      expect(described_class.disk_sha(md, kind: "skill")).to eq(skill_sha)
      expect(described_class.disk_sha(md, kind: :skill)).to eq(skill_sha)
    end
  end
end
