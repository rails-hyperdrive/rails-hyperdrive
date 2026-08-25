require "spec_helper"
require "rails/hyperdrive/canonical_skill_render"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Hyperdrive::CanonicalSkillRender do
  around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

  def write(rel, body)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # Roots resolve against the gemspec's directory, so the manifest carrying
  # them is written beside it.
  def write_gemspec(name: "paired_gem", skills_dir: "skills", templates_dir: nil, filename: nil, manifest: nil)
    path = filename || "#{name}.gemspec"
    write(path, <<~RUBY)
      Gem::Specification.new do |s|
        s.name    = #{name.inspect}
        s.version = "0.1.0"
        s.summary = "fixture"
        s.authors = ["fixture"]
      end
    RUBY

    keys = []
    keys << "skills_dir: #{skills_dir.inspect}\n" if skills_dir
    keys << "skill_templates_dir: #{templates_dir.inspect}\n" if templates_dir
    body = manifest || keys.join
    write(File.join(File.dirname(path), "hyperdrive.yml"), body) unless body.empty?
  end

  let(:template) { <<~MD }
    ---
    name: paired
    description: d
    allowed-tools: Read
    ---

    # Paired

    <%- if gem?("sqlite3") -%>
    SQLite <%= gem_version("sqlite3") || "(any version)" %> notes.
    <%- end -%>
  MD

  describe ".write" do
    it "renders the fail-open canonical face verbatim" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      written = described_class.write(dir: @dir)
      expect(written.map(&:dest)).to eq([File.join(@dir, "skills/paired/SKILL.md")])

      body = File.read(File.join(@dir, "skills/paired/SKILL.md"))
      expect(body).to eq(<<~MD)
        ---
        name: paired
        description: d
        allowed-tools: Read
        ---

        # Paired

        SQLite (any version) notes.
      MD
    end

    it "keeps every frontmatter key the template renders, stripping nothing" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb",
        "---\nname: paired\ndescription: d\ngem: railties\nversions: \">= 7.0\"\n---\n\n# Paired\n")

      described_class.write(dir: @dir)
      body = File.read(File.join(@dir, "skills/paired/SKILL.md"))
      expect(body).to include("gem: railties")
      expect(body).to include("versions: \">= 7.0\"")
    end

    it "preserves nested template layouts" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/cat/nested/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/cat/nested/SKILL.md"))).to be true
    end

    it "honors skill_templates_dir:" do
      write_gemspec(templates_dir: "tpl")
      write("tpl/paired/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
    end

    it "renders lib-convention templates into top-level skills/ with no manifest key declared" do
      write_gemspec(skills_dir: nil)
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      described_class.write(dir: @dir)

      expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
      expect(described_class.stale(dir: @dir)).to be_empty
      expect(described_class.public_erb_templates(dir: @dir)).to be_empty
    end

    it "errors when a template's content dir equals its template dir" do
      write_gemspec(skills_dir: "tpl", templates_dir: "tpl")
      write("tpl/paired/SKILL.md.erb", template)

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /content dir equals template dir/)
    end

    it "errors on a template that fails to render" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", "<% raise 'boom' %>\n")

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /canonical render failed/)
    end

    it "errors when the rendered output has no frontmatter" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", "# no frontmatter\n")

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /no YAML frontmatter/)
    end

    it "errors when the rendered frontmatter lacks name: or description:" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", "---\nname: paired\n---\n\n# p\n")

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /lacks name: or description:/)
    end

    it "errors on a manifest dir containing .. segments" do
      write_gemspec(skills_dir: "../outside")
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /skills_dir: must not contain '\.\.'/)
    end

    it "errors on a .. segment in the templates dir too" do
      write_gemspec(templates_dir: "../outside")
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /skill_templates_dir: must not contain '\.\.'/)
    end

    it "errors on a non-string manifest dir" do
      write_gemspec(manifest: "skills_dir:\n  - a\n  - b\n")
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /skills_dir: must be a directory path/)
    end

    it "errors on a malformed manifest rather than rendering with default roots" do
      write_gemspec(manifest: "skills_dir: [unterminated\n")
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /malformed YAML/)
    end

    it "treats a blank manifest dir as the default root" do
      write_gemspec(manifest: "skills_dir: \"  \"\n")
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
    end

    it "ignores the retired dir-override gemspec metadata keys" do
      write("paired_gem.gemspec", <<~RUBY)
        Gem::Specification.new do |s|
          s.name    = "paired_gem"
          s.version = "0.1.0"
          s.summary = "fixture"
          s.authors = ["fixture"]
          s.metadata["hyperdrive_skills_dir"] = "custom"
          s.metadata["hyperdrive_skill_templates_dir"] = "tpl"
        end
      RUBY
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
    end

    it "reads the roots from the manifest the hyperdrive_manifest metadata key names" do
      write("paired_gem.gemspec", <<~RUBY)
        Gem::Specification.new do |s|
          s.name    = "paired_gem"
          s.version = "0.1.0"
          s.summary = "fixture"
          s.authors = ["fixture"]
          s.metadata["hyperdrive_manifest"] = "config/hyperdrive.yml"
        end
      RUBY
      write("config/hyperdrive.yml", "skill_templates_dir: tpl\n")
      write("tpl/paired/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
    end
  end

  describe ".stale" do
    before do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)
    end

    it "is empty right after a render" do
      described_class.write(dir: @dir)
      expect(described_class.stale(dir: @dir)).to be_empty
    end

    it "reports a missing static face" do
      expect(described_class.stale(dir: @dir).map(&:dest))
        .to eq([File.join(@dir, "skills/paired/SKILL.md")])
    end

    it "reports a static face out of date with its template" do
      described_class.write(dir: @dir)
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template + "\nMore.\n")

      expect(described_class.stale(dir: @dir).map(&:dest))
        .to eq([File.join(@dir, "skills/paired/SKILL.md")])
    end
  end

  describe "supporting templates" do
    let(:support) { "Notes for <%= gem_version(\"sqlite3\") || \"any version\" %>.\n" }

    before do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)
    end

    it "renders each support face into the content dir, preserving layout" do
      write("lib/paired_gem/hyperdrive/skills/paired/references/notes.md.erb", support)

      written = described_class.write(dir: @dir)
      expect(written.map(&:dest)).to eq([
        File.join(@dir, "skills/paired/SKILL.md"),
        File.join(@dir, "skills/paired/references/notes.md")
      ])
      expect(File.read(File.join(@dir, "skills/paired/references/notes.md")))
        .to eq("Notes for any version.\n")
    end

    it "writes a support face without frontmatter, unvalidated" do
      write("lib/paired_gem/hyperdrive/skills/paired/references/notes.md.erb", "# just prose\n")

      expect { described_class.write(dir: @dir) }.not_to raise_error
      expect(File.read(File.join(@dir, "skills/paired/references/notes.md"))).to eq("# just prose\n")
    end

    it "reports a missing and an out-of-date support face" do
      write("lib/paired_gem/hyperdrive/skills/paired/references/notes.md.erb", support)
      expect(described_class.stale(dir: @dir).map(&:dest))
        .to include(File.join(@dir, "skills/paired/references/notes.md"))

      described_class.write(dir: @dir)
      expect(described_class.stale(dir: @dir)).to be_empty

      write("lib/paired_gem/hyperdrive/skills/paired/references/notes.md.erb", support + "More.\n")
      expect(described_class.stale(dir: @dir).map(&:dest))
        .to eq([File.join(@dir, "skills/paired/references/notes.md")])
    end
  end

  describe ".public_erb_templates" do
    before { write_gemspec }

    it "lists every *.md.erb reachable through a public skills root" do
      write("skills/paired/SKILL.md.erb", template)
      write("skills/paired/references/notes.md.erb", "notes\n")
      write("skills/paired/references/keep.md", "keep\n")

      expect(described_class.public_erb_templates(dir: @dir)).to eq([
        File.join(@dir, "skills/paired/SKILL.md.erb"),
        File.join(@dir, "skills/paired/references/notes.md.erb")
      ])
    end

    it "excludes templates-root paths" do
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)
      write("lib/paired_gem/hyperdrive/skills/paired/references/notes.md.erb", "notes\n")

      expect(described_class.public_erb_templates(dir: @dir)).to be_empty
    end

    it "scans the top-level skills dir even when it is not the declared root" do
      write_gemspec(skills_dir: "public")
      write("skills/loose/references/notes.md.erb", "notes\n")
      write("public/paired/references/notes.md.erb", "notes\n")

      expect(described_class.public_erb_templates(dir: @dir)).to eq([
        File.join(@dir, "public/paired/references/notes.md.erb"),
        File.join(@dir, "skills/loose/references/notes.md.erb")
      ])
    end
  end

  describe "gemspec resolution" do
    it "errors when the working directory has no gemspec" do
      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /no \.gemspec found/)
    end

    it "errors when the working directory has several gemspecs" do
      write_gemspec(filename: "a.gemspec")
      write_gemspec(filename: "b.gemspec")

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /multiple gemspecs found/)
    end

    it "accepts an explicit gemspec path, resolving roots against its directory" do
      write_gemspec(filename: "nested/paired_gem.gemspec")
      write("nested/lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      described_class.write(gemspec: "nested/paired_gem.gemspec", dir: @dir)
      expect(File.file?(File.join(@dir, "nested/skills/paired/SKILL.md"))).to be true
    end

    it "errors when the explicit gemspec path does not exist" do
      expect { described_class.write(gemspec: "missing.gemspec", dir: @dir) }
        .to raise_error(described_class::Error, /gemspec not found/)
    end
  end
end
