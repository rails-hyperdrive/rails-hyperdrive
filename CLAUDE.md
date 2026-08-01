# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`rails-hyperdrive` is a **dev-only Rails engine gem** that mounts an MCP (Model Context Protocol) server at `/_hyperdrive/mcp` exposing 8 introspection tools for AI coding agents, plus `hyperdrive:init` / `hyperdrive:sync` generators that discover and install two artifact types — **skills** (lazy) and **guidelines** (eager) — shipped by companion gems under a documented contract, and a networked `hyperdrive:discover` that suggests uninstalled companion gems for the app's stack from rubygems.

**rails-hyperdrive is the mechanism; companion gems (`rails-hyperdrive-<library>`) are the content.** The gem ships no skills or guidelines of its own — only the contract and the discovery/install engine.

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

`bin/bump` and the release tooling cover **only the root gem**. The `bundler-hyperdrive` plugin gem (below) versions independently via `bundler-hyperdrive/lib/bundler/hyperdrive/version.rb` and has no bump script, tags, or publish workflow yet.

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

`StackProfile` (`lib/rails/hyperdrive/stack_profile.rb`) parses `Gemfile.lock` into a categorized stack snapshot. Its only consumers are the **pull surfaces** — the `describe_app` MCP tool and the `hyperdrive://stack-profile` resource — which answer "what is this app's stack" live, against the resolved bundle. The install side does not read it. Gem→category mapping lives in `lib/rails/hyperdrive/data/gem_categories.yml`. Its `gem_skills_info` defers to `BundlerArtifactDiscovery` (below) and lists each installed skill as a `(name, source)` pair.

### Companion-gem artifact discovery contract

`BundlerArtifactDiscovery` (`lib/rails/hyperdrive/bundler_artifact_discovery.rb`) walks `Bundler.load.specs` for **two artifact types**:

- **Skills** — `<gem-source>/lib/<gem_name>/hyperdrive/skills/**/SKILL.md` (dir-per-skill; `SKILL.md.erb` defines a skill the same way, rendered before frontmatter parsing — see gem-conditional content below). Also honors a `rails_hyperdrive_skills_dir` gemspec-metadata override (union of convention path + override; `..` segments rejected). A skill dir may ship **supporting files** — everything besides `SKILL.md`/`SKILL.md.erb`, at any depth. Discovery captures them on the `Artifact` as `support_files` (dir-relative path + raw bytes via `binread`; files named `SKILL.md`/`SKILL.md.erb` excluded at every depth, `..`-containing relative paths rejected, always empty for guidelines, excluded from `to_h` like `body`). They carry no frontmatter contract — `SKILL.md` frontmatter is the sole schema surface — and install byte-identical to the **install-ready body** (the shipped bytes; for `*.md.erb`, the rendered output; **no audit header**; non-markdown/binary content must not be prepended to) under `.claude/skills/<final_name>/<relpath>`, preserving layout. Collision postfixing renames the whole directory and rewrites only SKILL.md's `name:`, so dir-relative links inside a skill keep working with no body rewriting.
- **Guidelines** — `<gem-source>/lib/<gem_name>/hyperdrive/guidelines/<name>.md` (flat file, convention path only, no ERB support).

**Gem-conditional skill content** — both mechanisms run at **discovery time** inside `BundlerArtifactDiscovery` (the sole holder of the resolved bundle map), so an `Artifact` leaves discovery fully conditioned and downstream (`InstallPlan`, pipeline, status, auto-install) is untouched:

- *Per-file gating*: a `conditional:` map in SKILL.md frontmatter — keys are dir-relative **shipped** supporting-file paths, values take the artifact-level `gem:`/`versions:` forms (any-match; `"*"` universal), except `versions:` is **optional** (omitted = unconstrained). Unlisted files install unconditionally. Malformed entries (non-map value, missing/unparsable `gem:`, unparsable `versions:`) **fail open**: warn + install the file. A key naming no shipped file or naming `SKILL.md`(.erb) warns and is ignored. The key ships through into installed frontmatter unchanged.
- *ERB templates* (`SkillTemplate`, `lib/rails/hyperdrive/skill_template.rb`): `*.md.erb` supporting files render with a sealed binding of exactly `gem?(name, requirement = nil)`, `any_gem?(*names)`, `gem_version(name)` (String or nil) over the resolved bundle, `trim_mode: "-"`, and retarget to `x.md` in `support_files`. Gated-out templates are never rendered. Render failure → warn + skip that file; a failing `SKILL.md.erb` skips the whole skill. Tie rules: `SKILL.md` beats `SKILL.md.erb` in one dir, and a plain `x.md` beats an `x.md.erb` rendering to the same path — always with a warning, never a silent tiebreak.
- Lock `source_sha` is over the rendered bytes, so the drift machine applies unchanged; a bundle change that alters render output or gates a file out is picked up by `init`/`sync` (gated-out unedited files ride the existing stale-support delete). `AutoInstall` (`:additive`) only tops up newly gated-in files — removals and re-rendered content wait for the next `sync`.

Both carry YAML frontmatter with four required fields: `name`, `description`, `gem`, `versions`. **Target vs. source:** `gem:` names the *targets* (each must be present in the bundle; its resolved version is matched against `versions:`, a `Gem::Requirement` string). `spec.name` during the walk is the *source* (provenance / audit header / conflict postfix). `gem: "*"` is universal (no target resolved, `versions:` ignored — must be quoted, bare `*` is a YAML alias and is skipped); `gem: railties` is a normal target, version-gated against the resolved Rails. The parser is **permissive**: unknown keys ignored; a missing field / malformed YAML / version mismatch / absent target → skip with a warning (collected, printed to stdout), never raised.

**Multi-target `gem:`.** `gem:` accepts a comma-separated string or a YAML list, so one artifact can cover several interchangeable libraries. Match is **any**: the artifact installs when at least one listed target is bundled at a satisfying version, and `target_gem` is an **array** of every target that matched (a single-target artifact reports a one-element array). `"*"` anywhere in the list short-circuits to universal. `versions:` is either one requirement covering every listed target, or a **map keyed by gem name** constraining each independently — targets the map omits are unconstrained. The target participates in neither dedup phase, so a set-valued target adds no installs. Per-artifact targets are expected to stay a subset of the gem's `hyperdrive_targets`; this is convention, not enforced anywhere.

Dedup is **two-phase**. *Phase 1* (discovery) collapses same-name variants **within one source gem** to the highest `spec_version` (path as tiebreak); composite identity is `(name, source_gem, artifact_type)`. *Phase 2* (install, in `InstallPlan`) groups Phase-1 survivors across sources: one source → canonical path; multiple sources → install **all**, each postfixed `--<source_gem>` on the path (and, for skills, on the display `name:`).

`AuditHeader` (`lib/rails/hyperdrive/audit_header.rb`) records `source=<gem>@<version>`, `sha256=...`, `installed_at=...` in two syntaxes: **YAML comments inside the frontmatter** for skills (frontmatter kept, so the skill parser still sees a valid schema), and a **prepended HTML-comment block** for guidelines (frontmatter stripped on install). `sha256` is computed over the install-ready body *before* injection, so `strip(installed_file)` round-trips exactly — the basis for drift detection.

### Lockfile + idempotency/drift

`LockFile` (`lib/rails/hyperdrive/lock_file.rb`) reads/writes the git-tracked `.hyperdrive/lock.yml` manifest: per-file `source`, canonical `source_sha` (hash of the install-ready body), `installed_at` (volatile, never compared), plus `claude_md.state` (omitted entirely while no import line is being managed; tear-down transitions `present` → omitted, while `removed-by-user` is sticky) and the hand-editable `disabled:` list. Top-level keys the schema does not recognize survive a read/write round-trip (entries under `files:` are regenerated), so `LockFile#carry_settings` is what lets a freshly-built lock replace one read from disk. The drift state machine (in `InstallPipeline`): file current (`disk_sha == lock == gem`) → leave untouched; gem upgraded, file unedited → rewrite; user-edited → **skip + warn in preserve mode** (`init`, `sync`), **force-overwrite in overwrite mode** (`sync --overwrite`); missing → reinstall; orphan (source gem gone, file remains) → warn + leave. Three opt-out state machines, all persistent and "never re-add": the single `@.claude/hyperdrive/index.md` line in `CLAUDE.md` (`present | removed-by-user`), per-guideline opt-out by deleting its `@`-line from `index.md`, and the `disabled:` list naming skills/guidelines the user never wants installed. `InstallPlan.build` filters the plan against that list; a listed artifact already on disk is deleted **only** when its stripped body still hashes to the recorded `source_sha` — otherwise it is reported and left, keeping the installer's never-delete-user-work property. Disabling a skill removes its lock-recorded supporting files under the same gate; skill directories (and emptied subdirectories) go only once empty, so user-created files not in the lock always survive and keep the directory alive. `:additive` never removes.

Supporting files are ordinary lock entries under the `artifact:` kind **`skill_support`** (no schema change, per-file `source_sha` over raw bytes — never a tree hash), so the whole drift state machine applies per file; their disk comparison reads raw bytes without `AuditHeader.strip`, which can raise on binary content. One extra delete path exists for them (same sha gate): when the bundle **stops shipping a supporting file while its owning skill is still planned**, an unedited copy is removed and emptied subdirectories pruned; an edited copy is warned about and its lock entry carried. Skipped in `:additive`; a skill whose whole source gem left the bundle stays on the ordinary orphan path (warn + leave, supporting files included). `ArtifactStatus` offers supporting-file dests too, so `AutoInstall` tops up a supporting file the lock does not record. The sync/init summary collapses `skill_support` entries into a `(+N files)` suffix on the owning skill's line; `installed_counts` counts skills, not files.

### Install pipeline

`InstallPipeline` (`lib/rails/hyperdrive/install_pipeline.rb`) owns all content installation: Phase-2 plan → skills/guidelines with audit headers through the drift state machine → `index.md` → the one `CLAUDE.md` import line → the lock → warnings + eager footprint → a warning if git ignores an install destination (`.claude/skills`, `.claude/hyperdrive`, `.hyperdrive/lock.yml`). That last check shells out to `git check-ignore` — `.gitignore` line-matching cannot see patterns, negations, or per-repo excludes — and treats any non-zero exit (no match, no repo, no git) as "nothing ignored". It takes an **explicit app root** and never reads `Rails.root`, so it runs in any process that can see the app's bundle. Three modes: `:preserve` (skip locally-modified files), `:overwrite` (force-overwrite them), `:additive` (write only what the lock doesn't record *and* what isn't already on disk — it can create files but never overwrite one, and it leaves `CLAUDE.md` alone entirely; `index.md` is amended in place rather than recomputed, so user opt-outs and orphan lines survive).

The **eager chain** — `index.md` plus the single `CLAUDE.md` import line — is companion-driven: it is written only when the plan holds at least one guideline, and torn down when it holds none. Tear-down deletes `index.md` and, for `CLAUDE.md`, deletes the file only when it is byte-identical to the one the installer wrote; otherwise it strips just the import line and leaves every other byte. A `removed-by-user` state survives tear-down, so a line the user deleted is still never re-added. An `index.md` that renders empty because the user deleted every `@`-line is kept, not torn down — it is the opt-out ledger, and deleting it would re-add everything on the next run. `:additive` never tears down.

It writes through a **shell** collaborator (`create_file` / `append_to_file` / `say_status` / `say`): the generator passes a `ThorShell` adapter so Thor's output and `--dry-run` keep working, everything else passes `InstallShell` (`install_shell.rb` — plain `FileUtils`, silent unless given an `io:`). `InstallPlan` (`install_plan.rb`) is Phase 2 extracted: it computes each artifact's final name, dest path, and install-ready body (including the postfixed skill's renamed `name:`), so the installer and the lockfile comparison hash exactly the same bytes.

`ArtifactStatus` (`artifact_status.rb`) compares what the bundle offers against `.hyperdrive/lock.yml` — `installed | missing | outdated | orphaned`. It is a **manifest** comparison, deliberately not a disk audit; disk state is the drift machine's job.

`AutoInstall` (`auto_install.rb`) is the entry point for callers with no Rails booted: it runs the comparison, installs only the missing artifacts (`:additive`), and returns everything it left alone for the caller to print. Because `:additive` never touches `CLAUDE.md`, a guideline landing in an app whose eager chain was never armed is inert until a `sync`; `Result#unwired` reports that (new guideline installed, lock `claude_md.state` still absent) so the caller can say so. Guards, in order: environment must read as development from `ENV` directly (`RAILS_ENV`/`RACK_ENV`), no `CI`, not a frozen bundle; and the app must already have a lock (it tops up an initialized app, it never bootstraps one). It never raises — a caller wrapped around `bundle install` must not turn a hyperdrive problem into a failed install.

### Generator

`lib/generators/hyperdrive/install/install_generator.rb` backs `bin/rails hyperdrive:init`; `lib/generators/hyperdrive/sync/sync_generator.rb` backs `bin/rails hyperdrive:sync` (both wired by `lib/tasks/hyperdrive.rake`, both non-interactive; shared plumbing lives in `lib/generators/hyperdrive/content_sync_support.rb`, the run sequence both generators' steps delegate to in `sync_runner.rb`, and the lock-derived summary formatting in `install_summary.rb`). Init's public flags: `--mount-at`, `--skip-content` (skips the *whole* `sync_content` step — skills, guidelines, `index.md`, the `CLAUDE.md` import, and the lockfile; leaves only `.mcp.json`, the gitignore rule, the initializer, and the mount), `--dry-run` (translated to Thor's `pretend`). Init's pipeline: verify env → discover artifacts → merge `.mcp.json` → ignore the discover cache in `.gitignore` → (optionally) write initializer → mount engine → `sync_content` (hands off to `InstallPipeline` in `:preserve` mode) → summary. Sync's flags: `--overwrite` (run the pipeline in `:overwrite` mode instead of `:preserve`), `--dry-run`; it runs the same content pipeline (verify env → discover → `sync_content` → summary) and prints the same lock-derived summary, but writes no bootstrap artifact. The summary lists every entry of the lock the pipeline leaves behind (`InstallPipeline#lock`), grouped by `source` with rails-hyperdrive's own `internal@` group last, so it reports the app's resulting state rather than the run's writes. Skills install to `.claude/skills/<name>/SKILL.md` (frontmatter kept); guidelines to `.claude/hyperdrive/guidelines/<name>.md` (frontmatter stripped, `@`-included via `index.md`).

`.mcp.json` is the one artifact outside the lockfile drift machine. `write_mcp_json` reads any existing file, sets `mcpServers["rails-hyperdrive"]` (leaving every other server and sibling top-level key alone), and re-serializes with `JSON.pretty_generate`. Formatting survives by value, not byte-for-byte. The write is `create_file … force: true` so no run can stop on Thor's conflict prompt; idempotency comes from comparing the merged output against disk and skipping the write when equal. A `.mcp.json` that isn't a JSON object — or whose `mcpServers` isn't one — is warned about and left untouched, since its contents are unrecoverable once overwritten.

### Companion discovery
`CompanionDiscovery` (`lib/rails/hyperdrive/companion_discovery.rb`) backs `bin/rails hyperdrive:discover` (generator at `lib/generators/hyperdrive/discover/discover_generator.rb`, `--refresh` flag). This is the **only networked command** — read-only, never auto-run by `init`/`sync`, never modifies the Gemfile. It queries the rubygems search API with the field-scoped metadata query `metadata.rails_hyperdrive_targets:*` (paginated 30/page until a short page), reads that key plus `rails_hyperdrive_artifacts` **straight from the API response** (no `.gem` download), matches the declared targets against `Gemfile.lock` (`*` = universal), and prints `bundle add` suggestions. Companions are found by what they **declare**, not by name — the `rails-hyperdrive-` prefix is a recommended naming convention with no role in discovery. The metadata query is an **undocumented** passthrough to the rubygems search backend, so it is treated as best-effort: if it stops matching it returns an empty 200 page, which degrades to "no suggestions" rather than an error, and the live smoke canary is what turns that into a failing test. This pre-install `rails_hyperdrive_targets` hint is a **separate surface** from the per-artifact frontmatter `gem:` the installer uses authoritatively — it is never reconciled. Results cache to `.hyperdrive/discover_cache.json` (the one gitignored artifact; 24h TTL, `--refresh` busts). Offline / HTTP error / 429 → fall back to a stale cache (flagged) or report "unavailable" and exit cleanly; never raises. The HTTP fetcher is injectable (`fetcher:`) for tests. **Ships dormant** — empty until companions exist on rubygems.

### Bundler plugin gem (`bundler-hyperdrive/`)

A **second gem** lives in the `bundler-hyperdrive/` subdirectory, with its own gemspec and the `plugins.rb` Bundler requires when registering a plugin. The root gemspec remains the only gemspec at repo root, and its globs exclude the subdirectory from the rails-hyperdrive package. The plugin gem has **zero runtime dependencies** — deliberately not even rails-hyperdrive, because Bundler resolves plugins outside the app's `Gemfile.lock`; a gemspec dep would install a second rails-hyperdrive into the plugin's gem home instead of using the app's.

`plugins.rb` registers an `after-install-all` hook (once per `bundle install`, against the settled bundle — no per-gem hook). The hook (`Bundler::Hyperdrive.auto_install` in `bundler-hyperdrive/lib/bundler/hyperdrive.rb`): silent env guard (`RAILS_ENV`/`RACK_ENV` must read development, no non-empty `CI`) → resolve rails-hyperdrive from `Bundler.load.specs` → runtime range check (`>= 0.2`, deliberately uncapped) → put the resolved gem's `lib` on `$LOAD_PATH` and call `AutoInstall.run(root: Bundler.root.to_s)` — the entry point is the plugin's entire coupling to rails-hyperdrive — → print `result.messages` with a `[hyperdrive] ` prefix on non-indented lines. **Quiet failure is a hard contract**: the whole body is rescue-wrapped, every failure degrades to one printed line, and the hook must never fail a `bundle install`.

The plugin enters an app via the Gemfile directive `plugin "bundler-hyperdrive"`, written by `hyperdrive:init`'s `register_bundler_plugin` step (idempotent: any existing directive line — with `path:`, versions, whatever — counts as present; no Gemfile → skip status). Only `init` writes it, never `sync`. Known limits (checked against Bundler 2.6.9): `bundle lock` runs no hooks; `BUNDLE_PLUGINS=false` disables the plugin system entirely; the plugin's own version is not pinned by the app's `Gemfile.lock`.

## Test infrastructure

- **Combustion** (`spec/spec_helper.rb`) boots a real Rails app from `spec/internal/`. Schema is `spec/internal/db/schema.rb` (Users + Posts on SQLite).
- `ENV["RAILS_ENV"]` is forced to `"development"` in the spec helper because the engine middleware refuses anything else.
- `before(:each)` resets `StackProfile` and `McpServer` singletons — preserve this when adding new singletons.
- Generator specs write into `spec/tmp/install_generator/` (gitignored) and **stub `BundlerArtifactDiscovery.discover`** to inject `Artifact` structs (default: empty → zero-content install). Real artifact discovery is exercised against `spec/fixtures/dummy_gem/` and `spec/fixtures/companion_gem/` (the latter targets `dummy_gem` from a different source, covering the target/source split + cross-source collision).
- **Smoke specs** (`spec/smoke/`, tagged `:smoke`, excluded by default in `.rspec`) shell out to a real `bin/rails hyperdrive:init` subprocess against fixture apps under `spec/fixtures/smoke_apps/{minimal,services,full_stack}/` and POST JSON-RPC to a booted server. The base apps ship no companion gems, so `install_generator_spec` exercises a **zero-companion install** — `.mcp.json`, the gitignore rule, the initializer, the mount, and `.hyperdrive/lock.yml`, with no `CLAUDE.md`, no `index.md`, and no `.claude/skills`. `companion_install_spec` goes further: it bundles the fixture-only path gems under `spec/fixtures/smoke_companions/{rails-hyperdrive-alpha,rails-hyperdrive-beta}/` (real gemspecs shipping skills + guidelines) to drive the full install pipeline end-to-end — companion skill/guideline install with both audit-header forms, `index.md` aggregation + footprint, `hyperdrive:sync --overwrite` restore of a locally-modified file, cross-source skill collision (both variants installed, postfixed `--<source_gem>`), and the `disabled:` round trip (uninstall, stays gone, restored when the name is cleared). `auto_install_spec` drives `AutoInstall` through `bundle exec ruby -e` in the fixture app — **no Rails booted**, which is the whole point of the extraction — asserting a newly bundled companion's artifacts land, a locally-edited file survives, and a non-development environment installs nothing. `discover_generator_spec` smokes the networked `hyperdrive:discover` end-to-end against the live rubygems API: a healthy run must print a recognized outcome (silently-broken exits fail); offline/rate-limited runs are flagged and only the outcome assertion is skipped, keeping the suite deterministic. Every fixture registers the bundler-hyperdrive plugin from its in-repo path (`Smoke.add_path_gem!` appends both the `gem` line and the `plugin "bundler-hyperdrive", path:` line), so the hook running on every smoke `bundle install` is a standing regression check that it never breaks an install; `bundler_plugin_spec` covers the plugin end-to-end (a bundled companion's artifacts land during `bundle install` itself, an edited file survives, an upgraded companion is only reported — never overwritten, production installs nothing), and `auto_install_spec` passes `BUNDLE_PLUGINS=false` on its installs so it keeps driving the `AutoInstall.run` entry point directly with the plugin inert. Shared bundle cache lives at `spec/tmp/smoke-bundle/`. Run with `bundle exec rspec --tag smoke`. CI smoke job triggers on every push to `main`, on `workflow_dispatch`, or on PRs with the `run-smoke` label, and runs two corner slots only (Ruby 3.2/Rails 7.2 and Ruby 3.4/Rails 8.1).
- **Known coverage limits** (verified manually, not by the suite): two paths can't be exercised today. (1) **`hyperdrive:discover` with a live, non-empty result** — no `rails-hyperdrive-*` companion gems are published to rubygems yet, so the networked discover smoke only ever sees an empty result set; the with-results and 24h-cache-reuse paths are covered at unit level via `CompanionDiscovery`'s injectable `fetcher:`. (2) **Claude Code runtime consumption** — `.mcp.json` autoload, `@`-import resolution of `index.md`, and lazy skill loading all happen inside Claude Code itself, outside any process this suite can drive.

## Gemfile & dependency notes

- `Gemfile.lock` is **gitignored** — Bundler resolves fresh each install. CI keys its cache off `RAILS_VERSION` to avoid cross-slot bleed.
- Runtime deps: `railties`, `activerecord` (both `>= 7.2`, no upper cap), `mcp ~> 0.17`, `bundler >= 2.3`.
- License must stay MIT throughout, including transitive runtime deps — no Apache-licensed runtime additions.
