require_relative "lib/bundler/hyperdrive/version"

Gem::Specification.new do |spec|
  spec.name        = "bundler-rails-hyperdrive"
  spec.version     = Bundler::Hyperdrive::VERSION
  spec.authors     = ["Bakaface"]
  spec.email       = ["afaceisnomore@gmail.com"]

  spec.summary     = "Bundler plugin that installs rails-hyperdrive companion artifacts on bundle install."
  spec.description = <<~DESC
    A Bundler plugin for applications using rails-hyperdrive. After every
    `bundle install` in development it installs the artifacts (skills and
    guidelines) that newly bundled companion gems ship — additively, never
    overwriting or deleting a file — and reports anything that needs
    `bin/rails hyperdrive:sync`. It never fails an install.
  DESC
  spec.homepage    = "https://github.com/rails-hyperdrive/rails-hyperdrive"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/bundler-rails-hyperdrive/CHANGELOG.md"
  spec.metadata["allowed_push_host"]     = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Anchored to this directory: a cwd-relative glob evaluated from the repo
  # root would package the root gem's lib/ and miss plugins.rb.
  spec.files = Dir.chdir(__dir__) do
    Dir[
      "plugins.rb",
      "lib/**/*",
      "LICENSE.txt",
      "CHANGELOG.md"
    ].reject { |f| File.directory?(f) }
  end

  spec.require_paths = ["lib"]

  # No dependency on rails-hyperdrive: Bundler resolves plugins outside the
  # application's Gemfile.lock, so declaring it here would install a second
  # copy into the plugin's gem home instead of using the application's. The
  # supported range is enforced at runtime against the app's bundle.
end
