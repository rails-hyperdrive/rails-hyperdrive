# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A template/content-paired skill's supporting files can be templated too: a
  `*.md.erb` in the template directory renders against the app's bundle and
  installs as `x.md`, so generic skills.sh consumers never copy raw ERB. Within
  a paired skill a template-side file owns its target path — the content
  directory's same-named file never installs, whether the template renders, is
  gated out by `conditional:`, or fails to render.
  `rake hyperdrive:skills:render` now writes each supporting template's
  fail-open canonical face into the paired content directory, and
  `rake hyperdrive:skills:check` byte-gates those faces and fails on any
  `*.md.erb` found under a public skills root. A supporting `*.md.erb` shipped
  under a public skills root still renders, but draws a warning steering it to
  the template directory.
- `hyperdrive:init --skip-mcp` skips MCP setup entirely: no `rails-hyperdrive`
  entry in `.mcp.json` and no engine mount in `config/routes.rb`. Content
  install, the discover-cache `.gitignore` rule, and the bundler-plugin Gemfile
  directive all still run, and the summary reports `MCP: skipped (--skip-mcp)`
  in place of the mount/server lines. Like `--skip-content`, it only suppresses
  writes — existing MCP configuration is left untouched — and the two flags
  combine.
- `gems:` is an exact alias of `gem:` at every position the key is read —
  gem-wide defaults, `skills:`/`guidelines:` entries, and per-file
  `conditional:` entries — for every value shape. A map carrying both keys is a
  stylistic slip rather than an error: `gems:` wins, with a warning.
- Companion-manifest `gem:` gating accepts a map with exactly one of `any:` or
  `all:`, so an artifact can require *every* listed target rather than any one
  of them: `gems: {all: [devise, pundit]}`. `any:` is an explicit spelling of the
  existing any-match, which every bare form (single name, comma-separated
  string, YAML list, `"*"`) keeps by default. The map values take those same
  flat forms, and the form is accepted everywhere `gem:` is — gem-wide defaults,
  `skills:`/`guidelines:` entries, and per-file `conditional:` entries. A `"*"`
  inside `all:` is always satisfied, so it is dropped with a warning; a
  malformed map takes the usual fail-open path (warn, install ungated).
- Companion manifests can version-fence artifacts against the running
  rails-hyperdrive with a `hyperdrive_version:` requirement, valid gem-wide at
  the manifest top level and per `skills:`/`guidelines:` entry. It is matched
  against the installer's own version rather than the bundle — a constraint
  `gem:` cannot express, since it is an any-match gate across its targets. An
  unsatisfied fence skips the artifact and names the upgrade, both in
  `hyperdrive:init`/`hyperdrive:sync` output and during `bundle install` via the
  bundler plugin.

### Changed

- **Breaking (companion manifests).** Version constraints move onto the gate
  members and the sibling `versions:` key is gone. Wherever `gem:` takes a YAML
  list — the bare list and the `any:`/`all:` values alike — a member is now
  either a bare gem name or a single-pair map carrying that member's own
  requirement: `gems: [railties: ">= 7.0"]`. The requirement is a
  `Gem::Requirement` (comma-separated string or YAML list); a pair value of
  `"*"` or nothing means unconstrained. Scalar and comma-separated string forms
  stay name-only, and a pair value is never target-split, so a compound
  requirement like `">= 4.9, < 6"` is passed whole. A `"*"` used as a pair key
  is meaningless, so it is dropped with a warning in every list context; when it
  was the sole member the gate resolves universal.

  A `versions:` key remaining anywhere it used to be valid (top level,
  `skills:`/`guidelines:` entries, `conditional:` entries) is warned about and
  ignored: the named targets keep gating, unconstrained. Because requirements
  now travel with the targets, an entry's gate replaces the gem-wide default
  **wholesale** — the per-axis inheritance that let a top-level `versions:`
  apply to an entry naming a different `gem:` is gone. `hyperdrive_version:`
  inheritance is unchanged.

  No compatibility shim: older rails-hyperdrive releases read a pair member as a
  malformed `gem:` and install the artifact ungated.
- `hyperdrive:init`, `hyperdrive:sync`, and `hyperdrive:discover` are Rails
  commands rather than rake tasks, so their flags now work bare —
  `bin/rails hyperdrive:sync --merge` instead of
  `bin/rails hyperdrive:sync -- --merge` — and
  `bin/rails hyperdrive:sync --help` prints usage. The `-- --flag` form keeps
  working, so existing scripts and docs need no change.

### Removed

- **BREAKING:** the `hyperdrive:*` rake tasks. `bundle exec rake hyperdrive:init`
  (and `:sync` / `:discover`) is no longer available, and the tasks no longer
  appear in `bin/rails -T`. Use `bin/rails hyperdrive:<command>`, which is
  unchanged.

## [0.6.0] - 2026-08-17

### Changed

- `run_sql` now labels an over-cap result `(showing first 100 of <total> rows)`
  instead of `(<total> rows, truncated)`, which read as though rows beyond the
  count shown had been dropped from a smaller set.
- The connection check printed under `hyperdrive:init`'s "Next steps" is now a
  JSON-RPC `tools/list` POST carrying the `Content-Type` and `Accept` headers
  the endpoint requires. The previous bare `curl <url>` was a GET, which the
  stateless MCP transport answers with 405 — the suggested check read as a
  failure against a perfectly working install.

### Removed

- **BREAKING:** `Rails::Hyperdrive.configure` /
  `Rails::Hyperdrive::Configuration`, and the `config/initializers/hyperdrive.rb`
  initializer that `hyperdrive:init --mount-at` used to write. The
  initializer's only setting, `config.mount_at`, was read by nothing — the
  live mount is the `mount Rails::Hyperdrive::Engine` line the generator
  writes into `config/routes.rb`, and `.mcp.json` records the URL — so
  editing it never moved the endpoint. The `--mount-at` flag is unchanged.

  **Manual migration:** delete `config/initializers/hyperdrive.rb` if an
  earlier `hyperdrive:init --mount-at` wrote one. The file calls
  `Rails::Hyperdrive.configure` unguarded, so with the gem in the
  `:development` group it raises `NameError` on any boot that excludes that
  group (e.g. a production deploy) — deleting it also removes that hazard.

## [0.5.0] - 2026-08-15

### Added

- Gem-root manifest: a companion gem now declares artifact gating in a
  `hyperdrive.yml` at its root (or at the path named by a new
  `rails_hyperdrive_manifest` gemspec metadata key; `..` segments or a blank
  value fall back to the conventional path). Top-level `gem:`/`versions:` are
  gem-wide defaults; `skills:` entries (keyed by skill-dir relpath from the
  skills root) and `guidelines:` entries (keyed by filename) override them per
  key, and per-file `conditional:` gating nests inside `skills:` entries. All
  keys optional; malformed gating fails open (warn + install ungated, never
  skip, never raise), and an entry keying no shipped artifact warns — the
  staleness signal for gating detached from content. Shipping a manifest (file
  or metadata key) is also a companion opt-in signal, so a skills.sh-format
  skill repo integrates with zero modification to its skill files.

- Template/content pairing for skills, so one companion repo can serve
  `npx skills` / git-clone consumers and rails-hyperdrive at once without
  giving up bundle-conditioned content. A skill directory holding a static
  `SKILL.md` (the universal face: generated definition plus all supporting
  files) pairs with a `SKILL.md.erb` master at the same relative path under a
  templates root — declared via the new `rails_hyperdrive_skill_templates_dir`
  gemspec metadata key, defaulting to the convention path
  `lib/<gem_name>/hyperdrive/skills`. The pair discovers as one skill:
  hyperdrive renders the template against the app's bundle and installs the
  supporting files from the content directory, never reading the static
  `SKILL.md`. Unpaired layouts — every existing companion — behave exactly as
  before.
- Canonical-render rake tasks for companion repos:
  `require "rails/hyperdrive/skill_tasks"` in the Rakefile provides
  `rake hyperdrive:skills:render` (generate each template's static `SKILL.md`
  with the fail-open canonical binding — every gem present, `gem_version`
  `nil`; the generated face is the rendered template verbatim — with gating
  in the gem-root manifest there are no installer keys to strip) and
  `rake hyperdrive:skills:check` (fail listing stale generated
  files — the CI freshness gate). Rails-free; rails-hyperdrive as a
  development dependency suffices.
- A gem's top-level `skills/` directory is now scanned as a default skills
  root for opted-in companions (convention-path artifacts, a
  `rails_hyperdrive_skills_dir`, `rails_hyperdrive_skill_templates_dir`, or
  `rails_hyperdrive_targets` metadata key, or a lockfile `enabled:` entry are
  the opt-in signals). Roots are deduplicated
  by expanded path, so a companion already declaring
  `rails_hyperdrive_skills_dir: "skills"` sees identical results.
- A hand-editable `enabled:` list in `.hyperdrive/lock.yml` (gem names,
  mirroring `disabled:`): naming a gem there treats it as an opted-in
  companion, so its top-level `skills/` content installs through the normal
  pipeline. `disabled:` still wins for individual artifacts.
- `hyperdrive:init` and `hyperdrive:sync` now surface bundled gems that ship
  skills.sh-style `skills/*/SKILL.md` content without opting in as companions
  — report-only, with a pointer to the `enabled:` list; nothing is installed
  until the user opts in.

### Changed

- The artifact frontmatter contract is relaxed to the skills.sh base
  contract: only `name` and `description` are required. `gem:` and
  `versions:` are now optional narrowing keys — a missing `gem:` means
  universal (`"*"`), a missing `versions:` means unconstrained. Artifacts
  declaring all four fields behave exactly as before.
- **Breaking:** gating moved entirely to the gem-root manifest. The
  frontmatter `gem:`/`versions:`/`conditional:` keys are no longer read —
  they are ordinary unknown keys, silently ignored and installed verbatim —
  and installer-key stripping is removed: skill bodies now install, and
  render canonically, byte-identical to their shipped (or ERB-rendered)
  content, frontmatter included. Guideline frontmatter is still stripped on
  install. A companion gating via frontmatter must move those keys into
  `hyperdrive.yml`.

## [0.4.0] - 2026-08-08

### Added

- `hyperdrive:sync --sidecar`: when an installed file is locally modified and
  its gem ships something new, the new upstream body is delivered next to it
  as `<file>.new` instead of being skipped. The live
  file is never touched; `mv <file>.new <file>` accepts the upstream
  wholesale. The lockfile records the delivered upstream, so the same version
  is offered exactly once, and a delivered-but-unresolved file no longer nags
  from `bundle install`.
- `hyperdrive:sync --merge`: same as `--sidecar`, but first attempts a git
  three-way merge of the local edits with the upstream change, using the
  previously installed gem version (found in the installed gem directories,
  content-verified against the lock) as the ancestor. Only a clean merge is
  written to the live file — a conflict, a missing ancestor, a missing `git`,
  binary content, or an earlier delivery still unresolved at `<file>.new` all
  fall back to the sidecar delivery, so conflict markers never reach a live
  file and a pending delivery is never merged over.
- Leftover sidecars are swept: whenever a sync writes or verifies the live
  file, a `<file>.new` still matching a delivered upstream is removed, and
  one you edited is warned about and left alone.

### Changed

- **BREAKING:** the stack profile (`describe_app` MCP tool and the
  `hyperdrive://stack-profile` resource) no longer categorizes gems into
  `test` / `jobs` / `frontend` / `auth` / `authz` / `db_gems` buckets. Those
  keys are replaced by `direct_dependencies` — the app's declared gems (the
  lockfile's `DEPENDENCIES` section) with their resolved versions. The old
  buckets matched a hand-curated gem list against the *resolved* dependency
  set, so every Rails app reported transitive `minitest` as a chosen test
  framework
  ([#2](https://github.com/rails-hyperdrive/rails-hyperdrive/issues/2));
  raw direct dependencies carry no such editorializing and
  need no curated list to go stale. `rails`, `ruby`, `database`, and
  `gem_skills` are unchanged.

- Installed skills no longer carry the installer-only frontmatter keys
  (`gem:`, `versions:`, `conditional:`). They are discovery-time inputs with
  no post-install reader, and the `conditional:` map referenced shipped paths
  that gating and ERB rendering could leave pointing at files absent from
  disk — dead weight in the agent's context window at every skill invocation.
  The installed frontmatter now holds only what the runtime reads (`name:`,
  `description:`, any extra keys like `allowed-tools:`). Because the
  install-ready body changes, the next
  `hyperdrive:sync` rewrites each unedited installed skill once; locally
  edited skills are skipped with the usual warning.
- The skip warning for a locally-modified file now names all three
  reconciliation flags (`--merge`, `--sidecar`, `--overwrite`).
- Orphan reports now say "no longer shipped by \<source\>" instead of
  "source \<source\> no longer in bundle" — an artifact is also orphaned when
  its gem is still bundled but stopped shipping it.

### Removed

- Audit headers. Installed skills and guidelines no longer carry the
  `# hyperdrive: source=...` / `<!-- hyperdrive: ... -->` comment block —
  every installed file now lands byte-identical to its install-ready body
  (sidecar `.new` deliveries and merge results included). The header
  duplicated what the git-tracked `.hyperdrive/lock.yml` already records per
  file (`source`, `source_sha`, `installed_at`) and was loaded into the
  agent's context on every skill invocation (and eagerly, for guidelines).

## [0.3.0] - 2026-08-04

### Added

- `bundler-rails-hyperdrive`, a Bundler plugin gem co-located in this repository
  (`bundler-rails-hyperdrive/`). Once registered, it runs after every
  `bundle install` in development and installs the artifacts that newly
  bundled companion gems ship — additive only (it never overwrites or
  deletes a file) — and reports upgraded or orphaned artifacts with a
  pointer to `bin/rails hyperdrive:sync`. It resolves rails-hyperdrive from
  the application's bundle at runtime (supported range `>= 0.2`), stays
  silent outside development, and never fails a `bundle install`.
- `hyperdrive:init` now registers the plugin by appending
  `plugin "bundler-rails-hyperdrive"` to the application's Gemfile. Idempotent: an
  existing directive (with any options) is left alone, and an app without a
  Gemfile gets a skip status.
- **Gem-conditional skill content.** A multi-file skill can now condition parts
  of itself on the app's bundle, through two complementary mechanisms evaluated
  at discovery time:
  - A `conditional:` map in `SKILL.md` frontmatter gates individual supporting
    files per gem. Keys are dir-relative shipped paths; values reuse the
    artifact-level `gem:`/`versions:` forms (single target, comma-separated
    string, YAML list, per-target `versions:` map, `"*"`), with `versions:`
    optional (omitted = unconstrained). A gated file installs only when a
    listed target is bundled at a satisfying version, and disappears on the
    next `hyperdrive:sync` when its gate closes (unedited copies only). A
    malformed condition fails open — the file installs and the problem is
    reported as a discovery warning.
  - Files named `*.md.erb` in a skill directory — including `SKILL.md.erb` in
    place of `SKILL.md` — are rendered at install time with a sealed helper
    binding (`gem?`, `any_gem?`, `gem_version`) over the resolved bundle, and
    install as plain `.md`. A template that fails to render is skipped with a
    warning (the whole skill, for `SKILL.md.erb`); a plain file always beats a
    template rendering to the same path.

- **Multi-file skills.** A companion skill directory can now ship more than
  `SKILL.md`: every other file in it (nested however deep — `workflows/`,
  `references/`, `examples/`, …) installs as a **supporting file** under
  `.claude/skills/<name>/`, preserving the relative layout, so `SKILL.md` can
  reference it with directory-relative links (which survive cross-source
  collision postfixing, since that renames the whole directory). Supporting
  files carry no frontmatter contract and no audit header — they land
  byte-identical to what the gem ships, with provenance and a per-file sha
  recorded in `.hyperdrive/lock.yml` under the new `skill_support` kind. The
  full drift state machine applies per file (unedited upgrades rewritten,
  local edits skipped on sync / restored with `--overwrite`, deletions
  reinstalled), a supporting file the gem stops shipping is cleaned up when
  unedited (warned about and left when edited), disabling a skill removes its
  unedited supporting files too, and the install summary shows them as a
  `(+N files)` count on the skill's line.

- `hyperdrive:sync` — content-only actualization. Refreshes skills, guidelines,
  `index.md`, and `.hyperdrive/lock.yml` to match the current bundle, and
  touches no bootstrap artifact (`.mcp.json`, the engine mount, the
  optional initializer, the `.gitignore` rule). Locally-edited files are
  preserved by default (skip + warn); pass `--overwrite` to restore the
  gem-shipped content. Works with or without a prior `hyperdrive:init`.
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
- Content installation is now callable without a booted Rails application.
  `Rails::Hyperdrive::InstallPipeline` takes an explicit application root and
  performs the whole install — skills, guidelines, `index.md`, the `CLAUDE.md`
  import line, and `.hyperdrive/lock.yml` — so any process that can
  see the app's bundle can run it. `hyperdrive:init` and `hyperdrive:update`
  call the same pipeline, and their behaviour is unchanged.
- `Rails::Hyperdrive::ArtifactStatus` compares what the bundle offers against
  what `.hyperdrive/lock.yml` records, classifying every artifact as
  `installed`, `missing`, `outdated`, or `orphaned`.
- `Rails::Hyperdrive::AutoInstall.run` tops up an already-initialized
  application with artifacts the lockfile does not record yet, and returns
  everything it deliberately left alone. Installation is strictly additive: it
  can create a file that does not exist, and it will never overwrite one, so a
  locally-edited artifact is safe. Upgraded and orphaned artifacts are reported
  for `hyperdrive:update` to handle. It writes only when the environment reads
  as development from `ENV` directly (no Rails to ask), `CI` is unset, and the
  bundle is not frozen, and it reports errors rather than raising them.

- `hyperdrive:init` / `hyperdrive:update` now check the *combined* eager
  footprint against a budget, not just per-file size. When the guidelines
  listed in `index.md` exceed ~10,000 tokens, the footprint line is followed
  by a warning naming the two largest contributors, so it is
  clear what to trim or which line to drop from `index.md` to opt a guideline
  out. Individually reasonable guidelines could previously clear every per-file
  check and still add up to real context-window pressure with nothing flagging
  it. The install still proceeds — this is a warning, not a gate.

- `hyperdrive:init` / `hyperdrive:update` now list every installed artifact in
  the final summary, grouped under the source gem and version that shipped it,
  instead of reporting bare skill and guideline counts. The listing is built
  from `.hyperdrive/lock.yml`, so it reflects what the app ends up with —
  including files left unchanged, files skipped as locally modified, and
  orphans whose source gem has left the bundle — rather than only what the run
  wrote. `--skip-content` prints no listing, as before.

- `hyperdrive:init` / `hyperdrive:update` now warn when git ignores an install
  destination. Installed artifacts are git-tracked on purpose: reviewing the
  diff is how you see what a companion gem added to the agent's context. An app
  that gitignores `.claude/` empties that diff while the artifacts still reach
  the agent, and nothing previously said so. The check asks git whether each
  destination is ignored, so patterns, negations, and per-repository excludes
  are all honored; outside a git repository, or without git installed, it stays
  silent.

- Per-artifact opt-out via a `disabled:` list in `.hyperdrive/lock.yml`, keyed by
  artifact type (`skills:` / `guidelines:`). A listed artifact is never installed,
  and one already on disk is removed on the next `hyperdrive:init` /
  `hyperdrive:sync` — but only when the file still matches the content the lock
  recorded, so a locally-modified artifact is reported and left in place instead.
  Disabling a guideline also drops its line from `index.md`. For a name shipped by
  more than one companion gem, the shipped name disables every variant and the
  `--<source-gem>` postfixed name disables one. The list is hand-edited: the
  generator reads it, carries it forward, and writes the empty scaffold on every
  install so the key is discoverable. Previously the only control was
  `--skip-content`, which suppresses all installed content at once.

### Changed

- **BREAKING:** the eager-content chain is now companion-driven.
  `.claude/hyperdrive/index.md` and the `@.claude/hyperdrive/index.md` line in
  `CLAUDE.md` are created only once a companion gem ships a guideline, and are
  removed again when the last one leaves the bundle. A zero-companion
  `hyperdrive:init` now writes `.mcp.json`, the `.gitignore` rule, the optional
  initializer, the engine mount, and `.hyperdrive/lock.yml` — and nothing into
  the agent's context window. On tear-down, `CLAUDE.md` is deleted only when it
  is byte-identical to the file hyperdrive created; otherwise only hyperdrive's
  own import line is removed and every other byte is left alone. An import line
  you deleted by hand is still never re-added. `hyperdrive:sync` performs the
  tear-down; the `bundler-rails-hyperdrive` plugin (additive) never removes anything.
  Because a `bundle install` must not edit `CLAUDE.md`, the plugin now says so
  when it installs the first guideline into an app that has no import line yet:
  the guideline is on disk but out of context until you run
  `bin/rails hyperdrive:sync`.
- **BREAKING:** `hyperdrive:init` no longer accepts `--update` /
  `--force-install`; it always preserves locally-edited files (skip + warn).
  The conflict warning and the AutoInstall nudge now point at
  `hyperdrive:sync`.
- `hyperdrive:init`'s summary now reports the mounted MCP server and its tool
  count.
- `bundle install` (through the `bundler-rails-hyperdrive` plugin) no longer parses
  `Gemfile.lock`.

### Removed

- **BREAKING:** `.claude/hyperdrive/stack.md` is no longer generated. Ask the
  running server what the app's stack is instead — the `describe_app` MCP tool
  and the `hyperdrive://stack-profile` resource answer it live, from the
  resolved bundle, and can never go stale the way a written-once file does.

  **Manual migration:** an app installed before this release keeps
  `.claude/hyperdrive/stack.md` on disk, and `hyperdrive:init` / `hyperdrive:sync`
  will report it as an orphan on every run. Delete the file and its
  `.hyperdrive/lock.yml` entry by hand.
- **BREAKING:** `hyperdrive:update` is removed (not deprecated) — use
  `bin/rails hyperdrive:sync --overwrite`. Note the default flip: the routine
  refresh (`hyperdrive:sync`) now preserves locally-edited files; overwriting
  them is opt-in via `--overwrite`.

### Fixed

- The MCP endpoint no longer 403s local requests whose `Origin` port differs
  from the server's (e.g. `Origin: http://localhost` against
  `127.0.0.1:3000`). The `mcp` gem's `StreamableHTTPTransport` gained
  default-on DNS-rebinding protection requiring a same-origin `host:port`
  match; it is now disabled in favor of the engine's own Rack middleware,
  which allows any `localhost` / `127.0.0.1` / `[::1]` origin regardless of
  port. The `mcp` dependency floor moves to `~> 0.25` accordingly.

- `.hyperdrive/lock.yml` now round-trips top-level keys it does not recognize.
  Reading it selected only the known keys and writing it rebuilt the document from
  scratch, so anything hand-added to the file was erased on the next run. Entries
  under `files:` remain fully generated.

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
  installed content, not just skills: skills, guidelines, `index.md`,
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

[Unreleased]: https://github.com/rails-hyperdrive/rails-hyperdrive/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.6.0
[0.5.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.5.0
[0.4.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.4.0
[0.3.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.3.0
[0.2.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.2.0
[0.1.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.1.0
