Gem::Specification.new do |spec|
  spec.name        = "rails-hyperdrive-beta"
  spec.version     = "0.2.0"
  spec.authors     = ["Smoke Fixture"]
  spec.email       = ["smoke@example.com"]
  spec.summary     = "Smoke-test companion gem for rails-hyperdrive (beta)."
  spec.description = "Fixture-only companion gem used by the rails-hyperdrive " \
                     "smoke suite to exercise cross-source skill collision."
  spec.homepage    = "https://example.com/rails-hyperdrive-beta"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files       = Dir["lib/**/*", "hyperdrive.yml"]
  spec.require_paths = ["lib"]

  spec.metadata["rails_hyperdrive_targets"]   = "railties"
  spec.metadata["rails_hyperdrive_artifacts"] = "skill,guideline"
end
