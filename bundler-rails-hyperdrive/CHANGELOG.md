# Changelog

All notable changes to `bundler-rails-hyperdrive` are documented in this file.
The gem versions and releases independently of `rails-hyperdrive`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-08-24

### Fixed

- The `bundle install` hook now rescues `ScriptError` (`LoadError`, `SyntaxError`)
  alongside `StandardError`, in both `Bundler::Hyperdrive.auto_install` and the
  hook block itself. A failure to load rails-hyperdrive's code — possible for any
  release in the deliberately uncapped supported range — degrades to the usual
  one-line `[hyperdrive] auto-install skipped (…)` report instead of failing the
  user's `bundle install`.

## [0.1.0] - 2026-08-04

### Added

- Initial release: an `after-install-all` Bundler hook that installs missing
  hyperdrive artifacts during `bundle install`, with zero runtime dependencies.

[Unreleased]: https://github.com/rails-hyperdrive/rails-hyperdrive/compare/bundler-rails-hyperdrive/v0.1.1...HEAD
[0.1.1]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/bundler-rails-hyperdrive/v0.1.1
[0.1.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/bundler-rails-hyperdrive/v0.1.0
