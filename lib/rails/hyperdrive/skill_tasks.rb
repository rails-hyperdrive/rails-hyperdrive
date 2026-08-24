# Rake tasks for companion gem repos: add `require "rails/hyperdrive/skill_tasks"`
# to the Rakefile. Both tasks take an optional gemspec-path argument, e.g.
# rake "hyperdrive:skills:render[path/to/name.gemspec]".
require "rake"
require "rails/hyperdrive/canonical_skill_render"

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
end
