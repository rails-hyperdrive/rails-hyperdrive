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

  def write_gemspec(name: "paired_gem", skills_dir: "skills", templates_dir: nil, filename: nil)
    metadata = []
    metadata << %(  s.metadata["rails_hyperdrive_skills_dir"] = #{skills_dir.inspect}\n) if skills_dir
    metadata << %(  s.metadata["rails_hyperdrive_skill_templates_dir"] = #{templates_dir.inspect}\n) if templates_dir
    write(filename || "#{name}.gemspec", <<~RUBY)
      Gem::Specification.new do |s|
        s.name    = #{name.inspect}
        s.version = "0.1.0"
        s.summary = "fixture"
        s.authors = ["fixture"]
      #{metadata.join}end
    RUBY
  end

  let(:template) { <<~MD }
    ---
    name: paired
    description: d
    gem: railties
    versions: ">= 7.0"
    conditional:
      references/notes.md:
        gem: sqlite3
    ---

    # Paired

    <%- if gem?("sqlite3") -%>
    SQLite <%= gem_version("sqlite3") || "(any version)" %> notes.
    <%- end -%>
  MD

  describe ".write" do
    it "renders the fail-open canonical face, keeping the installer keys" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      written = described_class.write(dir: @dir)
      expect(written.map(&:dest)).to eq([File.join(@dir, "skills/paired/SKILL.md")])

      body = File.read(File.join(@dir, "skills/paired/SKILL.md"))
      expect(body).to include("SQLite (any version) notes.")
      expect(body).not_to include("<%")
      expect(body).to include("gem: railties")
      expect(body).to include(%(versions: ">= 7.0"))
      expect(body).to include("conditional:")
    end

    it "preserves nested template layouts" do
      write_gemspec
      write("lib/paired_gem/hyperdrive/skills/cat/nested/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/cat/nested/SKILL.md"))).to be true
    end

    it "honors rails_hyperdrive_skill_templates_dir" do
      write_gemspec(templates_dir: "tpl")
      write("tpl/paired/SKILL.md.erb", template)

      described_class.write(dir: @dir)
      expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
    end

    it "errors when a template's content dir equals its template dir" do
      write_gemspec(skills_dir: nil)
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

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

    it "errors on a metadata dir containing .. segments" do
      write_gemspec(skills_dir: "../outside")
      write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)

      expect { described_class.write(dir: @dir) }
        .to raise_error(described_class::Error, /must not contain '\.\.'/)
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
