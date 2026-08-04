require_relative "lib/rails/hyperdrive/version"

Gem::Specification.new do |spec|
  spec.name        = "rails-hyperdrive"
  spec.version     = Rails::Hyperdrive::VERSION
  spec.authors     = ["Bakaface"]
  spec.email       = ["afaceisnomore@gmail.com"]

  spec.summary     = "Dev-only Rails engine that bootstraps an MCP server + skills/guidelines for AI coding agents."
  spec.description = <<~DESC
    Rails Hyperdrive mounts an MCP (Model Context Protocol) server at /_hyperdrive/mcp in development,
    exposing introspection tools for AI coding agents (eval Ruby, query DB, tail logs,
    list models/routes, locate source, fetch docs, snapshot stack). It also ships a
    `hyperdrive:init` generator that discovers and installs two artifact types — lazy skills
    and eager guidelines — shipped by companion gems under a documented contract.
    rails-hyperdrive is the mechanism; companion gems (rails-hyperdrive-<library>) are the content.
  DESC
  spec.homepage    = "https://github.com/rails-hyperdrive/rails-hyperdrive"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]        = spec.homepage
  spec.metadata["source_code_uri"]     = spec.homepage
  spec.metadata["changelog_uri"]       = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"]   = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*",
    "config/**/*",
    "MIT-LICENSE",
    "LICENSE.txt",
    "Rakefile",
    "README.md",
    "SECURITY.md",
    "CHANGELOG.md"
  ].reject { |f| File.directory?(f) }

  spec.bindir        = "exe"
  spec.executables   = []
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.2"
  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "mcp", "~> 0.25"
  spec.add_dependency "bundler", ">= 2.3"
end
