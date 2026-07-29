# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`rails-hyperdrive` is a **dev-only Rails engine gem** that mounts an MCP (Model Context Protocol) server at `/_hyperdrive/mcp` exposing 8 introspection tools for AI coding agents, plus `hyperdrive:init` / `hyperdrive:update` generators that discover and install two artifact types — **skills** (lazy) and **guidelines** (eager) — shipped by companion gems under a documented contract, and a networked `hyperdrive:discover` that suggests uninstalled companion gems for the app's stack from rubygems.

**rails-hyperdrive is the mechanism; companion gems (`rails-hyperdrive-<library>`) are the content.** The gem ships no skills or guidelines of its own — only the contract, the discovery/install engine, and a single generated `stack.md`.

This is the gem itself, **not** an app that uses it. There is no host Rails app — specs boot a tiny in-memory app via Combustion at `spec/internal/`.

`README.md` describes the user-facing golden path.

## Commands

```bash
bin/setup                                          # bundle install
bundle exec rspec                                  # full suite (default rake task)
bundle exec rspec spec/hyperdrive/tools_spec.rb   # single file
bundle exec rspec -e "name fragment"               # filter by example name
bundle exec rspec --tag smoke                      # opt-in end-to-end smoke (slow; ~60s first run)
bin/console                                        # IRB with hyperdrive loaded
bin/bump patch|minor|major                         # bump the gem version (see Versioning)
bin/playground minimal|services|full_stack         # copy a smoke fixture app to gitignored playground/<variant>/,
                                                   # bundle it against this checkout, run hyperdrive:init — for
                                                   # manual poking (--force overwrites, --no-init skips init)

# CI matrix is Ruby {3.2, 3.3, 3.4} × Rails {7.2, 8.1}.
# Reproduce a specific slot locally:
RAILS_VERSION=7.2 bundle install && RAILS_VERSION=7.2 bundle exec rspec
```

Coverage is written to `coverage/` by SimpleCov (configured in `spec/spec_helper.rb`).

## Versioning

The gem follows [Semantic Versioning](https://semver.org). `lib/rails/hyperdrive/version.rb` is the **single source of truth** — `rails-hyperdrive.gemspec` reads `Rails::Hyperdrive::VERSION` from it, as does the `describe_app` MCP tool (`mcp_server.rb`). Never hand-edit the version anywhere else.

Bump with `bin/bump <patch|minor|major|X.Y.Z>` (or `mise run bump <level>`). The script:

1. Rewrites the `VERSION` constant in `version.rb`.
2. Rolls the `## [Unreleased]` section of `CHANGELOG.md` into a dated `## [X.Y.Z]` section and refreshes the link-reference footer.
3. Prints the suggested `git commit` + `git tag` commands. Pass `--commit` to make the `chore(release): vX.Y.Z` commit, and `--tag` to also create the annotated `vX.Y.Z` tag. Use `--dry-run` to preview without writing.

Record user-facing changes under `## [Unreleased]` in `CHANGELOG.md` as you go, so a release bump just dates and tags them.

Publishing to RubyGems is tag-triggered (`bin/bump <level> --commit --tag` then push the tag). Do **not** combine `bin/bump --tag` with `rake release` — both create the `vX.Y.Z` tag. Full release runbook is in [`RELEASING.md`](RELEASING.md).

## Architecture

### Composition root

`lib/rails/hyperdrive/mcp_server.rb` is where everything wires together. It builds a single `MCP::Server` with the 8 tools and 2 resource families, then wraps the `StreamableHTTPTransport` in `Safety::RackMiddleware` and exposes it as a Rack app. The engine's `config/routes.rb` mounts that rack app at `/mcp`. `McpServer.reset!` exists for test isolation — singletons are intentional.

### Safety model (defense in depth)

Three layers, all keyed off `Rails::Hyperdrive.dev_mode?` (the single source of truth in `lib/rails/hyperdrive.rb`):

1. **Engine load-time warning** (`engine.rb`) — loads in any env so production boots don't blow up, just logs a warning.
2. **Rack middleware** (`safety/rack_middleware.rb`) — 403s every request outside `Rails.env.development?` or with an Origin outside the allowlist (`localhost`, `127.0.0.1`, `[::1]`).
3. **Per-tool `with_dev_guard`** (`tools/base.rb`) — catches direct invocations (tests, rake tasks) that bypass the transport.

When adding new tools, always inherit from `Tools::Base` and wrap the body in `with_dev_guard { ... }`. The block also rescues and shapes exceptions into `respond_error`.

SQL safety (`sql_safety.rb`) is a regex pair: an allowed-leader pattern (`SELECT`/`WITH...SELECT`/`EXPLAIN`/`SHOW`/`PRAGMA`) plus a forbidden-token denylist (to catch a `DELETE` smuggled inside a CTE). It is a **guardrail against accidental AI damage, not a sandbox** — the user has root on their dev DB.

### Shared state between generator and runtime

`StackProfile` (`lib/rails/hyperdrive/stack_profile.rb`) parses `Gemfile.lock` into a categorized stack snapshot. **Both** the `hyperdrive:init` generator (to render `stack.md` + `.mcp.json`) **and** the `describe_app` MCP tool / `hyperdrive://stack-profile` resource consume it. This is deliberate — installer and running server must not drift on what "this app's stack" means. Gem→category mapping lives in `lib/rails/hyperdrive/data/gem_categories.yml`. Its `gem_skills_info` defers to `BundlerArtifactDiscovery` (below) and lists each installed skill as a `(name, source)` pair.

### Companion-gem artifact discovery contract

`BundlerArtifactDiscovery` (`lib/rails/hyperdrive/bundler_artifact_discovery.rb`) walks `Bundler.load.specs` for **two artifact types**:

- **Skills** — `<gem-source>/lib/<gem_name>/hyperdrive/skills/**/SKILL.md` (dir-per-skill). Also honors a `hyperdrive_skills_dir` gemspec-metadata override (union of convention path + override; `..` segments rejected).
- **Guidelines** — `<gem-source>/lib/<gem_name>/hyperdrive/guidelines/<name>.md` (flat file, convention path only).

Both carry YAML frontmatter with four required fields: `name`, `description`, `gem`, `versions`. **Target vs. source:** `gem:` is the *target* (must be present in the bundle; its resolved version is matched against `versions:`, a `Gem::Requirement` string). `spec.name` during the walk is the *source* (provenance / audit header / conflict postfix). `gem: "*"` is universal (no target resolved, `versions:` ignored — must be quoted, bare `*` is a YAML alias and is skipped); `gem: railties` is a normal target, version-gated against the resolved Rails. The parser is **permissive**: unknown keys ignored; a missing field / malformed YAML / version mismatch / absent target → skip with a warning (collected, printed to stdout), never raised.

Dedup is **two-phase**. *Phase 1* (discovery) collapses same-name variants **within one source gem** to the highest `spec_version` (path as tiebreak); composite identity is `(name, source_gem, artifact_type)`. *Phase 2* (install, in the generator) groups Phase-1 survivors across sources: one source → canonical path; multiple sources → install **all**, each postfixed `--<source_gem>` on the path (and, for skills, on the display `name:`).

`AuditHeader` (`lib/rails/hyperdrive/audit_header.rb`) records `source=<gem>@<version>`, `sha256=...`, `installed_at=...` in two syntaxes: **YAML comments inside the frontmatter** for skills (frontmatter kept, so the skill parser still sees a valid schema), and a **prepended HTML-comment block** for guidelines + `stack.md` (frontmatter stripped on install). `sha256` is computed over the install-ready body *before* injection, so `strip(installed_file)` round-trips exactly — the basis for drift detection.

### Generated stack.md

`StackDocument` (`lib/rails/hyperdrive/stack_document.rb`) renders `stack.md` — the only content a zero-companion install produces. Body-only markdown (facts: Rails/Ruby/DB → per-bucket steering → trailing `## MCP tools`); the installer adds the HTML audit header with `source: internal@<version>`. Display labels + per-gem steering clauses live in the sibling `lib/rails/hyperdrive/data/stack_steering.yml` (steering is emitted only when a gem is the sole member of its bucket). `gem_categories.yml` stays untouched.

### Lockfile + idempotency/drift

`LockFile` (`lib/rails/hyperdrive/lock_file.rb`) reads/writes the git-tracked `.hyperdrive/lock.yml` manifest: per-file `source`, canonical `source_sha` (hash of the install-ready body), `installed_at` (volatile, never compared), plus `claude_md.state`. The generator's drift state machine: file current (`disk_sha == lock == gem`) → leave untouched; gem upgraded, file unedited → rewrite; user-edited → **skip + warn on `init`**, **force-overwrite on `update`**; missing → reinstall; orphan (source gem gone, file remains) → warn + leave. Two opt-out state machines, both persistent and "never re-add": the single `@.claude/hyperdrive/index.md` line in `CLAUDE.md` (`present | removed-by-user`), and per-guideline opt-out by deleting its `@`-line from `index.md`.

### Generator

`lib/generators/hyperdrive/install/install_generator.rb` backs `bin/rails hyperdrive:init` and `hyperdrive:update` (wired by `lib/tasks/hyperdrive.rake`). Public flags: `--mount-at`, `--skip-content` (skips the *whole* `sync_content` step — skills, guidelines, `stack.md`, `index.md`, the `CLAUDE.md` import, and the lockfile; leaves only `.mcp.json`, the gitignore rule, the initializer, and the mount), `--dry-run` (translated to Thor's `pretend`), `--force-install`, `--update`. It is non-interactive — `update_mode?` is `--update || --force-install`. The pipeline: verify env → parse `StackProfile` → discover artifacts → write `.mcp.json` → ignore the discover cache in `.gitignore` → (optionally) write initializer → mount engine → `sync_content` (Phase-2 plan, install skills/guidelines/`stack.md` with audit headers via the drift state machine, maintain `index.md`, inject the one `CLAUDE.md` line, write the lock, print warnings + eager footprint) → summary. Skills install to `.claude/skills/<name>/SKILL.md` (frontmatter kept); guidelines to `.claude/hyperdrive/guidelines/<name>.md` (frontmatter stripped, `@`-included via `index.md`).

### Companion discovery
`CompanionDiscovery` (`lib/rails/hyperdrive/companion_discovery.rb`) backs `bin/rails hyperdrive:discover` (generator at `lib/generators/hyperdrive/discover/discover_generator.rb`, `--refresh` flag). This is the **only networked command** — read-only, never auto-run by `init`/`update`, never modifies the Gemfile. It queries the rubygems search API for `rails-hyperdrive-*` gems (client-side prefix filter — search is substring; paginated 30/page until a short page), reads their `hyperdrive_targets` / `hyperdrive_artifacts` gemspec metadata **straight from the API response** (no `.gem` download), matches the declared targets against `Gemfile.lock` (`*` = universal), and prints `bundle add` suggestions. This pre-install `hyperdrive_targets` hint is a **separate surface** from the per-artifact frontmatter `gem:` the installer uses authoritatively — it is never reconciled. Results cache to `.hyperdrive/discover_cache.json` (the one gitignored artifact; 24h TTL, `--refresh` busts). Offline / HTTP error / 429 → fall back to a stale cache (flagged) or report "unavailable" and exit cleanly; never raises. The HTTP fetcher is injectable (`fetcher:`) for tests. **Ships dormant** — empty until companions exist on rubygems.

## Test infrastructure

- **Combustion** (`spec/spec_helper.rb`) boots a real Rails app from `spec/internal/`. Schema is `spec/internal/db/schema.rb` (Users + Posts on SQLite).
- `ENV["RAILS_ENV"]` is forced to `"development"` in the spec helper because the engine middleware refuses anything else.
- `before(:each)` resets `StackProfile` and `McpServer` singletons — preserve this when adding new singletons.
- Generator specs write into `spec/tmp/install_generator/` (gitignored) and **stub `BundlerArtifactDiscovery.discover`** to inject `Artifact` structs (default: empty → zero-content install). Real artifact discovery is exercised against `spec/fixtures/dummy_gem/` and `spec/fixtures/companion_gem/` (the latter targets `dummy_gem` from a different source, covering the target/source split + cross-source collision).
- **Smoke specs** (`spec/smoke/`, tagged `:smoke`, excluded by default in `.rspec`) shell out to a real `bin/rails hyperdrive:init` subprocess against fixture apps under `spec/fixtures/smoke_apps/{minimal,services,full_stack}/` and POST JSON-RPC to a booted server. The base apps ship no companion gems, so `install_generator_spec` exercises a zero-content install (stack.md + index.md + lock.yml + the one CLAUDE.md import line). `companion_install_spec` goes further: it bundles the fixture-only path gems under `spec/fixtures/smoke_companions/{rails-hyperdrive-alpha,rails-hyperdrive-beta}/` (real gemspecs shipping skills + guidelines) to drive the full install pipeline end-to-end — companion skill/guideline install with both audit-header forms, `index.md` aggregation + footprint, `hyperdrive:update` force-overwrite of a locally-modified file, and cross-source skill collision (both variants installed, postfixed `--<source_gem>`). `discover_generator_spec` smokes the networked `hyperdrive:discover` end-to-end against the live rubygems API: a healthy run must print a recognized outcome (silently-broken exits fail); offline/rate-limited runs are flagged and only the outcome assertion is skipped, keeping the suite deterministic. Shared bundle cache lives at `spec/tmp/smoke-bundle/`. Run with `bundle exec rspec --tag smoke`. CI smoke job triggers on every push to `main`, on `workflow_dispatch`, or on PRs with the `run-smoke` label, and runs two corner slots only (Ruby 3.2/Rails 7.2 and Ruby 3.4/Rails 8.1).
- **Known coverage limits** (verified manually, not by the suite): two paths can't be exercised today. (1) **`hyperdrive:discover` with a live, non-empty result** — no `rails-hyperdrive-*` companion gems are published to rubygems yet, so the networked discover smoke only ever sees an empty result set; the with-results and 24h-cache-reuse paths are covered at unit level via `CompanionDiscovery`'s injectable `fetcher:`. (2) **Claude Code runtime consumption** — `.mcp.json` autoload, `@`-import resolution of `index.md`, and lazy skill loading all happen inside Claude Code itself, outside any process this suite can drive.

## Gemfile & dependency notes

- `Gemfile.lock` is **gitignored** — Bundler resolves fresh each install. CI keys its cache off `RAILS_VERSION` to avoid cross-slot bleed.
- Runtime deps: `railties`, `activerecord` (both `>= 7.2`, no upper cap), `mcp ~> 0.17`, `bundler >= 2.3`.
- License must stay MIT throughout, including transitive runtime deps — no Apache-licensed runtime additions.
