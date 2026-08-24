# Writing a companion gem

rails-hyperdrive is the mechanism; companion gems are the content. This document is the full contract a companion gem ships artifacts under. For the short version (layout, frontmatter, discoverability), see the [README](../README.md#build-a-companion-gem).

## Artifact layout

A companion gem ships artifacts under:

```
<gem-source>/skills/<name>/SKILL.md                                 # skill (dir-per-skill) — recommended, the gem's public face
<gem-source>/lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md       # skill — hyperdrive-specific root, also scanned
<gem-source>/lib/<gem_name>/hyperdrive/guidelines/<name>.md         # guideline (flat file)
```

`<gem_name>` is the gem's name exactly as published, dashes and all — Ruby's dash-to-slash require convention does not apply. A gem named `rails-hyperdrive-sidekiq` ships guidelines under `lib/rails-hyperdrive-sidekiq/hyperdrive/guidelines/`, **not** `lib/rails/hyperdrive/sidekiq/guidelines/`. A file at the dash-to-slash path is silently never discovered: guidelines have no override root and no fallback, so nothing can warn about it.

Top-level `skills/` is the recommended home for skill content: it is the public, tool-agnostic face of the gem, matching what [skills.sh](https://www.skills.sh) and plain git-clone consumers expect, and it is scanned by default once the gem has opted in (below); no additional metadata key is needed. `lib/<gem_name>/hyperdrive/` is the hyperdrive-specific root: it holds guidelines and is the default home for ERB skill templates (`SKILL.md.erb` must stay here, so raw ERB never reaches generic `skills/` consumers). Plain static skills shipped under it remain scanned indefinitely, so published companions keep working unchanged; prefer top-level `skills/` for new ones.

### The companion opt-in gate

Discovery walks the entire bundle, and many gemspecs package files via `git ls-files`, so an ordinary non-companion gem can ship a contributor-facing `skills/` directory by accident. A gem's artifacts are therefore only scanned when one of a closed set of signals is present:

- artifacts under the `lib/<gem_name>/hyperdrive/` convention path — skills or guidelines;
- a `hyperdrive.yml` manifest at the gem root (below);
- one of the gemspec metadata keys `hyperdrive_skills_dir`, `hyperdrive_skill_templates_dir`, `hyperdrive_targets`, or `hyperdrive_manifest` — any non-empty value counts, even one discovery later rejects (a `..` segment, say), since declaring the key at all signals intent;
- the app naming the gem in the `enabled:` list of `.hyperdrive/lock.yml`.

`hyperdrive_artifacts` is deliberately not in that set: it is a presentational hint read by `hyperdrive:discover` (below) and never an opt-in signal.

An un-opted gem shipping `skills/*/SKILL.md` never auto-installs: `hyperdrive:init`/`hyperdrive:sync` surface it with a pointer to the `enabled:` list instead.

Skills may also ship under an additional root declared in gemspec metadata:

```ruby
spec.metadata["hyperdrive_skills_dir"] = "extra/skills"   # optional; relative to the gem root
```

That root is searched **in addition to** the default roots, never instead of them, so an override never hides skills already shipped elsewhere. Roots are deduplicated by expanded path (declaring `"skills"` explicitly changes nothing), and a value containing a `..` segment is ignored. Guidelines have no override: they are found only at the convention path.

## Multi-file skills

A skill is a **directory**, and it may ship more than `SKILL.md`. Everything else in it, nested however you like (`workflows/`, `references/`, `examples/`, …), installs alongside as **supporting files**:

- The relative layout is preserved under `.claude/skills/<name>/`, so directory-relative links from `SKILL.md` keep working, even on a cross-source name collision (which renames the whole installed directory).
- Files install byte-identical to what the gem ships (markdown, code, or binary alike); the one exception is `*.md.erb` templates, which install as their rendered output.
- Each file is tracked individually in `.hyperdrive/lock.yml`, so local edits are preserved on sync exactly like any other installed file.
- Supporting files carry no frontmatter contract: `SKILL.md` frontmatter remains the skill's sole schema surface.

Guidelines stay single-file.

## Frontmatter

Every artifact carries YAML frontmatter following the [Agent Skills](https://agentskills.io/specification) / skills.sh base contract: `name` and `description`, both required; every other key is ignored by the parser and installed verbatim:

```yaml
---
name: jobs-sidekiq                # kebab-case; determines the install path
description: Background job conventions for Sidekiq.
---
```

A plain skills.sh SKILL.md installs with zero warnings, and an adopted skill repo's content needs no modification: gating lives entirely in the gem-root manifest (below). A skill installs byte-identical to its shipped (or ERB-rendered) body, frontmatter included; guidelines are installed with their frontmatter stripped entirely (they are `@`-included eagerly). Provenance (`source`, `source_sha`, `installed_at`) is recorded per file in the git-tracked `.hyperdrive/lock.yml`, never inside the installed file. When two gems ship a same-named artifact, both install, each postfixed by source gem.

`name:` is the artifact's identity, not a label. It is what the installer writes to disk (`.claude/skills/<name>/SKILL.md`, `.claude/hyperdrive/guidelines/<name>.md`). Keep it equal to the file or directory stem: if the two disagree the install still succeeds, but the artifact lands under `name:`. Within one gem, two artifacts of the same type declaring the same `name:` collapse to a single installed file; which one survives is not a guarantee to build on, so give each a distinct `name:`.

`--` is reserved inside `name:`. It is the collision-postfix separator: colliding artifacts install as `<name>--<source_gem>`, and the installer parses an installed name back at its **first** `--` to recover the base name, which drives `disabled:` matching, orphan reporting, and the sha-gated delete. A `name:` containing `--` makes that parse ambiguous. Avoid `--` in the companion gem's own name for the same reason — the gem name is what lands in the postfix.

Renaming a skill directory or its `name:` is a breaking change for apps that already installed it. On their next `hyperdrive:init`/`hyperdrive:sync` the new name installs fresh and the old one is deleted — but only when the old copy is unedited, its source gem is still bundled, and that gem lost no artifact to a discovery skip in the same run; a locally edited copy is reported and left for the user to delete by hand. The additive top-up after `bundle install` removes nothing, so until a sync runs the skill sits under both names. Renaming the directory also detaches its gating, since `skills:` entries are keyed by directory path: the old manifest key names no shipped directory and starts warning.

## The gem-root manifest

Gating (which bundles an artifact installs into) is declared in a `hyperdrive.yml` at the gem root, or at the path named by a `hyperdrive_manifest` gemspec metadata key (relative to the gem root; a value containing `..` segments, or a blank value, falls back to the conventional path). Every key is optional, and no manifest (or an empty one) means every artifact installs universally:

```yaml
gems:                    # gem-wide default TARGET gem(s); "gem:" is an exact alias
  - railties: ">= 7.2"   # a list member is a bare name, or a name: requirement pair
hyperdrive_version: ">= 0.7"   # gem-wide default fence against the INSTALLER's own version — see below
skills:                  # per-skill entries, keyed by the skill dir's path relative to its skills root
  layered-rails:
    gems:
      - railties: ">= 8.0"
    hyperdrive_version: ">= 0.7"
    conditional:         # per-file supporting-file gating — see below
      references/gems/alba.md: { gem: alba }
guidelines:              # per-guideline entries, keyed by filename (extension included)
  jobs.md:
    gem: sidekiq
```

`gem:` and `gems:` are exact aliases at every position they are read — top-level, `skills:`/`guidelines:` entries, and `conditional:` entries — for every value shape. Use whichever reads naturally; this document writes `gem:` for a single scalar and `gems:` for lists and `any:`/`all:` maps. A map carrying both keys is a stylistic slip rather than an error: `gems:` wins, with a warning.

Entries are keyed by path, never by the skill's `name:`: a skill entry's key is the skill directory's path relative to its skills root (for a template/content-paired skill, the content dir's path), and a guideline entry's key is its filename. Resolution is per artifact:

- **`gem`/`gems`**: the entry's own value when either key is present, else the top-level default, else `"*"` (ungated). An entry's value replaces the default gate **wholesale** — targets and their requirements travel together. A per-entry `gem: "*"` therefore un-gates an artifact against a gem-wide default.
- **`hyperdrive_version`**: the entry's own value when the key is present, else the top-level default, else no fence. A per-entry `hyperdrive_version: ">= 0"` therefore un-fences an artifact against a gem-wide fence.

`gem:` names the **targets**: each must be present in the bundle, and a target carrying a requirement must also resolve to a satisfying version. Use `railties` for "every Rails app" or `"*"` for "always applicable". A well-formed gate matching nothing in the bundle skips the artifact with a warning; that is gating working. Malformed gating, by contrast, never skips an artifact:

- an unreadable or non-map manifest is warned about and treated as absent;
- a non-map `skills:`/`guidelines:` section is warned about and ignored;
- a malformed entry (a non-map value, or an unusable `gem:`) is warned about and the artifact installs **ungated**, the gem-wide `gem:` default dropped along with it — though a resolvable fence still applies (below);
- an entry whose own `hyperdrive_version:` is unparsable is warned about and installs ungated **and** unfenced;
- an entry whose key matches no shipped skill directory or guideline is warned about and ignored; this is the staleness signal when a skill dir is renamed out from under its gating.

### Version requirements

A version constraint rides on the target it constrains. Wherever `gem:` takes a YAML list, a member is either a bare gem name (unconstrained) or a single-pair map `name: "requirement"`:

```yaml
skills:
  layered-rails:
    gems:
      - railties: ">= 7.2"
```

The requirement is a `Gem::Requirement` string; commas separate its parts, so `">= 4.9, < 6"` is a single two-part requirement. A pair value of `"*"` or nothing at all means unconstrained, exactly like the bare member.

Scalar and comma-separated string forms stay name-only — `gem: railties` and `gem: "pg, mysql2"` name targets and never carry requirements. Commas split a bare string into target names; inside a pair value they belong to the requirement.

There is no separate `versions:` key. A manifest still carrying one is warned about and the constraint is ignored — the named targets keep gating, unconstrained — so migrate the requirement onto the member.

### Multiple targets

One artifact can cover several libraries. Write `gems:` as a map with exactly one of `any:` or `all:` — the recommended spelling once more than one target is involved, because it states the intent in the manifest:

```yaml
skills:
  jobs-conventions:
    gems:
      any:                                    # installs when ANY listed target is bundled
        - sidekiq: ">= 7.0"
        - solid_queue: ">= 1.0"
        - good_job
  authorized-devise:
    gems:
      all:                                    # installs only when EVERY listed target is bundled
        - devise: ">= 4.9"
        - pundit
```

A bare `gems:` — single name, comma-separated string, or YAML list — is shorthand for `any:`, and pair members are valid there too: `gems: [railties: ">= 7.0"]` needs no mode key. The `any:`/`all:` values take those same flat forms, so `gems: {all: "devise, pundit"}` is the `gems: {all: [devise, pundit]}` spelling. The list is the only container under a mode key.

Under `any:`, a requirement is a relevance floor: the member counts only from that version, and an unconstrained sibling can still carry the match. Under `all:` every member must be bundled at a satisfying version, and the skip warning names every failing member.

`"*"` anywhere in an `any:` list (or a bare list) makes the artifact universal. Under `all:` a `"*"` member is satisfied by definition and only obscures the real targets, so it is dropped with a warning: `all: [devise, "*"]` gates on `devise` alone, and `all: ["*"]` is simply universal. A requirement on `"*"` is meaningless in any list, so `- "*": ">= 1"` is dropped with a warning too; if it was the only member, the gate resolves universal.

Malformed input takes the usual fail-open path — a map with both mode keys, with neither, or with an unknown key; a member that is a nested list, a multi-pair map, or a pair whose value is not a parsable requirement — is warned about and the artifact installs ungated. A map is read as a mode map or not at all: `gem: {railties: ">= 7.0"}` is malformed, never a name-to-requirement table.

Draw the listed targets from the gem's own `hyperdrive_targets` (below): the gem-level declaration decides whether a companion is suggested at all, and an artifact naming a target the gemspec omits is unreachable for apps that have only that target.

### Version-fencing against rails-hyperdrive

`hyperdrive_version:` is the sanctioned way to require a minimum rails-hyperdrive for a piece of content. Write it at the top level for the whole gem, or in a `skills:`/`guidelines:` entry for one artifact, as a `Gem::Requirement`: one string (comma-separated allowed) or a YAML list of requirement strings.

```yaml
skills:
  turbo-morph:
    gem: [turbo-rails, hotwire-rails]
    hyperdrive_version: ">= 0.7"
```

The fence is matched against the running installer's own version, never against the bundle. That is what makes it a separate key: `gem:` is any-match across its targets, so adding `rails-hyperdrive` to the list would read as "turbo-rails **or** rails-hyperdrive", not "turbo-rails **and** a new enough installer".

An unsatisfied fence skips the artifact — gating working, exactly like a `gem:` gate matching nothing — and reports it, at `hyperdrive:init`/`hyperdrive:sync` and in `bundle install` output:

```
skill 'turbo-morph' (from rails-hyperdrive-turbo) requires rails-hyperdrive >= 0.7 (this is 0.6.0); upgrade rails-hyperdrive to install it
```

The fence is decided before `gem:`, so a fenced-out artifact reports the upgrade and nothing about its targets — including in apps that bundle none of them. Skipped means not installed, not uninstalled: a copy already on disk from an earlier release stays exactly where it is, reported as an orphan.

Resolving the fence first is also what makes it survive gating the installer cannot read. A malformed `gem:`/`gems:` still falls open to an ungated install — but a parseable `hyperdrive_version:` alongside it keeps applying, per entry and gem-wide, where the two default axes fail independently (an unusable default `gem:` never drops a parseable default fence). Fail-open therefore reads "install ungated **unless fenced out**", so a manifest written in a value shape an older installer cannot parse is fenced out of that installer rather than installing everywhere unconstrained. The one exception is the fence being the unparsable part itself: an entry with an unreadable `hyperdrive_version:` installs ungated and unfenced, because inheriting the gem-wide fence would impose a constraint that entry never asked for.

Reach for the fence when content depends on an installer capability (a manifest key, a discovery behavior) rather than on a library in the app. Note what it cannot do: releases predating the key ignore it as an unknown manifest key, so it constrains only installers that understand it, and it has no effect on `hyperdrive:discover`, which is version-blind.

## Gem-conditional skill content

A multi-file skill can condition parts of itself on the app's bundle, so one skill tree serves apps with different gem sets. Both mechanisms are evaluated at discovery time, against the same resolved bundle that gates whole artifacts.

### Per-file gating

A `conditional:` map inside a manifest `skills:` entry gates individual supporting files. Keys are dir-relative shipped paths; values take the same `gem:`/`gems:` forms as the whole-artifact gate (single target, comma-separated string, YAML list with bare or pair members, an `any:`/`all:` map, `"*"`), with the same any-match default. `gem:` is required in each entry. Files the map doesn't mention install unconditionally, and the supporting files themselves stay byte-identical to upstream; the condition lives entirely out of band.

```yaml
skills:
  layered-rails:
    gems:
      - railties: ">= 7.2"
    conditional:
      references/gems/alba.md:
        gem: alba
      references/gems/jobs.md:
        gems:
          - sidekiq: ">= 7.0"
          - solid_queue
```

A malformed condition **fails open**: the file installs unconditionally and the problem is reported with the other discovery warnings. The bias is deliberate: a surplus reference file is harmless, while a missing one breaks links from `SKILL.md`. A key naming no shipped file is warned about and ignored, as is one naming `SKILL.md` itself (the entry's own `gem:` already gates the whole skill). And because the `conditional:` map lives only in the manifest, gating adds nothing to the installed content: gate as extensively as you like.

### ERB-templated markdown

A file named `*.md.erb` in a skill directory is rendered at install time and lands as plain `.md` (the `.erb` suffix is dropped). `SKILL.md.erb` defines a skill exactly like `SKILL.md`; its frontmatter is parsed from the rendered output. Hyperdrive provides three helpers, and they are the only API a template may rely on:

- `gem?("name")` / `gem?("name", ">= 2.0")`: is the gem bundled (at a satisfying version)?
- `any_gem?("a", "b", …)`: is any of these bundled?
- `gem_version("name")`: the resolved version as a String, or `nil`.

Nothing beyond those three is a contract — but nothing is blocked either. A template is plain ERB over an ordinary Ruby binding, not a sandbox: it can reach anything Ruby can, and it runs with the developer's own privileges at discovery time — during `hyperdrive:init`/`hyperdrive:sync`, on every `bundle install` through the bundler plugin, and when the MCP server answers `describe_app`. Enabling a companion trusts its templates exactly like its `lib/` code.

```erb
Use `bundle exec sidekiq` (you run Sidekiq <%= gem_version("sidekiq") || "any version" %>).
<%- if gem?("activejob", ">= 8.0") -%>
Prefer `ActiveJob.perform_all_later` for bulk enqueues.
<%- end -%>
```

Rendering uses ERB's trim mode, so `<%- if gem?("alba") -%>` … `<%- end -%>` control lines leave no blank lines behind. A template that fails to render is skipped with a warning (the whole skill, when it's `SKILL.md.erb`); when a plain file and a template would land at the same path, the plain file wins with a warning. `conditional:` keys refer to templates by their shipped `x.md.erb` name and gate them before rendering. Guidelines get no ERB support.

Use ERB sparingly: condition reference manuals via `conditional:` and wrap link-table rows that point at gated files, but keep "consider adopting gem X" recommendations unconditional. An all-wrapped `.md.erb` renders to an empty file; to omit a file entirely, gate it with `conditional:` instead.

Gated files appear and disappear as the bundle changes: `hyperdrive:init`/`hyperdrive:sync` install newly gated-in files and remove unedited gated-out ones. The auto top-up after `bundle install` adds newly gated-in files but never removes anything and never rewrites an already-installed file, so removals and re-rendered template output wait for the next `hyperdrive:sync`.

## The universal layout: template/content pairing

Generic consumers (`npx skills`, people browsing a git clone) need a static `skills/<name>/SKILL.md` with its supporting files beside it; hyperdrive wants the `SKILL.md.erb` master. Neither file can live in the other's directory: a static `SKILL.md` beside the template would take precedence over it, and raw ERB in `skills/` would be copied verbatim by tools that don't render it. Pairing splits the skill across two directories:

```
skills/<name>/SKILL.md                                  # content dir: generated static face…
skills/<name>/references/…                              # …plus every static supporting file
lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md.erb    # template dir: the master…
lib/<gem_name>/hyperdrive/skills/<name>/references/…    # …plus any supporting *.md.erb templates
```

with gemspec metadata pointing the two roots apart:

```ruby
spec.files = Dir["lib/**/*", "skills/**/*"]
spec.metadata["hyperdrive_skills_dir"] = "skills"
# optional; defaults to the convention path lib/<gem_name>/hyperdrive/skills
spec.metadata["hyperdrive_skill_templates_dir"] = "lib/<gem_name>/hyperdrive/skills"
```

A skill dir holding a static `SKILL.md` pairs with the template dir at the **same relative path** under the templates root (nested layouts like `skills/<category>/<name>/` pair too). The pair is one skill: hyperdrive renders the **template** against the app's bundle and takes the supporting files from the **content dir**. It never reads the static `SKILL.md`, which exists for consumers that can't inspect a bundle. Pairing is strictly opt-in: a content dir with no matching template is an ordinary standalone skill, and so is a template dir with no matching content dir — but only when that template dir sits under a root discovery actually enumerates, namely the convention path (which is also the default templates root), top-level `skills/`, or the `hyperdrive_skills_dir` override. A custom `hyperdrive_skill_templates_dir` is consulted for pairing alone and never enumerated, so a template-only skill placed there is silently dropped; keep standalone template skills under a scanned skills root. A template that fails to render skips the skill (the static file is deliberately not a fallback, because falling back would silently un-condition the skill).

The template dir holds templates and nothing else: `SKILL.md.erb` plus any supporting `*.md.erb`, which render against the app's bundle and install as plain `.md` alongside the rest of the skill. Any other file in it is ignored with a warning — static supporting files are the content dir's to ship. A template-side file **owns** its rendered target path: a same-named file in the content dir never installs, whether the template renders, is gated out by `conditional:`, or fails to render, since falling back to the static face would silently un-condition the file. A supporting `*.md.erb` under a public skills root still renders, but warns and points you at the template dir: generic consumers copy it verbatim and get raw ERB.

### Author-side rake tasks

The static `SKILL.md` is generated, not hand-written. In the companion repo's `Rakefile`:

```ruby
require "rails/hyperdrive/skill_tasks"
```

- `rake hyperdrive:skills:render` renders each `SKILL.md.erb` to its paired static `SKILL.md`, and each supporting `*.md.erb` to its own face in the same content dir, using the **canonical** binding: `gem?`/`any_gem?` always true (even with a version requirement), `gem_version` always `nil`. Templates that interpolate `gem_version` must handle `nil` (e.g. `<%= gem_version("sidekiq") || "(any version)" %>`).
- `rake hyperdrive:skills:check` renders in memory and fails, listing any stale static file; it also fails on any `*.md.erb` found under a public skills root.
- `rake hyperdrive:manifest:check` lints `hyperdrive.yml` where the installer is deliberately permissive, and fails on: unknown keys at every level (top level, `skills:`/`guidelines:` entries, `conditional:` entries), any `gem:`/`gems:`/`hyperdrive_version:` value the installer cannot parse or would only accept with a warning, and entry keys naming nothing the gem ships — with the retired `versions:` and its `version:` near-miss called out by name. A manifest that lints clean draws no gating warning at install time.

Because every predicate reads true in the canonical binding, the render takes the **first** branch: an `if`/`elsif`/`else` chain contributes only its `if` body to the static face, and an `unless gem?(...)` body vanishes from it entirely — and `skills:check` byte-blesses whatever comes out, so nothing catches the loss. Write templates meant for pairing as independent, additive `if gem?(...)` blocks; never wrap a bundle predicate in `else`, `elsif`, or `unless`.

Run both `check` tasks in CI: one keeps the generated face in step with its templates, the other keeps the manifest inside the schema.

All three tasks read the single `*.gemspec` in the working directory (pass an explicit path as a task argument otherwise: `rake "hyperdrive:skills:render[path/to/name.gemspec]"`) and require rails-hyperdrive only as a development dependency, with no Rails app involved. The generated file is the rendered template verbatim; with gating in the manifest, the static face is already the pristine skills.sh view. The two `skills:` tasks are stricter than discovery about their roots: where discovery quietly ignores a `..` segment in `hyperdrive_skills_dir` or `hyperdrive_skill_templates_dir`, they fail on one (`gemspec metadata <key> must not contain '..' segments`).

## Discovery never raises

An artifact with missing or malformed frontmatter, a missing `name:` or `description:`, no manifest-declared target in the bundle, or every bundled target resolving outside its member requirement is skipped, and the reason is collected. `hyperdrive:init` and `hyperdrive:sync` print the collected reasons at the end of the run, under a yellow `warn` line reading `discovery skipped N artifact(s):`. A companion whose artifacts all fail therefore installs nothing and reports it only there. Read that section first when a gem you expected to contribute produces no files.

## Being found by `hyperdrive:discover`

To be discoverable by `hyperdrive:discover` **before** it is installed, a companion also declares gemspec metadata (read remotely from rubygems, so the frontmatter inside the gem isn't visible yet):

```ruby
spec.metadata["hyperdrive_targets"]   = "sidekiq"          # required; comma-sep, or "*" for always-applicable
spec.metadata["hyperdrive_artifacts"] = "guideline,skill"  # optional; presentational hint
```

`hyperdrive_targets` is what makes a gem discoverable: `hyperdrive:discover` searches rubygems for gems declaring it, so a companion is found by what it declares rather than by what it is named. Naming plays no part in discovery: every name is found on the same terms. Still, prefer `rails-hyperdrive-<name>`: the prefix tells a Gemfile reader the gem is agent guidance consumed by rails-hyperdrive, not runtime code.

`hyperdrive_targets` is a coarse pre-install hint, never reconciled against the manifest's `gem:`. It is matched against the app's `Gemfile.lock` by presence alone, ignoring versions; version requirements exist only on the manifest's gate members. It is also a flat any-match list with no way to express `all:`, so a companion whose artifacts are all AND-gated is still suggested to an app holding any one of its declared targets. Once the gem is bundled, the manifest alone governs what installs.
