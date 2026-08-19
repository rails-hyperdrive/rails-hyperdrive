# Writing a companion gem

rails-hyperdrive is the mechanism; companion gems are the content. This document is the full contract a companion gem ships artifacts under. For the short version (layout, frontmatter, discoverability), see the [README](../README.md#build-a-companion-gem).

## Artifact layout

A companion gem ships artifacts under:

```
<gem-source>/skills/<name>/SKILL.md                                 # skill (dir-per-skill) — recommended, the gem's public face
<gem-source>/lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md       # skill — hyperdrive-specific root, also scanned
<gem-source>/lib/<gem_name>/hyperdrive/guidelines/<name>.md         # guideline (flat file)
```

Top-level `skills/` is the recommended home for skill content: it is the public, tool-agnostic face of the gem, matching what [skills.sh](https://www.skills.sh) and plain git-clone consumers expect, and it is scanned by default; no metadata key is needed. `lib/<gem_name>/hyperdrive/` is the hyperdrive-specific root: it holds guidelines and is the default home for ERB skill templates (`SKILL.md.erb` must stay here, so raw ERB never reaches generic `skills/` consumers). Plain static skills shipped under it remain scanned indefinitely, so published companions keep working unchanged; prefer top-level `skills/` for new ones.

### The companion opt-in gate

Discovery walks the entire bundle, and many gemspecs package files via `git ls-files`, so an ordinary non-companion gem can ship a contributor-facing `skills/` directory by accident. A gem's artifacts are therefore only scanned when one of two things is true:

- the gem itself carries hyperdrive-specific configuration: artifacts under the `lib/<gem_name>/hyperdrive/` convention path, a `hyperdrive.yml` manifest at the gem root (below), or any `rails_hyperdrive_*` gemspec metadata key, or
- the app names the gem in the `enabled:` list of `.hyperdrive/lock.yml`.

An un-opted gem shipping `skills/*/SKILL.md` never auto-installs: `hyperdrive:init`/`hyperdrive:sync` surface it with a pointer to the `enabled:` list instead.

Skills may also ship under an additional root declared in gemspec metadata:

```ruby
spec.metadata["rails_hyperdrive_skills_dir"] = "extra/skills"   # optional; relative to the gem root
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

## The gem-root manifest

Gating (which bundles an artifact installs into) is declared in a `hyperdrive.yml` at the gem root, or at the path named by a `rails_hyperdrive_manifest` gemspec metadata key (relative to the gem root; a value containing `..` segments, or a blank value, falls back to the conventional path). Every key is optional, and no manifest (or an empty one) means every artifact installs universally:

```yaml
gem: railties            # gem-wide default TARGET gem(s): string, comma-separated string, or YAML list; "*" universal
versions: ">= 7.2"       # gem-wide default Gem::Requirement: one string, a list, or a map keyed by gem name
skills:                  # per-skill entries, keyed by the skill dir's path relative to its skills root
  layered-rails:
    gem: railties
    versions: ">= 8.0"
    conditional:         # per-file supporting-file gating — see below
      references/gems/alba.md: { gem: alba }
guidelines:              # per-guideline entries, keyed by filename (extension included)
  jobs.md:
    gem: sidekiq
```

Entries are keyed by path, never by the skill's `name:`: a skill entry's key is the skill directory's path relative to its skills root (for a template/content-paired skill, the content dir's path), and a guideline entry's key is its filename. Resolution is per artifact:

- **`gem`**: the entry's own value when its key is present, else the top-level default, else `"*"` (ungated). A per-entry `gem: "*"` therefore un-gates an artifact against a gem-wide default.
- **`versions`**: same lookup (entry, then top-level, else unconstrained), so a top-level `versions:` also applies to an entry that names a different `gem:` and omits `versions:`.

`gem:` names the **targets**: each must be present in the bundle, its resolved version matched against `versions:`. Use `railties` for "every Rails app" or `"*"` for "always applicable". A well-formed gate matching nothing in the bundle skips the artifact with a warning; that is gating working. Malformed gating, by contrast, never skips an artifact:

- an unreadable or non-map manifest is warned about and treated as absent;
- a non-map `skills:`/`guidelines:` section is warned about and ignored;
- a malformed entry (non-map value, unusable `gem:`, unparsable `versions:`) is warned about and the artifact installs **ungated** (the gem-wide defaults are not applied either);
- an entry whose key matches no shipped skill directory or guideline is warned about and ignored; this is the staleness signal when a skill dir is renamed out from under its gating.

### Multiple targets

One artifact can cover several interchangeable libraries: write `gem:` as a comma-separated string or a YAML list, and it installs when **any** listed target is bundled at a satisfying version. `"*"` anywhere in the list makes the artifact universal. Give `versions:` a map keyed by gem name when the targets do not share a version cycle; targets the map omits are unconstrained.

```yaml
skills:
  jobs-conventions:
    gem: [sidekiq, solid_queue, good_job]
    versions:
      sidekiq: ">= 7.0"
      solid_queue: ">= 1.0"
```

Draw the listed targets from the gem's own `hyperdrive_targets` (below): the gem-level declaration decides whether a companion is suggested at all, and an artifact naming a target the gemspec omits is unreachable for apps that have only that target.

## Gem-conditional skill content

A multi-file skill can condition parts of itself on the app's bundle, so one skill tree serves apps with different gem sets. Both mechanisms are evaluated at discovery time, against the same resolved bundle that gates whole artifacts.

### Per-file gating

A `conditional:` map inside a manifest `skills:` entry gates individual supporting files. Keys are dir-relative shipped paths; values take the same `gem:`/`versions:` forms as the whole-artifact gate (single target, comma-separated string, YAML list, per-target `versions:` map, `"*"`), and the file installs when **any** listed target is bundled at a satisfying version. `versions:` is optional (omitted means unconstrained), though `gem:` is required in each entry. Files the map doesn't mention install unconditionally, and the supporting files themselves stay byte-identical to upstream; the condition lives entirely out of band.

```yaml
skills:
  layered-rails:
    gem: railties
    versions: ">= 7.2"
    conditional:
      references/gems/alba.md:
        gem: alba
      references/gems/jobs.md:
        gem: [sidekiq, solid_queue]
        versions:
          sidekiq: ">= 7.0"
```

A malformed condition **fails open**: the file installs unconditionally and the problem is reported with the other discovery warnings. The bias is deliberate: a surplus reference file is harmless, while a missing one breaks links from `SKILL.md`. A key naming no shipped file is warned about and ignored, as is one naming `SKILL.md` itself (the entry's own `gem:`/`versions:` already gate the whole skill). And because the `conditional:` map lives only in the manifest, gating adds nothing to the installed content: gate as extensively as you like.

### ERB-templated markdown

A file named `*.md.erb` in a skill directory is rendered at install time and lands as plain `.md` (the `.erb` suffix is dropped). `SKILL.md.erb` defines a skill exactly like `SKILL.md`; its frontmatter is parsed from the rendered output. Templates can call exactly three helpers; no other Ruby context is available:

- `gem?("name")` / `gem?("name", ">= 2.0")`: is the gem bundled (at a satisfying version)?
- `any_gem?("a", "b", …)`: is any of these bundled?
- `gem_version("name")`: the resolved version as a String, or `nil`.

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
skills/<name>/SKILL.md                            # content dir: generated static face…
skills/<name>/references/…                        # …plus ALL supporting files
lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md.erb   # template dir: the master, and nothing else
```

with gemspec metadata pointing the two roots apart:

```ruby
spec.files = Dir["lib/**/*", "skills/**/*"]
spec.metadata["rails_hyperdrive_skills_dir"] = "skills"
# optional; defaults to the convention path lib/<gem_name>/hyperdrive/skills
spec.metadata["rails_hyperdrive_skill_templates_dir"] = "lib/<gem_name>/hyperdrive/skills"
```

A skill dir holding a static `SKILL.md` pairs with the template dir at the **same relative path** under the templates root (nested layouts like `skills/<category>/<name>/` pair too). The pair is one skill: hyperdrive renders the **template** against the app's bundle and takes the supporting files from the **content dir**. It never reads the static `SKILL.md`, which exists for consumers that can't inspect a bundle. A template dir with no matching content dir, or a content dir with no matching template, is an ordinary standalone skill, so pairing is strictly opt-in. Keep the template dir down to `SKILL.md.erb` alone: anything else in it is ignored with a warning, since the content dir is the single source of truth for supporting files. A template that fails to render skips the skill (the static file is deliberately not a fallback, because falling back would silently un-condition the skill).

### Generating and checking the static face

The static `SKILL.md` is generated, not hand-written. In the companion repo's `Rakefile`:

```ruby
require "rails/hyperdrive/skill_tasks"
```

- `rake hyperdrive:skills:render` renders each `SKILL.md.erb` to its paired static `SKILL.md` using the **canonical** binding: `gem?`/`any_gem?` always true (even with a version requirement), `gem_version` always `nil`. That is the fail-open, everything-included face for consumers whose bundle can't be inspected. Templates that interpolate `gem_version` must handle `nil` (e.g. `<%= gem_version("sidekiq") || "(any version)" %>`).
- `rake hyperdrive:skills:check` renders in memory and fails, listing any stale static file. Run it in CI so the generated face never drifts from its template.

Both read the single `*.gemspec` in the working directory (pass an explicit path as a task argument otherwise: `rake "hyperdrive:skills:render[path/to/name.gemspec]"`) and require rails-hyperdrive only as a development dependency, with no Rails app involved. The generated file is the rendered template verbatim; with gating in the manifest, the static face is already the pristine skills.sh view. Template-using companions require the rails-hyperdrive release that ships pairing. Unlike discovery, which quietly ignores a `..` segment in `rails_hyperdrive_skills_dir` or `rails_hyperdrive_skill_templates_dir`, these tasks fail on one (`gemspec metadata <key> must not contain '..' segments`).

## Discovery never raises

An artifact with missing or malformed frontmatter, a missing `name:` or `description:`, no manifest-declared target in the bundle, or every bundled target resolving outside `versions:` is skipped, and the reason is collected. `hyperdrive:init` and `hyperdrive:sync` print the collected reasons at the end of the run, under a yellow `warn` line reading `discovery skipped N artifact(s):`. A companion whose artifacts all fail therefore installs nothing and reports it only there. Read that section first when a gem you expected to contribute produces no files.

## Being found by `hyperdrive:discover`

To be discoverable by `hyperdrive:discover` **before** it is installed, a companion also declares gemspec metadata (read remotely from rubygems, so the frontmatter inside the gem isn't visible yet):

```ruby
spec.metadata["rails_hyperdrive_targets"]   = "sidekiq"          # required; comma-sep, or "*" for always-applicable
spec.metadata["rails_hyperdrive_artifacts"] = "guideline,skill"  # optional; presentational hint
```

`rails_hyperdrive_targets` is what makes a gem discoverable: `hyperdrive:discover` searches rubygems for gems declaring it, so a companion is found by what it declares rather than by what it is named. Naming plays no part in discovery: every name is found on the same terms. Still, prefer `rails-hyperdrive-<name>`: the prefix tells a Gemfile reader the gem is agent guidance consumed by rails-hyperdrive, not runtime code.

`rails_hyperdrive_targets` is a coarse pre-install hint, never reconciled against the manifest's `gem:`. It is matched against the app's `Gemfile.lock` by presence alone, ignoring versions; `versions:` constraints exist only in the manifest. Once the gem is bundled, the manifest alone governs what installs.
