# Writing a companion gem

rails-hyperdrive is the mechanism; companion gems are the content. This document is the full contract a companion gem ships artifacts under. For the short version — layout, frontmatter, discoverability — see the [README](../README.md#build-a-companion-gem).

## Artifact layout

A companion gem ships artifacts under:

```
<gem-source>/lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md       # skill (dir-per-skill)
<gem-source>/lib/<gem_name>/hyperdrive/guidelines/<name>.md         # guideline (flat file)
```

Skills may ship under an additional root declared in gemspec metadata:

```ruby
spec.metadata["rails_hyperdrive_skills_dir"] = "extra/skills"   # optional; relative to the gem root
```

That root is searched **in addition to** the convention path, never instead of it, so an override never hides skills already shipped at the convention path. A value containing a `..` segment is ignored. Guidelines have no override — they are found only at the convention path.

## Multi-file skills

A skill is a **directory**, and it may ship more than `SKILL.md`. Everything else in the skill directory — nested however you like (`workflows/`, `references/`, `examples/`, …) — installs alongside it as **supporting files**, preserving the relative layout under `.claude/skills/<name>/`. Reference them from `SKILL.md` with directory-relative links; a cross-source name collision renames the whole installed directory, so those links keep working.

Supporting files carry no frontmatter contract — they install byte-identical to the install-ready body, which is what the gem ships (markdown, code, or binary alike) except for `*.md.erb` templates, which install as their rendered output. Each is tracked per file in `.hyperdrive/lock.yml`, so local edits are preserved on sync exactly like any other installed file. `SKILL.md` frontmatter remains the skill's sole schema surface. Guidelines stay single-file.

## Frontmatter

Every artifact carries four required YAML frontmatter fields:

```yaml
---
name: jobs-sidekiq                # kebab-case; determines the install path
description: Background job conventions for Sidekiq.
gem: sidekiq                      # TARGET gem(s), resolved + version-matched in the bundle
versions: ">= 7.0, < 9.0"         # Gem::Requirement matched against the target gem
---
```

`name:` is the artifact's identity, not a label — it is what the installer writes to disk (`.claude/skills/<name>/SKILL.md`, `.claude/hyperdrive/guidelines/<name>.md`). Keep it equal to the file or directory stem: if the two disagree the install still succeeds, but the artifact lands under `name:`. Within one gem, two artifacts of the same type declaring the same `name:` collapse to a single installed file; which one survives is not a guarantee to build on, so give each a distinct `name:`.

`versions:` accepts a single comma-separated string (`">= 7.0, < 9.0"`), a YAML list (`[">= 7.0", "< 9.0"]`), or — for multi-target artifacts — a map keyed by gem name.

`gem:` names the **targets** (each must be present in the bundle; its resolved version is matched against `versions:`). Use `railties` for "every Rails app" or the quoted `"*"` for "always applicable" (it must be quoted — bare `*` is a YAML alias and the file is skipped). `hyperdrive:init` discovers every such file across the bundle, version-matches it, and installs it byte-identical to its install-ready body — provenance (`source`, `sha256`, `installed_at`) is recorded per file in the git-tracked `.hyperdrive/lock.yml`, never inside the installed file. The three installer-only keys — `gem:`, `versions:`, and `conditional:` — are consumed at discovery time and **stripped from the installed file**: a skill keeps its frontmatter minus those keys (so the agent runtime reads only `name:`, `description:`, and whatever else you ship, e.g. `allowed-tools:`), while guidelines are installed with their frontmatter stripped entirely (they are `@`-included eagerly). When two gems ship a same-named artifact, both install, each postfixed by source gem.

### Multiple targets

One artifact can cover several interchangeable libraries — write `gem:` as a comma-separated string or a YAML list, and it installs when **any** listed target is bundled at a satisfying version. `"*"` anywhere in the list makes the artifact universal. Give `versions:` a map keyed by gem name when the targets do not share a version cycle; targets the map omits are unconstrained.

```yaml
---
name: jobs-conventions
description: Background job conventions.
gem: [sidekiq, solid_queue, good_job]
versions:
  sidekiq: ">= 7.0"
  solid_queue: ">= 1.0"
---
```

Draw the listed targets from the gem's own `hyperdrive_targets` (below): the gem-level declaration decides whether a companion is suggested at all, and an artifact naming a target the gemspec omits is unreachable for apps that have only that target.

## Gem-conditional skill content

A multi-file skill can condition parts of itself on the app's bundle, so one skill tree serves apps with different gem sets. Both mechanisms are evaluated at discovery time, against the same resolved bundle that gates whole artifacts.

### Per-file gating

A `conditional:` map in `SKILL.md` frontmatter gates individual supporting files. Keys are dir-relative shipped paths; values take the same `gem:`/`versions:` forms as the artifact-level fields (single target, comma-separated string, YAML list, per-target `versions:` map, `"*"`), and the file installs when **any** listed target is bundled at a satisfying version. Unlike the artifact level, `versions:` is optional here — omitted means unconstrained. Files the map doesn't mention install unconditionally, and the supporting files themselves stay byte-identical to upstream — the condition lives entirely out-of-band.

```yaml
---
name: layered-rails
description: Layered architecture conventions.
gem: railties
versions: ">= 7.2"
conditional:
  references/gems/alba.md:
    gem: alba
  references/gems/jobs.md:
    gem: [sidekiq, solid_queue]
    versions:
      sidekiq: ">= 7.0"
---
```

A malformed condition **fails open**: the file installs unconditionally and the problem is reported with the other discovery warnings — a surplus reference file is harmless, a missing one breaks links from `SKILL.md`. A key naming no shipped file, or naming `SKILL.md` itself (the artifact-level `gem:`/`versions:` gate the whole skill), is warned about and ignored. Like `gem:` and `versions:`, the `conditional:` map never reaches the installed frontmatter — its keys name shipped paths that gating and ERB rendering may leave pointing at files absent from disk, so gate as extensively as you like at no cost to the installed skill.

### ERB-templated markdown

A file named `*.md.erb` in a skill directory — including `SKILL.md.erb` in place of `SKILL.md` — is rendered at install time and lands as plain `.md` (the `.erb` suffix is dropped; a `SKILL.md.erb` defines a skill exactly like `SKILL.md`, with frontmatter read from the rendered output). Templates see a sealed binding of exactly three helpers over the resolved bundle, nothing else:

- `gem?("name")` / `gem?("name", ">= 2.0")` — is the gem bundled (at a satisfying version)?
- `any_gem?("a", "b", …)` — is any of these bundled?
- `gem_version("name")` — the resolved version as a String, or `nil`.

Rendering uses ERB's trim mode, so `<%- if gem?("alba") -%>` … `<%- end -%>` control lines leave no blank lines behind. A template that fails to render is skipped with a warning (the whole skill, when it's `SKILL.md.erb`); when a plain file and a template would land at the same path, the plain file wins with a warning. `conditional:` keys refer to templates by their shipped `x.md.erb` name and gate them before rendering. Guidelines get no ERB support.

Use ERB sparingly — condition reference manuals via `conditional:` and wrap link-table rows that point at gated files, but keep "consider adopting gem X" recommendations unconditional. An all-wrapped `.md.erb` renders to an empty file; to omit a file entirely, gate it with `conditional:` instead.

Gated files appear and disappear as the bundle changes: `hyperdrive:init`/`hyperdrive:sync` install newly gated-in files and remove unedited gated-out ones. The auto top-up after `bundle install` adds newly gated-in files but never removes anything and never rewrites an already-installed file, so removals and re-rendered template output wait for the next `hyperdrive:sync`.

## The universal layout: template/content pairing

Conditional content and the universal skills convention pull in opposite directions: tools like `npx skills` (and people browsing a git clone) expect a static `skills/<name>/SKILL.md` with its supporting files in the same directory, while hyperdrive wants the `SKILL.md.erb` master. Neither can live in the other's directory — a static `SKILL.md` beside the template would take precedence over it, and a `SKILL.md.erb` in the static dir would be copied verbatim by tools that don't render it.

Pairing splits the skill across two directories:

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

A skill dir holding a static `SKILL.md` pairs with the template dir at the **same relative path** under the templates root (nested layouts like `skills/<category>/<name>/` pair too). The pair is one skill: hyperdrive renders the **template** against the app's bundle and takes the supporting files from the **content dir**; the static `SKILL.md` is never read by hyperdrive — it exists for consumers that can't inspect a bundle. A template dir with no matching content dir, or a content dir with no matching template, is a standalone skill exactly as before, so pairing is strictly opt-in. Keep the template dir down to `SKILL.md.erb` alone: anything else in it is ignored with a warning — the content dir is the single source of truth for supporting files. A template that fails to render skips the skill (the static file is deliberately not used as a fallback — that would silently un-condition the skill).

### Generating and checking the static face

The static `SKILL.md` is generated, not hand-written. In the companion repo's `Rakefile`:

```ruby
require "rails/hyperdrive/skill_tasks"
```

- `rake hyperdrive:skills:render` — renders each `SKILL.md.erb` to its paired static `SKILL.md` using the **canonical** binding: `gem?`/`any_gem?` always true (even with a version requirement), `gem_version` always `nil` — the fail-open, everything-included face for consumers whose bundle can't be inspected. Templates that interpolate `gem_version` must handle `nil` (e.g. `<%= gem_version("sidekiq") || "(any version)" %>`).
- `rake hyperdrive:skills:check` — renders in memory and fails listing any stale static file; run it in CI so the generated face never drifts from its template.

Both read the single `*.gemspec` in the working directory (pass an explicit path as a task argument otherwise: `rake "hyperdrive:skills:render[path/to/name.gemspec]"`) and require rails-hyperdrive only as a development dependency — no Rails app involved. The generated file keeps the `gem:`/`versions:`/`conditional:` frontmatter keys on purpose: older rails-hyperdrive versions that don't know about pairing fall back to installing the static artifact, and the kept keys let them gate it normally (skill-consuming tools ignore unknown frontmatter keys).

## Discovery never raises

An artifact with missing or malformed frontmatter, a missing required field, no declared target in the bundle, or every bundled target resolving outside `versions:` is skipped, and the reason is collected. `hyperdrive:init` and `hyperdrive:sync` print the collected reasons at the end of the run, under a yellow `warn` line reading `discovery skipped N artifact(s):`. A companion whose artifacts all fail therefore installs nothing and reports it only there — read that section first when a gem you expected to contribute produces no files.

## Being found by `hyperdrive:discover`

To be discoverable by `hyperdrive:discover` **before** it is installed, a companion also declares gemspec metadata (read remotely from rubygems, so the frontmatter inside the gem isn't visible yet):

```ruby
spec.metadata["rails_hyperdrive_targets"]   = "sidekiq"          # required; comma-sep, or "*" for always-applicable
spec.metadata["rails_hyperdrive_artifacts"] = "guideline,skill"  # optional; presentational hint
```

`rails_hyperdrive_targets` is what makes a gem discoverable: `hyperdrive:discover` searches rubygems for gems declaring it, so a companion is found by what it declares rather than by what it is named. Naming it `rails-hyperdrive-<library>` is a recommended convention — it makes the gem legible in a Gemfile — but it plays no part in discovery, and a companion published under your own namespace is found on the same terms.

`rails_hyperdrive_targets` is a coarse pre-install hint — it is never reconciled against the frontmatter `gem:`; once the gem is bundled, the frontmatter alone governs what installs.
