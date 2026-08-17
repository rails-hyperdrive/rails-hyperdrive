<p align="center">
  <img src="https://raw.githubusercontent.com/rails-hyperdrive/rails-hyperdrive/main/docs/logo-wide.png" alt="" width="480">
</p>

# Rails Hyperdrive

**Live introspection and stack-matched knowledge for AI coding agents, straight from your Rails app.**

[![Gem Version](https://img.shields.io/gem/v/rails-hyperdrive)](https://rubygems.org/gems/rails-hyperdrive)
[![CI](https://github.com/rails-hyperdrive/rails-hyperdrive/actions/workflows/ci.yml/badge.svg)](https://github.com/rails-hyperdrive/rails-hyperdrive/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

Rails Hyperdrive is a development-only Rails engine for working on Rails apps with AI coding agents. It gives the agent two things it can't get from source alone: live answers from the booted app, and guidance specific to the gems and versions in the bundle.

- **Live introspection.** The engine mounts an [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server at `http://localhost:3000/_hyperdrive/mcp` with **8 tools** that answer from the running app itself: eval Ruby, query the DB (read-only), tail logs, list models and routes, jump to source, look up docs, snapshot the stack. The agent asks the router instead of grepping `routes.rb`, and reads the live schema instead of replaying migrations.
- **Stack-specific knowledge.** `bin/rails hyperdrive:init` discovers **skills** and **guidelines** shipped by companion gems and installs only the ones matching your Gemfile: guidance targeting Sidekiq, for example, lands only if your app bundles Sidekiq, at a version the guidance covers.

**rails-hyperdrive is the mechanism; companion gems are the content.** The gem itself ships no skills or guidelines, only the contract and the discovery/install engine. Content reaches your app three ways:

- **Native support**: the library gem itself ships a top-level `skills/` directory in the [skills.sh](https://www.skills.sh) layout and opts in as a hyperdrive companion. The preferred route when the maintainer is on board: one gem, one source of truth.
- **Adopted skill repos**: an existing skills.sh skill repo packaged as a gem, content untouched, gating declared on the side.
- **Dedicated companion gems**: third-party guidance for a library that ships none itself. A name like `rails-hyperdrive-<library>` or `<library>-skills` keeps the gem legible in a Gemfile, but naming plays no part in discovery.

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

The generated `.mcp.json` points at `http://localhost:3000<mount>/mcp`. If your dev server runs on another port, edit the URL there.

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
| 7 | `describe_app` | Snapshot: Rails/Ruby/DB versions + direct gem dependencies |
| 8 | `list_routes` | All routes: HTTP verb, path, controller#action, named route |

Plus two MCP resources: `hyperdrive://stack-profile` (JSON snapshot of your resolved stack) and `hyperdrive://skills/{name}` (the markdown body of each installed skill). The skill list is enumerated at server boot and the stack snapshot is memoized per process, so a newly installed skill or a changed bundle reaches these two only after a dev-server restart.

### Two kinds of knowledge

Companion gems ship two artifact types, tuned for how agents consume context:

- **Skills**: *lazy*. Loaded on demand via Claude Code's native description matcher. Procedural knowledge: "how to write an idempotent Sidekiq job". Installed to `.claude/skills/<name>/SKILL.md`, optionally with supporting files (references, examples, workflows) alongside.
- **Guidelines**: *eager*. Always in context via a single `@`-include from `CLAUDE.md`. Declarative facts: "this app uses ActionPolicy, not Pundit". Installed to `.claude/hyperdrive/guidelines/<name>.md`.

A companion gem declares in its manifest which gem each artifact targets and at which versions, so what lands in your app is what matches your `Gemfile.lock`, and nothing aimed at a library or version you don't run.

With no companion gems, `hyperdrive:init` sets up just the server plumbing (`.mcp.json`, the engine mount, the lockfile) and puts **nothing** into your agent's context window.

---

## Staying in sync

**After `bundle install`: automatic.** `hyperdrive:init` registers the [`bundler-rails-hyperdrive`](bundler-rails-hyperdrive/) Bundler plugin in your Gemfile. From then on, adding a companion gem lands its artifacts on that very `bundle install`, with no extra command to run. The plugin is additive only (it never touches an existing file); version bumps and orphaned artifacts are only reported, with a pointer to `hyperdrive:sync`.

**`bin/rails hyperdrive:sync`: on demand.** Run it any time (e.g. after `bundle update`) to refresh installed content to the current bundle. It touches no bootstrap artifact and leaves locally modified files untouched (skip + warn). When you *have* edited an installed file and its gem ships a new version, three mutually exclusive flags reconcile the two:

| Strategy | What happens to the live file | What happens to your edits |
|---|---|---|
| `--merge` | Rewritten with a git three-way merge when it applies cleanly; otherwise untouched and the upstream lands as a `--sidecar` delivery | Kept: a merge that would need conflict markers falls back to the sidecar, so nothing half-merged ever goes live |
| `--sidecar` | Untouched; the new upstream body is written next to it as `<file>.new` | Kept, byte-for-byte |
| `--overwrite` | Restored to the gem-shipped content | Discarded |

A sidecar is inert (Claude Code loads only `SKILL.md` and the `index.md` `@`-lines, never a `.new` file), and it shows up in `git status` as your prompt to resolve. Resolve it by folding what you want into the live file and deleting the `.new`, or `mv <file>.new <file>` to accept the upstream wholesale. Either way the lockfile already records that delivery, so the next sync doesn't re-offer the same version (and a leftover sidecar you haven't touched is cleaned up once the live file catches up). `--merge` needs the previously installed gem version still present on disk to reconstruct the merge ancestor; when it isn't (CI, after `gem cleanup`), it degrades to the sidecar with a note saying why.

The sidecar pair is also how an AI coding agent reconciles for you, with no extra machinery: run `bin/rails hyperdrive:sync --sidecar`, have the agent merge the live/`.new` pair semantically (it has both full texts), then delete the sidecar.

**`bin/rails hyperdrive:discover`: find what you're missing.** Queries rubygems for companion gems published for your stack that you haven't installed yet, and prints the `bundle add` lines to run. It is read-only, caches results for 24h (`--refresh` re-queries), and never touches your Gemfile or makes network calls unless you invoke it.

---

## You stay in charge

### Everything lands git-tracked

```
CLAUDE.md                              # user-owned; ONE injected line: @.claude/hyperdrive/index.md
.claude/hyperdrive/
  index.md                             # managed aggregator: @guidelines/<name>.md
  guidelines/<name>.md                 # companion-shipped, frontmatter stripped
.claude/skills/<name>/
  SKILL.md                             # companion-shipped, installed verbatim (frontmatter included)
  <supporting files>                   # optional extras (references/, examples/, …), installed as shipped (*.md.erb rendered)
.hyperdrive/lock.yml                   # git-tracked manifest (source gem, version, content hash)
```

A `git diff` is where you review what a companion gem added. The install summary names each artifact's source gem and version, and every installed file is hashed and attributed to its source in the git-tracked `.hyperdrive/lock.yml`. The files themselves land byte-identical to what the gem ships, with nothing injected. `hyperdrive:init` warns if your app gitignores these paths, since that empties the diff without changing what reaches the agent. The `hyperdrive:discover` cache is the one file rails-hyperdrive adds to `.gitignore`.

`CLAUDE.md` and `index.md` are the **eager chain**: they exist only because a companion gem ships a guideline, and both go when the last one leaves the bundle (the guideline file itself is left on disk and reported as an orphan).

### Your edits win

Installed files are yours to modify. The lockfile hash tells the installer whether a file is still gem-pristine: unedited files are refreshed on upgrade, edited files are skipped with a warning, never silently overwritten. `hyperdrive:sync --overwrite` is the explicit way back to gem-shipped content.

### Turning off a single artifact

A companion gem you want for one skill but not another doesn't have to be all-or-nothing. Add the artifact's name to the `disabled:` list in `.hyperdrive/lock.yml`. It is written empty on every install, so the shape is already there:

```yaml
disabled:
  skills:
    - sidekiq-idempotency
  guidelines:
    - jobs-sidekiq
```

A disabled artifact is never installed, and one already on disk is removed on the next `hyperdrive:init` or `hyperdrive:sync`, but **only if you haven't edited it**. A locally modified file is reported and left alone, for you to delete when you're ready. Disabling a skill removes its shipped supporting files under the same per-file rule; files you created yourself in the skill directory survive and keep the directory alive. Disabling a guideline also drops its line from `index.md`, so it leaves eager context along with the file.

The list is yours to edit; the generator only reads it and carries it forward. Delete a name to get the artifact back on the next run. When two companion gems ship the same artifact name, both install under a `<name>--<source-gem>` suffix: the plain name disables both, the suffixed name disables one.

To skip installed content wholesale instead, pass `--skip-content` to `hyperdrive:init`.

### Opting into a gem's bundled skills

Ordinary gems (not built as hyperdrive companions) sometimes ship a top-level `skills/` directory of skills.sh-style skills. Those are never installed automatically: `hyperdrive:init` and `hyperdrive:sync` only report them, e.g. `gem 'foo' ships 2 skills.sh skill(s)`. To install them, name the gem in the `enabled:` list in `.hyperdrive/lock.yml` and re-run `hyperdrive:sync`:

```yaml
enabled:
  - foo
```

An enabled gem is treated as a companion from then on: its skills install through the normal pipeline (including on `bundle install`), and `disabled:` still wins for any individual artifact. The list is hand-edited like `disabled:` and survives every rewrite of the lockfile.

---

## Safety

Rails Hyperdrive is **dev-only**, enforced in depth: the engine refuses requests outside `Rails.env.development?`, applies an origin allowlist (`localhost`, `127.0.0.1`, `[::1]`), and every tool re-checks the dev guard on invocation. `run_sql` accepts read-only statements and refuses anything else. See [SECURITY.md](SECURITY.md).

---

## Build a companion gem

Ship markdown, declare what it targets, publish. That's the whole contract:

```
skills/<name>/SKILL.md                                 # skill (dir-per-skill, may ship supporting files)
lib/<gem_name>/hyperdrive/guidelines/<name>.md         # guideline (flat file)
```

Top-level `skills/` is the recommended home for skill content: it is the tool-agnostic face of your gem, readable by skills.sh and plain git-clone consumers as well as hyperdrive, and it is scanned by default. `lib/<gem_name>/hyperdrive/` is the hyperdrive-specific root: guidelines, and ERB skill templates (`SKILL.md.erb`, which must stay out of `skills/` so raw ERB never reaches generic consumers). Plain skills shipped under it remain scanned as well.

Frontmatter is pure skills.sh: only `name` and `description` are read, so a skill repo's content integrates without modification:

```yaml
---
name: jobs-sidekiq                # kebab-case; determines the install path
description: Background job conventions for Sidekiq.
---
```

Gating (which bundles an artifact installs into) lives in a `hyperdrive.yml` manifest at the gem root (or at the path named by a `rails_hyperdrive_manifest` gemspec metadata key), never in the content. Every key is optional; no manifest (or an empty one) means everything installs universally:

```yaml
gem: sidekiq                # gem-wide default: TARGET gem(s), resolved + version-matched in the bundle
versions: ">= 7.0, < 9.0"   # gem-wide default: Gem::Requirement matched against the target gem
skills:                     # per-skill overrides, keyed by skill dir relative to its skills root
  jobs-sidekiq:
    versions: ">= 8.0"
guidelines:                 # per-guideline overrides, keyed by filename
  jobs.md:
    gem: sidekiq
```

Shipping a `hyperdrive.yml` (or declaring `rails_hyperdrive_manifest`) opts your gem in as a companion. Also declare your targets in gemspec metadata. That opts your gem in too, and it is the pre-install targeting signal (how `hyperdrive:discover` suggests you before anyone installs you):

```ruby
spec.metadata["rails_hyperdrive_targets"] = "sidekiq"
```

[docs/COMPANION_GEMS.md](docs/COMPANION_GEMS.md) has the full contract: multi-target artifacts, multi-file skills, per-file gem gating, ERB-templated content, the template/content paired layout that also serves `npx skills` and git-clone consumers, and the collision and dedup rules.

---

## Requirements

Ruby ≥ 3.2, Rails ≥ 7.2. Tested against Rails 7.2 and 8.1 on Ruby 3.2-3.4.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
