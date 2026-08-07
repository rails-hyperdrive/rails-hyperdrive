require "spec_helper"
require "tmpdir"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/lock_file"

RSpec.describe Rails::Hyperdrive::DriftVerdict do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  let(:skill_body) { "---\nname: x\ndescription: d\n---\n\n# Heading\n\nbody text\n" }
  let(:skill_sha) { described_class.body_sha(skill_body) }
  let(:support_bytes) { "\xFF\x00PNG binary bytes".b }
  let(:support_sha) { described_class.body_sha(support_bytes) }

  def entry(kind:, sha:)
    Rails::Hyperdrive::LockFile::Entry.new(
      path: "irrelevant", kind: kind, source_gem: "g", source_version: "1.0",
      source_sha: sha, installed_at: "2026-01-01T00:00:00Z"
    )
  end

  def install_skill(body, name: "SKILL.md")
    file = File.join(@dir, name)
    File.write(file, body)
    file
  end

  describe ".verdict" do
    context "for an installed skill" do
      it "returns :current when disk, lock, and gem agree" do
        file = install_skill(skill_body)
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:current)
      end

      it "returns :outdated when the gem now ships a different body" do
        file = install_skill(skill_body)
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha),
          gem_sha: described_class.body_sha(skill_body + "new upstream content\n")
        )
        expect(verdict).to eq(:outdated)
      end

      it "returns :edited when the file was modified after install" do
        file = install_skill(skill_body)
        File.write(file, File.read(file) + "\nuser addition\n")
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:edited)
      end

      it "returns :edited when the file exists with no lock entry" do
        file = install_skill(skill_body)
        verdict = described_class.verdict(file: file, lock_entry: nil, gem_sha: skill_sha)
        expect(verdict).to eq(:edited)
      end

      it "returns :missing when the file is absent but locked and offered" do
        file = File.join(@dir, "gone.md")
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:missing)
      end

      it "returns :missing for a fresh install (no file, no lock entry)" do
        file = File.join(@dir, "fresh.md")
        verdict = described_class.verdict(file: file, lock_entry: nil, gem_sha: skill_sha)
        expect(verdict).to eq(:missing)
      end

      it "returns :orphaned when the bundle no longer offers the dest and the file remains" do
        file = install_skill(skill_body)
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: nil
        )
        expect(verdict).to eq(:orphaned)
      end

      it "returns :missing when the bundle no longer offers the dest and the file is gone" do
        file = File.join(@dir, "gone.md")
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: nil
        )
        expect(verdict).to eq(:missing)
      end

      it "hashes raw bytes, so binary content at a markdown dest cannot raise" do
        file = File.join(@dir, "weird.md")
        File.binwrite(file, "\xFF\xFEnot utf8".b)
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill", sha: skill_sha), gem_sha: skill_sha
        )
        expect(verdict).to eq(:edited)
      end
    end

    context "for skill_support raw bytes" do
      it "returns :current for byte-identical binary content" do
        file = File.join(@dir, "asset.png")
        File.binwrite(file, support_bytes)
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill_support", sha: support_sha), gem_sha: support_sha
        )
        expect(verdict).to eq(:current)
      end

      it "returns :edited for modified binary content" do
        file = File.join(@dir, "asset.png")
        File.binwrite(file, support_bytes + "\x01".b)
        verdict = described_class.verdict(
          file: file, lock_entry: entry(kind: "skill_support", sha: support_sha), gem_sha: support_sha
        )
        expect(verdict).to eq(:edited)
      end
    end
  end

  describe "the round-trip invariant: disk_sha(installed file) == recorded body_sha" do
    it "holds for a markdown body written verbatim" do
      file = install_skill(skill_body)
      expect(described_class.disk_sha(file)).to eq(skill_sha)
    end

    it "holds for skill_support raw bytes written verbatim" do
      file = File.join(@dir, "asset.bin")
      File.binwrite(file, support_bytes)
      expect(described_class.disk_sha(file)).to eq(support_sha)
    end
  end

  describe ".unedited?" do
    it "is true/false for a markdown kind" do
      file = install_skill(skill_body)
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
end
