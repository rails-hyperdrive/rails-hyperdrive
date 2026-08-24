# Rake tasks for companion gem repos: add `require "rails/hyperdrive/skill_tasks"`
# to the Rakefile. Every task takes an optional gemspec-path argument, e.g.
# rake "hyperdrive:skills:render[path/to/name.gemspec]".
require "rake"
require "rails/hyperdrive/canonical_skill_render"
require "rails/hyperdrive/manifest_lint"

namespace :hyperdrive do
  namespace :skills do
    desc "Render each SKILL.md.erb template to its canonical static SKILL.md"
    task :render, [:gemspec] do |_t, args|
      written = Rails::Hyperdrive::CanonicalSkillRender.write(gemspec: args[:gemspec])
      written.each { |r| puts "render #{r.dest}" }
      puts "no skill templates found" if written.empty?
    end

    desc "Fail when a canonical skill file is stale, or raw ERB sits under a public skills root"
    task :check, [:gemspec] do |_t, args|
      stale = Rails::Hyperdrive::CanonicalSkillRender.stale(gemspec: args[:gemspec])
      raw = Rails::Hyperdrive::CanonicalSkillRender.public_erb_templates(gemspec: args[:gemspec])
      stale.each { |r| warn "stale: #{r.dest}" }
      raw.each { |p| warn "raw ERB: #{p}" }
      abort "#{stale.size} canonical skill file(s) stale; run `rake hyperdrive:skills:render`" unless stale.empty?
      abort "#{raw.size} ERB template(s) under a public skills root; move them to the template directory" unless raw.empty?
      puts "canonical skill files up to date"
    end
  end

  namespace :manifest do
    desc "Fail on unknown keys, unparsable gating, or entries naming nothing shipped in hyperdrive.yml"
    task :check, [:gemspec] do |_t, args|
      result = Rails::Hyperdrive::ManifestLint.check(gemspec: args[:gemspec])
      result.problems.each { |p| warn "#{result.manifest}: #{p}" }
      abort "#{result.problems.size} problem(s) in #{result.manifest}" unless result.problems.empty?
      puts result.manifest ? "#{result.manifest} is clean" : "no hyperdrive.yml; nothing to lint"
    end
  end
end
