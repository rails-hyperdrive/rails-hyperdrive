# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **ERB templates for guidelines, agents, and commands.** A companion can ship a
  flat artifact as `<name>.md.erb` directly in its own root
  (`lib/<gem_name>/hyperdrive/guidelines/`, `agents/`, `commands/`, or an
  `agents_dir:`/`commands_dir:` override). It renders at discovery against the
  app's resolved bundle with the same helpers skills use — `gem?`, `any_gem?`,
  `gem_version`, `canonical_render?` — and installs as `<name>.md`: a
  guideline's frontmatter is parsed from the render and then stripped, a
  templated command takes its identity from the rendered stem
  (`analyze.md.erb` → `/analyze`, prefixed by `command_prefix:` as usual), and
  the rendered bytes are what the lock hashes, so a re-render is an ordinary
  upstream delivery through the existing drift, sidecar, and merge machinery.
  There is no template/content pairing for flat kinds and no separate template
  root: Claude Code plugins glob `*.md`, so a template is invisible to them.
  A static `<name>.md` beats a template rendering to the same filename anywhere
  in the kind's roots, always with a warning; a manifest entry may key the
  artifact by either spelling (`reviewer.md.erb` or `reviewer.md`), the shipped
  spelling winning with a warning when both appear, and
  `rake hyperdrive:manifest:check` fails on that ambiguity. A convention-path
  guideline template opts a gem in as a companion, like its static twin.
  Declare a gem-wide `hyperdrive_version: ">= 0.8"` when shipping templated flat
  artifacts: earlier installers never look for `*.md.erb` outside skill
  directories, so the fence is what turns their silence into "upgrade
  rails-hyperdrive to install it".
- `canonical_render?`, a fourth skill-template ERB helper: `true` in the
  author-side canonical render (`rake hyperdrive:skills:render`/`check`) and
  `false` when rendering into an app, so one template can serve both channels
  where the same content has to read differently — a companion that also ships
  as a Claude Code plugin, say, whose command spellings differ from the
  hyperdrive-installed ones. Unlike the bundle predicates it is deterministic in
  both bindings, so `if`/`else`/`unless` on it is safe. A template using it
  should declare `hyperdrive_version: ">= 0.8"` in its manifest entry (or
  gem-wide), so an older installer reports "upgrade rails-hyperdrive" rather
  than skipping the skill with a template-render failure.

## [0.7.0] - 2026-08-26

### Added

- **Two new companion artifact kinds: agents and commands.** A companion gem can
  now ship Claude Code subagents from `agents/*.md` (installed to
  `.claude/agents/<name>.md`) and slash commands from `commands/*.md` (installed
  to `.claude/commands/<name>.md`), alongside its skills and guidelines. Both
  are flat single files that install byte-identical to what the gem ships, and
  both ride the whole existing machine: gating, the `hyperdrive_version:` fence,
  sha-based drift, `--overwrite`/`--sidecar`/`--merge`, `disabled:`, the stale
  sweep, cross-source collision postfixing, and the additive top-up on
  `bundle install`. Agents require `name` + `description` frontmatter like a
  skill; a command's frontmatter is optional and never validated, and its
  identity is its filename stem, so `commands/analyze.md` becomes `/analyze`.
  Neither is wired into `CLAUDE.md` or `index.md` — Claude Code registers them
  by file presence. Installing flat (no per-gem subdirectory) keeps the
  `skills/`/`agents/`/`commands/` sibling geometry a gem ships, so relative
  links between them resolve unchanged after install.
- Manifest additions in `hyperdrive.yml`: `agents:` and `commands:` gating
  sections keyed by filename, taking the same values `guidelines:` entries do;
  `agents_dir:` and `commands_dir:` to name additional roots (resolved like
  `skills_dir:`); and `command_prefix:`, an optional gem-wide scalar inside
  `commands:` that installs every command of that gem as `<prefix>-<filename>`,
  for a companion that also ships as a Claude Code plugin and wants its
  `/name` namespaced. `rake hyperdrive:manifest:check` lints all of them.

- `require "hyperdrive/skill_tasks"` is the require path for the companion-repo
  rake tasks (`hyperdrive:skills:render`, `hyperdrive:skills:check`,
  `hyperdrive:manifest:check`) — framework-neutral, since the tasks run in a
  plain gem repo with no Rails involved.
- The `hyperdrive_version:` fence now carries a stated guarantee for companion
  authors: it fences on whichever gem implements artifact discovery and install
  — today rails-hyperdrive — and that version numbering is guaranteed
  continuous across any future restructuring of the gem, so a fence like
  `">= 0.8"` keeps its meaning permanently.
- `rake hyperdrive:manifest:check`, a strict author-side lint of a companion
  gem's `hyperdrive.yml`, on the same companion-repo rake surface as
  `hyperdrive:skills:*` (add `require "hyperdrive/skill_tasks"` to the
  Rakefile; takes the same optional gemspec-path argument). Where the installer
  is permissive so a manifest written for a newer schema never blocks an
  install, the lint fails: unknown keys at every level — the top level,
  `skills:`/`guidelines:` entries, and `conditional:` entries — plus any
  `gem:`/`gems:` or `hyperdrive_version:` value the installer cannot parse, and
  `skills:`/`guidelines:`/`conditional:` keys naming nothing the gem ships. The
  retired `versions:` key and its `version:` near-miss are named pointedly.
  A manifest that lints clean draws no gating warning at install time.
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

- **Breaking (installer skew).** `.hyperdrive/lock.yml` is now written at schema
  version 2, so every machine working on an app that has synced with this
  release needs this release too. Older installers ship no schema guard and
  cannot refuse: a 0.6.0 `init`, `sync`, or bundler-plugin top-up run against a
  lock this release wrote silently degrades instead — it never discovers agents
  or commands, so it orphan-warns their lock entries on every run, drops their
  `disabled:` lists, and rewrites the lock back to version 1. Installed files
  are never deleted. From this release on, the read guard (below) makes the
  same skew halt with the upgrade remedy instead of degrading.
- **Breaking (bundler plugin).** The `bundler-rails-hyperdrive` plugin gem is
  renamed `bundler-hyperdrive` — its directory, gem name, Gemfile directive
  (`plugin "bundler-hyperdrive"`), and release tag namespace
  (`bundler-hyperdrive/vX.Y.Z`). `hyperdrive:init` writes and matches the new
  directive only; an app carrying the old one gets the new line appended and
  should drop the old. Nothing else changes: the `Bundler::Hyperdrive`
  namespace, the hook, and its behavior are untouched.
- **Breaking (companion gemspecs).** The two directory overrides move out of
  gemspec metadata and into the gem-root manifest as top-level keys:
  `hyperdrive_skills_dir` → `skills_dir:` in `hyperdrive.yml`, and
  `hyperdrive_skill_templates_dir` → `skill_templates_dir:`. The metadata keys
  are no longer read at all — under either spelling, the `rails_`-prefixed one
  0.6.0 shipped included, and with no deprecation or dual-read — so a gem still
  declaring them ships from the default roots, and they no longer count as
  companion opt-in signals (the manifest that now carries them is one).
  Gemspec metadata is left as strictly the pre-install surface rubygems
  serves: `hyperdrive_targets`, `hyperdrive_artifacts`, and the
  `hyperdrive_manifest` bootstrap pointer. Discovery resolves both roots
  fail-open like every other manifest value: a non-string or `..`-containing
  value is warned about and the default roots are used (where the metadata keys
  were ignored silently), and a blank one falls back silently. The
  companion-repo rake tasks stay strict and now raise on a manifest that will
  not parse, rather than rendering with default roots over a file the
  installer cannot read. `rake hyperdrive:manifest:check` validates the two
  new keys.
- **Breaking (companion gemspecs).** The remaining companion-gem gemspec
  metadata keys drop their `rails_` prefix: `rails_hyperdrive_targets` →
  `hyperdrive_targets`, `rails_hyperdrive_artifacts` →
  `hyperdrive_artifacts`, and `rails_hyperdrive_manifest` →
  `hyperdrive_manifest`. The contract is not Rails-specific, and the keys now
  read that way. The old spellings are no longer read, with no deprecated
  alias: a gem still declaring them is not opted in as a companion, its
  manifest override is ignored, and `hyperdrive:discover` — which now queries
  rubygems for `metadata.hyperdrive_targets:*` — no longer surfaces it.
  Companion gems must update their gemspecs.
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
- `.hyperdrive/lock.yml` is now read-guarded against its own schema version. The
  lock is git-tracked and shared across branches that pin different
  rails-hyperdrive versions, so an installer can meet a lock a newer one wrote.
  It previously rewrote the file anyway: unknown top-level keys survive the
  round-trip, but anything a newer schema stores inside the keys it recognizes
  — `disabled:` lists for kinds it does not know, or a reshaped `enabled:` or
  `claude_md` — was silently dropped.
  `hyperdrive:init` and `hyperdrive:sync` now fail with the upgrade remedy
  before any content write (`--dry-run` included, and init's bootstrap steps
  still complete), and `bundle install`'s auto-install prints the same reason
  and installs nothing.
- An artifact that changes destination — a companion renaming a skill, or a
  cross-source name collision appearing or resolving, flipping between
  `.claude/skills/<name>/` and `.claude/skills/<name>--<source_gem>/` — now has
  its old copy removed, supporting files and emptied directories included,
  instead of being left behind as a byte-duplicate that warns on every sync.
  Removal requires the source gem to still be bundled and to have lost no
  artifact to a discovery skip this run, so a broken companion release or a
  version fence never deletes a good install; a locally-modified copy is always
  warned about and left. The bundler plugin's auto-install removes nothing, as
  before.
- Orphan warnings no longer claim an artifact is "no longer shipped by" a gem
  that is still in the bundle, in both `hyperdrive:sync` output and the
  "need attention" lines printed during `bundle install`.
- A `disabled:` entry naming a skill by its postfixed name (`foo--gem_a`) now
  opts that source's artifact out permanently, rather than only while the
  collision that produced the postfix exists.
- `hyperdrive:init`, `hyperdrive:sync`, and `hyperdrive:discover` are Rails
  commands rather than rake tasks, so their flags now work bare —
  `bin/rails hyperdrive:sync --merge` instead of
  `bin/rails hyperdrive:sync -- --merge` — and
  `bin/rails hyperdrive:sync --help` prints usage. The `-- --flag` form keeps
  working, so existing scripts and docs need no change.

### Removed

- **BREAKING:** `require "rails/hyperdrive/skill_tasks"`. The companion-repo
  rake tasks are required as `hyperdrive/skill_tasks`; a Rakefile using the old
  spelling raises `LoadError` and needs the one-line change. There is one path,
  under no framework's namespace.

- **BREAKING:** the `hyperdrive:*` rake tasks. `bundle exec rake hyperdrive:init`
  (and `:sync` / `:discover`) is no longer available, and the tasks no longer
  appear in `bin/rails -T`. Use `bin/rails hyperdrive:<command>`, which is
  unchanged.

### Fixed

- A parseable `hyperdrive_version:` fence now survives an unusable `gem:`,
  both per entry and in the gem-wide defaults. The fence is resolved before
  the gate, so fail-open reads "install ungated unless fenced out": a manifest
  written in a value shape an older installer cannot parse is fenced out of
  that installer instead of installing everywhere unconstrained — the exact
  case `hyperdrive_version:` exists to cover. The two gem-wide defaults are
  independent too: an unusable `gem:` default no longer drops a parseable
  fence, and a malformed fence no longer drops a usable `gem:` default; each
  warns for its own axis. An entry whose *own* `hyperdrive_version:` is
  unparsable still installs ungated and unfenced — the gem-wide fence is not
  substituted for a constraint the entry never asked for.
- A `conditional:` key spelled as a template-backed supporting file's rendered
  face (`references/x.md`) now gates that template, instead of silently
  matching nothing while the file installed unconditionally. Either spelling —
  the shipped `references/x.md.erb` or the face — resolves to the same gate;
  a manifest carrying both for one file draws a warning and the shipped `.erb`
  spelling wins. `rake hyperdrive:manifest:check` agrees with discovery on
  both points, and no longer reports a face-spelled key as naming nothing
  shipped.
- A `SKILL.md.erb` that fails to render because it reaches for a helper a
  newer rails-hyperdrive added now reports its `hyperdrive_version:` fence
  rather than a bare `ERB render failed (NameError)`, and that line reaches the
  bundler-plugin surface like every other fence warning.
- An ordinary gate miss — a well-formed `gem:` whose target simply is not
  bundled — no longer marks its source gem as having lost content, so the
  stale-destination sweep keeps converging for companions that gate different
  skills on different stacks. A renamed skill's old directory is now removed
  instead of being orphan-warned indefinitely.
- `hyperdrive:sync` sweeps a stale `<dest>.new` sidecar when it removes the
  destination that sidecar belonged to, under the same rule as everywhere else
  (machine-pristine → removed; edited → warned about and left). A pristine
  leftover no longer strands itself or keeps an emptied skill directory alive.
- `rake hyperdrive:manifest:check` fails when a `hyperdrive_manifest` gemspec
  metadata key names a path that is not a file — previously read as "this gem
  ships no manifest" and reported green, while the dangling key still counted
  as companion opt-in and every artifact installed ungated.
- `rake hyperdrive:skills:render` / `:check` work for a companion that declares
  neither `hyperdrive_skills_dir` nor `hyperdrive_skill_templates_dir`: the
  content root now defaults to top-level `skills/` (matching discovery) rather
  than to the same lib-convention path as the templates root, which made the
  tasks hard-error with "content dir equals template dir".
- `init`/`sync` no longer count advisory discovery warnings as dropped
  artifacts. Warnings that dropped shipped content — a whole artifact, or one
  supporting file of one — print under `discovery skipped N item(s):` (was
  `discovery skipped N artifact(s):`, which counted every warning and named
  them all artifacts); everything that installed anyway prints under
  `discovery reported M advisory warning(s):`.
- The bundler-plugin hook now prints discovery advisories during
  `bundle install`, so a retired `versions:` key — content this release
  deliberately installs unconstrained — is no longer silent there. Ordinary
  artifact skips stay with `init`/`sync`.
- The `installing ungated` warning on a malformed manifest entry that keeps its
  fence now reads `installing ungated unless fenced out`, so it can no longer
  contradict a fence-skip line for the same artifact. Only an unparsable
  `hyperdrive_version:` says `installing ungated and unfenced`.
- The warning for a manifest that will not parse now names the parser error
  (`ignoring manifest hyperdrive.yml: malformed YAML (<reason>)`), matching what
  `rake hyperdrive:manifest:check` already reported. Behaviour is unchanged:
  gating that cannot be read still resolves to an absent manifest.

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

[Unreleased]: https://github.com/rails-hyperdrive/rails-hyperdrive/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.7.0
[0.6.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.6.0
[0.5.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.5.0
[0.4.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.4.0
[0.3.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.3.0
[0.2.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.2.0
[0.1.0]: https://github.com/rails-hyperdrive/rails-hyperdrive/releases/tag/v0.1.0
