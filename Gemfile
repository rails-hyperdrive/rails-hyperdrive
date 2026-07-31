source "https://rubygems.org"

gemspec

# RAILS_VERSION pins the Rails series for matrix runs; unset resolves against the gemspec.
rails_version = ENV["RAILS_VERSION"]
if rails_version && !rails_version.empty?
  gem "rails", "~> #{rails_version}.0"
else
  gem "rails", ">= 7.2"
end
gem "sqlite3", "~> 2.0"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rspec-rails", "~> 7.0"
  gem "combustion", "~> 1.5"
  gem "rack-test", "~> 2.1"
  gem "simplecov", require: false
  gem "yard", "~> 0.9"
end
