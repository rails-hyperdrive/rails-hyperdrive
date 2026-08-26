Gem::Specification.new do |spec|
  spec.name        = "rails-hyperdrive-alpha"
  spec.version     = "0.1.0"
  spec.authors     = ["Smoke Fixture"]
  spec.email       = ["smoke@example.com"]
  spec.summary     = "Smoke-test companion gem for rails-hyperdrive (alpha)."
  spec.description = "Fixture-only companion gem used by the rails-hyperdrive " \
                     "smoke suite to exercise end-to-end skill/guideline install."
  spec.homepage    = "https://example.com/rails-hyperdrive-alpha"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files       = Dir["lib/**/*", "skills/**/*", "agents/**/*", "commands/**/*", "hyperdrive.yml"]
  spec.require_paths = ["lib"]

  spec.metadata["hyperdrive_targets"]   = "railties"
  spec.metadata["hyperdrive_artifacts"] = "skill,guideline,agent,command"
end
