# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `BundlerArtifactDiscovery#version_matches?` now correctly parses the documented
  comma-separated single-string form of `versions:` (e.g. `">= 7.0, < 9.0"`).
  Previously, `Gem::Requirement.new` rejected that form with `BadRequirementError`
  (subclass of `ArgumentError`), which was caught and silently treated as a
  version mismatch — installation would skip the artifact with a misleading
  "does not satisfy" warning. The YAML list form (`versions: [">= 7.0", "< 9.0"]`)
  was unaffected and continues to work.

- `hyperdrive:init` / `hyperdrive:update` now merge the `rails-hyperdrive` entry
  into an existing `.mcp.json` instead of rendering a template over the whole
  file. Any other MCP servers you have configured, and any sibling top-level
  keys, are preserved; only `mcpServers["rails-hyperdrive"]` is managed. The
  write is also silent — previously a project with a pre-existing `.mcp.json`
  hit Thor's interactive `Overwrite? [Ynaqdhm]` prompt, which stalls CI and
  agent runs and then discarded the other servers anyway. A re-run that changes
  nothing writes nothing, and a `.mcp.json` that cannot be parsed is left
  byte-for-byte intact with a warning rather than overwritten.

### Changed

- Documented the companion gem contract rules the installer enforces but the
  README omitted or misstated: the `hyperdrive_skills_dir` gemspec metadata
  override (an additional skill root, not a replacement; `..` segments ignored),
  the permissive failure model and where its warnings surface, within-gem
  collapsing of same-`name:` artifacts, and both accepted forms of `versions:`.
  Corrected the description of `name:` — it determines the installed path rather
  than merely matching the file or directory stem.

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
