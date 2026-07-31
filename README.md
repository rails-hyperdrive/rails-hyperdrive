# Rails Hyperdrive

> Dev-only Rails engine that bootstraps an MCP server + skills/guidelines for AI coding agents (Claude Code first).

Rails Hyperdrive mounts an [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server at `http://localhost:3000/_hyperdrive/mcp` in development, exposing **8 introspection tools** so AI agents stop guessing — they can eval Ruby, query the DB (read-only), tail logs, list models and routes, locate source, fetch docs, and snapshot the stack.

It also ships a `hyperdrive:init` generator that discovers and installs **two artifact types** that companion gems ship under a documented contract:

- **Skills** — lazy, model-invoked via Claude Code's native description matcher. Procedural ("how to write an idempotent Sidekiq job"). Installed to `.claude/skills/<name>/SKILL.md`.
- **Guidelines** — eager, always in context via `@`-include from `CLAUDE.md`. Declarative ("this app uses Pundit, not CanCanCan"). Installed to `.claude/hyperdrive/guidelines/<name>.md`.

**rails-hyperdrive is the mechanism; companion gems are the content.** rails-hyperdrive itself ships no skills or guidelines — only the contract, the discovery/install engine, and a generated `stack.md`. Content comes from companion gems, conventionally named `rails-hyperdrive-<library>` (e.g. `rails-hyperdrive-sidekiq`) following the [RuboCop ecosystem](https://github.com/rubocop/rubocop) precedent.

Built on the official [`mcp` gem](https://github.com/modelcontextprotocol/ruby-sdk). MIT-licensed.

---

## Golden path

```bash
# 1. Add the dev gem
$ bundle add rails-hyperdrive --group=development

# 2. (Optional) Add a companion gem for your stack
$ bundle add rails-hyperdrive-sidekiq --group=development

# 3. Run the generator
$ bin/rails hyperdrive:init

  create  .mcp.json
  insert  config/routes.rb
  create  .claude/hyperdrive/stack.md
  create  .claude/hyperdrive/guidelines/jobs-sidekiq.md
  create  .claude/skills/sidekiq-idempotency/SKILL.md
  create  .claude/hyperdrive/index.md
  create  CLAUDE.md
  create  .hyperdrive/lock.yml
   eager  1 guideline(s) + stack.md, ~420 tokens always in context

    done  hyperdrive initialized
  Mount: /_hyperdrive (in config/routes.rb)
  Installed 1 skill, 1 guideline + stack.md

    rails-hyperdrive-sidekiq@1.2.0
      skill      sidekiq-idempotency
      guideline  jobs-sidekiq
    internal@0.2.0
      stack      stack.md

# 4. Start the dev server
$ bin/dev

# 5. Open Claude Code in the project directory
# → Claude Code reads .mcp.json, connects to http://localhost:3000/_hyperdrive/mcp
# → agent has 8 tools, the eager guidelines (via CLAUDE.md), and the lazy skills
```

Run `bin/rails hyperdrive:sync` any time (e.g. after `bundle update` or adding a companion gem) to refresh installed content to the current bundle. It touches no bootstrap artifact and leaves locally-modified files untouched (skip + warn); pass `--overwrite` to restore them to the gem-shipped content.

Run `hyperdrive:discover` to find companion gems published for your stack that you haven't installed yet — it queries rubygems (read-only, results cached for 24h; `--refresh` re-queries) and prints the `bundle add` lines to run, then run `bin/rails hyperdrive:sync`. It never touches your Gemfile or makes network calls unless you invoke it.

---

## What ships

### MCP tools (8)

| # | Tool | Purpose |
|---|------|---------|
| 1 | `run_ruby` | Eval Ruby in the booted Rails process, with timeout + output capture |
| 2 | `run_sql` | Read-only SQL via the AR connection (refuses non-SELECT) |
| 3 | `tail_logs` | Tail the last N lines of a log under `log/` (defaults to `log/<env>.log`) |
| 4 | `list_models` | List Active Record model classes with columns/validations/associations |
| 5 | `locate_source` | Resolve `Const` / `Const#method` / `Const.method` / `dep:<gem>` to a file:line |
| 6 | `lookup_doc` | Look up RDoc for a symbol (via `ri`) |
| 7 | `describe_app` | Snapshot: Rails/Ruby/DB versions + full `StackProfile` |
| 8 | `list_routes` | All routes: HTTP verb, path, controller#action, named route |

### Resources

- `hyperdrive://stack-profile` — JSON of the resolved `StackProfile`
- `hyperdrive://skills/{name}` — markdown body of each installed skill

### Generated content

rails-hyperdrive generates exactly one content file itself — `.claude/hyperdrive/stack.md`, a guideline derived from your `Gemfile.lock` (stack facts + steering + how to use the MCP tools). Everything else under `.claude/` comes from companion gems.

### Install layout

```
CLAUDE.md                              # user-owned; ONE injected line: @.claude/hyperdrive/index.md
.claude/hyperdrive/
  index.md                             # managed aggregator: @stack.md + @guidelines/<name>.md
  stack.md                             # rails-hyperdrive-generated stack guideline
  guidelines/<name>.md                 # companion-shipped, frontmatter stripped, audit-headered
.claude/skills/<name>/
  SKILL.md                             # companion-shipped, frontmatter kept, audit-headered
  <supporting files>                   # optional companion-shipped extras, installed byte-identical
.hyperdrive/lock.yml                   # git-tracked manifest (source gem, version, content hash)
```

Everything a companion gem contributes lands here git-tracked, so a diff is where you review what it added — the install summary names each artifact's source gem and version, and every SKILL.md, guideline, and `stack.md` carries the same provenance in an audit header. A skill's supporting files carry no header — they install byte-identical to what the gem ships, and their provenance and content hash live in `.hyperdrive/lock.yml` alone. `hyperdrive:init` warns if your app gitignores these paths, since that empties the diff without changing what reaches the agent. The `hyperdrive:discover` cache is the one file rails-hyperdrive adds to `.gitignore`.

### Turning off a single artifact

A companion gem you want for one skill but not another doesn't have to be all-or-nothing. Add the artifact's name to the `disabled:` list in `.hyperdrive/lock.yml` — it is written empty on every install, so the shape is already there:

```yaml
disabled:
  skills:
    - sidekiq-idempotency
  guidelines:
    - jobs-sidekiq
```

A disabled artifact is never installed, and one already on disk is removed on the next `hyperdrive:init` or `hyperdrive:sync` — but only if you haven't edited it. A locally-modified file is reported and left alone, for you to delete when you're ready. Disabling a skill removes its shipped supporting files under the same per-file rule; files you created yourself in the skill directory survive and keep the directory alive. Disabling a guideline also drops its line from `index.md`, so it leaves eager context along with the file.

The list is yours to edit; the generator only reads it and carries it forward. Delete a name to get the artifact back on the next run. When two companion gems ship the same artifact name, both install under a `<name>--<source-gem>` suffix — the plain name disables both, the suffixed name disables one.

To skip installed content wholesale instead, pass `--skip-content`.

### Companion gem contract

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

A skill is a **directory**, and it may ship more than `SKILL.md`. Everything else in the skill directory — nested however you like (`workflows/`, `references/`, `examples/`, …) — installs alongside it as **supporting files**, preserving the relative layout under `.claude/skills/<name>/`. Reference them from `SKILL.md` with directory-relative links; a cross-source name collision renames the whole installed directory, so those links keep working. Supporting files carry no frontmatter contract and no audit header — they install byte-identical to what the gem ships (markdown, code, or binary alike), and each is tracked per file in `.hyperdrive/lock.yml`, so local edits are preserved on sync exactly like any other installed file. `SKILL.md` frontmatter remains the skill's sole schema surface. Guidelines stay single-file.

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

`gem:` names the **targets** (each must be present in the bundle; its resolved version is matched against `versions:`). Use `railties` for "every Rails app" or the quoted `"*"` for "always applicable" (it must be quoted — bare `*` is a YAML alias and the file is skipped). `hyperdrive:init` discovers every such file across the bundle, version-matches it, and installs it with an audit header naming `source`, `sha256`, and `installed_at`. Guidelines are installed with their frontmatter stripped (they are `@`-included eagerly). When two gems ship a same-named artifact, both install, each postfixed by source gem.

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

Discovery never raises. An artifact with missing or malformed frontmatter, a missing required field, no declared target in the bundle, or every bundled target resolving outside `versions:` is skipped, and the reason is collected. `hyperdrive:init` and `hyperdrive:sync` print the collected reasons at the end of the run, under a yellow `warn` line reading `discovery skipped N artifact(s):`. A companion whose artifacts all fail therefore installs nothing and reports it only there — read that section first when a gem you expected to contribute produces no files.

To be discoverable by `hyperdrive:discover` **before** it is installed, a companion also declares gemspec metadata (read remotely from rubygems, so the frontmatter inside the gem isn't visible yet):

```ruby
spec.metadata["rails_hyperdrive_targets"]   = "sidekiq"          # required; comma-sep, or "*" for always-applicable
spec.metadata["rails_hyperdrive_artifacts"] = "guideline,skill"  # optional; presentational hint
```

`rails_hyperdrive_targets` is what makes a gem discoverable: `hyperdrive:discover` searches rubygems for gems declaring it, so a companion is found by what it declares rather than by what it is named. Naming it `rails-hyperdrive-<library>` is a recommended convention — it makes the gem legible in a Gemfile — but it plays no part in discovery, and a companion published under your own namespace is found on the same terms.

`rails_hyperdrive_targets` is a coarse pre-install hint — it is never reconciled against the frontmatter `gem:`; once the gem is bundled, the frontmatter alone governs what installs.

---

## Safety

Rails Hyperdrive is **dev-only**. The engine refuses to handle requests outside `Rails.env.development?` and enforces an origin allowlist (`localhost`, `127.0.0.1`, `[::1]`). See [SECURITY.md](SECURITY.md).

---

## License

MIT — see [LICENSE.txt](LICENSE.txt).
