# Releasing

`rails-hyperdrive` follows [Semantic Versioning](https://semver.org). `lib/rails/hyperdrive/version.rb` is the single source of truth for the version — the gemspec and the `describe_app` MCP tool both read `Rails::Hyperdrive::VERSION` from it.

Publishing to RubyGems is **tag-triggered**: pushing a `vX.Y.Z` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml), which runs the specs, builds the gem, and pushes it to RubyGems via [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) (OIDC — no API keys stored in the repo).

## One-time setup

Required before the **first** publish, or the workflow fails with an auth error. On rubygems.org, register a Trusted Publisher (GitHub Actions) with:

- **Repository:** `rails-hyperdrive/rails-hyperdrive`
- **Workflow filename:** `release.yml`
- **Environment:** `release`

For a brand-new gem that isn't on rubygems.org yet, use the **pending publisher** flow: Profile → Trusted Publishers → Create. The exact field values are also documented in the header comment of `release.yml`.

## Cutting a release

```bash
# 1. (recommended) record what changed under "## [Unreleased]" in CHANGELOG.md

# 2. bump — edits version.rb, dates the CHANGELOG section, commits, creates the vX.Y.Z tag
bin/bump <patch|minor|major|X.Y.Z> --commit --tag

# 3. push the commit AND the tag — the tag is what triggers publishing
git push origin main --follow-tags
```

`bin/bump` also accepts `--dry-run` (preview without writing) and works without `--commit`/`--tag`, in which case it only edits the files and prints the git commands for you to run after reviewing the diff.

## Key facts

- **The bump does not publish — the tag push does.** `bin/bump` only edits files and (with `--tag`) creates the tag locally; nothing leaves your machine until you push it.
- **No tag, no publish.** A plain `git push` (or forgetting `--follow-tags`) only runs the normal CI workflow. The `vX.Y.Z` tag must reach GitHub for a release to happen.
- **The published version is whatever you bump to** — e.g. `bin/bump patch` from `0.1.0` produces `0.1.1`.

## Offline fallback

`rake release` (from `bundler/gem_tasks`) tags and pushes from your machine instead of via CI. Do **not** combine it with `bin/bump --tag` — both create the `vX.Y.Z` tag, so use one path or the other, not both.
