require "spec_helper"
require "rake"
require "fileutils"
require "tmpdir"

RSpec.describe "hyperdrive:skills rake tasks" do
  around { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

  before do
    Rake.application = Rake::Application.new
    load File.expand_path("../../lib/rails/hyperdrive/skill_tasks.rb", __dir__)
  end

  def write(rel, body)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def invoke(task, *args)
    Dir.chdir(@dir) { Rake::Task[task].invoke(*args) }
  end

  def quiet_render
    expect { invoke("hyperdrive:skills:render") }.to output(/render /).to_stdout
  end

  let(:template) { "---\nname: paired\ndescription: d\ngem: \"*\"\nversions: \"*\"\n---\n\n# Paired\n" }

  before do
    write("paired_gem.gemspec", <<~RUBY)
      Gem::Specification.new do |s|
        s.name    = "paired_gem"
        s.version = "0.1.0"
        s.summary = "fixture"
        s.authors = ["fixture"]
        s.metadata["rails_hyperdrive_skills_dir"] = "skills"
      end
    RUBY
    write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template)
  end

  it "hyperdrive:skills:render writes the canonical static face" do
    expect { invoke("hyperdrive:skills:render") }.to output(%r{render .*skills/paired/SKILL\.md}).to_stdout
    expect(File.read(File.join(@dir, "skills/paired/SKILL.md"))).to include("# Paired")
  end

  it "hyperdrive:skills:check passes when the static faces are fresh" do
    quiet_render
    expect { invoke("hyperdrive:skills:check") }.to output(/up to date/).to_stdout
  end

  it "hyperdrive:skills:check fails listing stale paths" do
    quiet_render
    write("lib/paired_gem/hyperdrive/skills/paired/SKILL.md.erb", template + "\nMore.\n")

    expect do
      expect { invoke("hyperdrive:skills:check") }.to raise_error(SystemExit)
    end.to output(%r{stale: .*skills/paired/SKILL\.md}).to_stderr
  end

  it "accepts an explicit gemspec path argument" do
    nested = File.join(@dir, "elsewhere")
    FileUtils.mkdir_p(nested)
    expect do
      Dir.chdir(nested) { Rake::Task["hyperdrive:skills:render"].invoke(File.join(@dir, "paired_gem.gemspec")) }
    end.to output(/render /).to_stdout
    expect(File.file?(File.join(@dir, "skills/paired/SKILL.md"))).to be true
  end
end
