<p align="center">
  <img src="https://raw.githubusercontent.com/rails-hyperdrive/rails-hyperdrive/main/docs/logo-wide.png" alt="" width="480">
</p>

# Rails Hyperdrive

**Live introspection and stack-matched knowledge for AI coding agents, straight from your Rails app.**

[![Gem Version](https://img.shields.io/gem/v/rails-hyperdrive)](https://rubygems.org/gems/rails-hyperdrive)
[![CI](https://github.com/rails-hyperdrive/rails-hyperdrive/actions/workflows/ci.yml/badge.svg)](https://github.com/rails-hyperdrive/rails-hyperdrive/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

Rails Hyperdrive is a development-only Rails engine for working on Rails apps with AI coding agents. It gives the agent two things it can't get from source alone — live answers from the booted app, and guidance specific to the gems and versions in the bundle:

- **Live introspection.** The engine mounts an [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server at `http://localhost:3000/_hyperdrive/mcp` with **8 tools** that answer from the running app itself: eval Ruby, query the DB (read-only), tail logs, list models and routes, jump to source, look up docs, snapshot the stack. The agent asks the router instead of grepping `routes.rb`, and reads the live schema instead of replaying migrations.
- **Stack-specific knowledge.** `bin/rails hyperdrive:init` discovers **skills** and **guidelines** shipped by companion gems and installs only the ones matching your Gemfile: guidance targeting Sidekiq, for example, lands only if your app bundles Sidekiq, at a version the guidance covers.

**rails-hyperdrive is the mechanism; companion gems are the content.** The gem itself ships no skills or guidelines — only the contract and the discovery/install engine. Content comes from companion gems, conventionally named `rails-hyperdrive-<library>` (e.g. `rails-hyperdrive-sidekiq`), following the [RuboCop ecosystem](https://github.com/rubocop/rubocop) precedent.

---

## Quick start

```bash
# 1. Add the dev gem
$ bundle add rails-hyperdrive --group=development

# 2. (Optional) Add a companion gem for your stack
$ bundle add rails-hyperdrive-sidekiq --group=development

# 3. Run the generator
$ bin/rails hyperdrive:init

  create  .mcp.json
  insert  config/routes.rb
  create  .claude/hyperdrive/guidelines/jobs-sidekiq.md
  create  .claude/skills/sidekiq-idempotency/SKILL.md
  create  .claude/hyperdrive/index.md
  create  CLAUDE.md
  create  .hyperdrive/lock.yml
   eager  1 guideline(s), ~240 tokens always in context

    done  hyperdrive initialized
  Mount: /_hyperdrive (in config/routes.rb)
  Server: 8 MCP tools at http://localhost:3000/_hyperdrive/mcp
  Installed 1 skill, 1 guideline

    rails-hyperdrive-sidekiq@1.2.0
      skill      sidekiq-idempotency
      guideline  jobs-sidekiq

# 4. Start the dev server
$ bin/dev

# 5. Open Claude Code in the project directory
# → Claude Code reads .mcp.json, connects to http://localhost:3000/_hyperdrive/mcp
# → agent has 8 tools, the eager guidelines (via CLAUDE.md), and the lazy skills
```

That's it. No API keys, no config files to write, no per-project setup beyond the generator.

---

## What your agent gets

### 8 MCP tools

| # | Tool | Purpose |
|---|------|---------|
| 1 | `run_ruby` | Eval Ruby in the booted Rails process, with timeout + output capture |
| 2 | `run_sql` | Read-only SQL via the AR connection (refuses non-SELECT) |
| 3 | `tail_logs` | Tail the last N lines of a log under `log/` (defaults to `log/<env>.log`) |
| 4 | `list_models` | List Active Record model classes with columns/validations/associations |
| 5 | `locate_source` | Resolve `Const` / `Const#method` / `Const.method` / `dep:<gem>` to a file:line |
| 6 | `lookup_doc` | Look up RDoc for a symbol (via `ri`) |
| 7 | `describe_app` | Snapshot: Rails/Ruby/DB versions + full stack profile |
| 8 | `list_routes` | All routes: HTTP verb, path, controller#action, named route |

Plus two MCP resources: `hyperdrive://stack-profile` (JSON snapshot of your resolved stack) and `hyperdrive://skills/{name}` (the markdown body of each installed skill).

### Two kinds of knowledge

Companion gems ship two artifact types, tuned for how agents consume context:

- **Skills** — *lazy*. Loaded on demand via Claude Code's native description matcher. Procedural knowledge: "how to write an idempotent Sidekiq job". Installed to `.claude/skills/<name>/SKILL.md`, optionally with supporting files (references, examples, workflows) alongside.
- **Guidelines** — *eager*. Always in context via a single `@`-include from `CLAUDE.md`. Declarative facts: "this app uses ActionPolicy, not Pundit". Installed to `.claude/hyperdrive/guidelines/<name>.md`.

Every artifact declares which gem it targets and at which versions, so what installs is exactly what matches your `Gemfile.lock` — nothing generic, nothing stale.

With no companion gems, `hyperdrive:init` sets up just the server plumbing (`.mcp.json`, the engine mount, the lockfile) and puts **nothing** into your agent's context window. Zero context cost until you opt in.

---

## Staying in sync

**After `bundle install` — automatic.** `hyperdrive:init` registers the [`bundler-rails-hyperdrive`](bundler-rails-hyperdrive/) Bundler plugin in your Gemfile. From then on, `bundle add rails-hyperdrive-<library>` lands the companion's artifacts on that very `bundle install` — no extra command. The plugin is additive only (it never touches an existing file); version bumps and orphaned artifacts are only reported, with a pointer to `hyperdrive:sync`.

**`bin/rails hyperdrive:sync` — on demand.** Run it any time (e.g. after `bundle update`) to refresh installed content to the current bundle. It touches no bootstrap artifact and leaves locally-modified files untouched (skip + warn); pass `--overwrite` to restore them to the gem-shipped content.

**`bin/rails hyperdrive:discover` — find what you're missing.** Queries rubygems for companion gems published for your stack that you haven't installed yet, and prints the `bundle add` lines to run. Read-only, results cached for 24h (`--refresh` re-queries), and it never touches your Gemfile or makes network calls unless you invoke it.

---

## You stay in charge

### Everything lands git-tracked

```
CLAUDE.md                              # user-owned; ONE injected line: @.claude/hyperdrive/index.md
.claude/hyperdrive/
  index.md                             # managed aggregator: @guidelines/<name>.md
  guidelines/<name>.md                 # companion-shipped, frontmatter stripped, audit-headered
.claude/skills/<name>/
  SKILL.md                             # companion-shipped, frontmatter kept minus installer keys, audit-headered
  <supporting files>                   # optional companion-shipped extras, installed as shipped (*.md.erb rendered)
.hyperdrive/lock.yml                   # git-tracked manifest (source gem, version, content hash)
```

A `git diff` is where you review what a companion gem added. The install summary names each artifact's source gem and version, every SKILL.md and guideline carries the same provenance in an audit header, and supporting files are hashed per file in `.hyperdrive/lock.yml`. `hyperdrive:init` warns if your app gitignores these paths, since that empties the diff without changing what reaches the agent. The `hyperdrive:discover` cache is the one file rails-hyperdrive adds to `.gitignore`.

`CLAUDE.md` and `index.md` are the **eager chain** — they exist only because a companion gem ships a guideline, and both go when the last one leaves the bundle (the guideline file itself is left on disk and reported as an orphan).

### Your edits win

Installed files are yours to modify. The lockfile hash tells the installer whether a file is still gem-pristine: unedited files are refreshed on upgrade, edited files are skipped with a warning — never silently overwritten. `hyperdrive:sync --overwrite` is the explicit way back to gem-shipped content.

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

To skip installed content wholesale instead, pass `--skip-content` to `hyperdrive:init`.

---

## Safety

Rails Hyperdrive is **dev-only**, enforced in depth: the engine refuses to handle requests outside `Rails.env.development?`, enforces an origin allowlist (`localhost`, `127.0.0.1`, `[::1]`), and every tool re-checks the dev guard on invocation. `run_sql` accepts read-only statements and refuses anything else. See [SECURITY.md](SECURITY.md).

---

## Build a companion gem

Ship markdown at a convention path, declare what it targets, publish. That's the whole contract:

```
lib/<gem_name>/hyperdrive/skills/<name>/SKILL.md       # skill (dir-per-skill, may ship supporting files)
lib/<gem_name>/hyperdrive/guidelines/<name>.md         # guideline (flat file)
```

```yaml
---
name: jobs-sidekiq                # kebab-case; determines the install path
description: Background job conventions for Sidekiq.
gem: sidekiq                      # TARGET gem(s), resolved + version-matched in the bundle
versions: ">= 7.0, < 9.0"         # Gem::Requirement matched against the target gem
---
```

And to be suggested by `hyperdrive:discover` before anyone installs you:

```ruby
spec.metadata["rails_hyperdrive_targets"] = "sidekiq"
```

The full contract — multi-target artifacts, multi-file skills, per-file gem gating, ERB-templated content, collision and dedup rules — lives in [docs/COMPANION_GEMS.md](docs/COMPANION_GEMS.md).

---

## Requirements

Ruby ≥ 3.2, Rails ≥ 7.2. Tested against Rails 7.2 and 8.1 on Ruby 3.2–3.4.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
