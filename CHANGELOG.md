# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An artifact's `gem:` frontmatter field can now declare **several** targets, as
  either a comma-separated string (`gem: "sidekiq, solid_queue"`) or a YAML list.
  The artifact installs when **any** listed target is in the bundle at a
  satisfying version, so one guideline or skill can cover interchangeable
  libraries instead of shipping as near-identical per-target copies. `"*"`
  anywhere in the list makes the artifact universal.
- `versions:` accepts a **map keyed by gem name** alongside the existing single
  requirement, for target sets that do not share a version cycle:

  ```yaml
  gem: [sidekiq, solid_queue]
  versions:
    sidekiq: ">= 7.0"
    solid_queue: ">= 1.0"
  ```

  A single requirement still applies to every listed target. Targets absent from
  the map are unconstrained.

### Fixed

- `BundlerArtifactDiscovery#version_matches?` now correctly parses the documented
  comma-separated single-string form of `versions:` (e.g. `">= 7.0, < 9.0"`).
  Previously, `Gem::Requirement.new` rejected that form with `BadRequirementError`
  (subclass of `ArgumentError`), which was caught and silently treated as a
  version mismatch — installation would skip the artifact with a misleading
  "does not satisfy" warning. The YAML list form (`versions: [">= 7.0", "< 9.0"]`)
  was unaffected and continues to work.

### Changed

- **BREAKING:** the `gem:` value reported for each installed skill by the
  `describe_app` MCP tool and the `hyperdrive://stack-profile` resource is now an
  **array** of every target that matched, rather than a single string. A
  single-target artifact reports a one-element array. Consumers reading that
  field as a string need updating.
- **BREAKING:** renamed the `hyperdrive:init` / `hyperdrive:update` flag
  `--skip-skills` to `--skip-content`. The old name is removed outright, with no
  deprecated alias — it never described what the flag does. The flag skips *all*
  installed content, not just skills: skills, guidelines, `stack.md`, `index.md`,
  the `CLAUDE.md` import line, and `.hyperdrive/lock.yml`, leaving only
  `.mcp.json`, the discover-cache `.gitignore` rule, the optional initializer,
  and the engine mount. Writing no lockfile is intentional and unchanged: the
  lock is a manifest of installed content, and a later `hyperdrive:init` or
  `hyperdrive:update` reconstructs the full state from scratch. Update any
  scripts or CI invocations passing `--skip-skills`.

- Dropped the `< 8.1` upper cap on the `railties` and `activerecord` runtime
  dependencies — both are now floor-only (`>= 7.2`), so the gem installs against
  Rails 8.1 and later without waiting on a new release. The gem uses only stable
  public Rails APIs and degrades gracefully per-tool, so the cap was conservative
  rather than load-bearing. CI now exercises Rails 8.1 in place of 8.0.

## [0.2.0] - 2026-05-29

### Added

- `hyperdrive:discover` — read-only, networked command that suggests uninstalled
  `rails-hyperdrive-*` companion gems for the app's stack. Queries the rubygems
  search API, matches each companion's declared `hyperdrive_targets` against
  `Gemfile.lock`, and prints the `bundle add` lines to run. Results cache to
  `.hyperdrive/discover_cache.json` (24h TTL; `--refresh` busts it); offline or
  rate-limited runs fall back to a stale cache or report "unavailable" without
  failing. Ships dormant — returns nothing until companion gems exist on rubygems.
- `hyperdrive:init` now adds a `.gitignore` rule for the discover cache.

## [0.1.0] - 2026-05-29

### Added

- Initial release of `rails-hyperdrive`: a dev-only Rails engine that mounts an MCP
  server at `/_hyperdrive/mcp` exposing introspection tools for AI coding agents.
- `hyperdrive:init` generator that installs architecture skills and auto-discovers
  per-gem skills.

[Unreleased]: https://github.com/Bakaface/rails-hyperdrive/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Bakaface/rails-hyperdrive/releases/tag/v0.2.0
[0.1.0]: https://github.com/Bakaface/rails-hyperdrive/releases/tag/v0.1.0
