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

    desc "Fail when a canonical SKILL.md is stale relative to its template"
    task :check, [:gemspec] do |_t, args|
      stale = Rails::Hyperdrive::CanonicalSkillRender.stale(gemspec: args[:gemspec])
      if stale.empty?
        puts "canonical skill files up to date"
      else
        stale.each { |r| warn "stale: #{r.dest}" }
        abort "#{stale.size} canonical skill file(s) stale; run `rake hyperdrive:skills:render`"
      end
    end
  end
end
