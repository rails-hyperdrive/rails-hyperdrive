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

- `hyperdrive:init` / `hyperdrive:update` now check the *combined* eager
  footprint against a budget, not just per-file size. When the guidelines
  listed in `index.md` plus `stack.md` exceed ~10,000 tokens, the footprint
  line is followed by a warning naming the two largest contributors, so it is
  clear what to trim or which line to drop from `index.md` to opt a guideline
  out. Individually reasonable guidelines could previously clear every per-file
  check and still add up to real context-window pressure with nothing flagging
  it. The install still proceeds — this is a warning, not a gate.

### Fixed

- The MCP endpoint no longer 403s local requests whose `Origin` port differs
  from the server's (e.g. `Origin: http://localhost` against
  `127.0.0.1:3000`). The `mcp` gem's `StreamableHTTPTransport` gained
  default-on DNS-rebinding protection requiring a same-origin `host:port`
  match; it is now disabled in favor of the engine's own Rack middleware,
  which allows any `localhost` / `127.0.0.1` / `[::1]` origin regardless of
  port. The `mcp` dependency floor moves to `~> 0.25` accordingly.

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

- **BREAKING:** the `gem:` value reported for each installed skill by the
  `describe_app` MCP tool and the `hyperdrive://stack-profile` resource is now an
  **array** of every target that matched, rather than a single string. A
  single-target artifact reports a one-element array. Consumers reading that
  field as a string need updating.

- Documented the companion gem contract rules the installer enforces but the
  README omitted or misstated: the `hyperdrive_skills_dir` gemspec metadata
  override (an additional skill root, not a replacement; `..` segments ignored),
  the permissive failure model and where its warnings surface, within-gem
  collapsing of same-`name:` artifacts, and both accepted forms of `versions:`.
  Corrected the description of `name:` — it determines the installed path rather
  than merely matching the file or directory stem.

- **BREAKING:** renamed the three companion-gem gemspec metadata keys
  `hyperdrive_targets`, `hyperdrive_artifacts`, and `hyperdrive_skills_dir` to
  `rails_hyperdrive_targets`, `rails_hyperdrive_artifacts`, and
  `rails_hyperdrive_skills_dir`. The old spellings are no longer read, with no
  deprecated alias. Gemspec metadata is a single flat namespace shared by every
  published gem, and the unprefixed `hyperdrive_*` prefix belongs to the
  pre-existing, unrelated `hyperdrive` gem on rubygems — the contract is now
  namespaced by the gem that defines it. Companion gems must update their
  gemspecs to the new keys.

- **BREAKING:** `hyperdrive:discover` now finds companions by the metadata they
  declare rather than by their name. It queries rubygems for gems declaring
  `rails_hyperdrive_targets` instead of searching for the `rails-hyperdrive-`
  name prefix, so a companion published under its author's own namespace is
  suggested on the same terms as a purpose-built one. The `rails-hyperdrive-`
  prefix remains a recommended naming convention and no longer plays any part in
  discovery. Target matching, version gating, caching, and the never-raise
  offline behaviour are unchanged, and artifact installation was never
  name-filtered, so nothing about `hyperdrive:init` / `hyperdrive:update`
  changes.

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
