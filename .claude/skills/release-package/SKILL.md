---
name: release-package
description: Prepare a new version of openmls for publication to pub.dev. Use when user wants to release, publish, or tag a new version of the package.
---

# Release the Dart Package (Stage 2)

Guide for publishing a new version of the `openmls` Dart package to pub.dev.

> **Stage 2 of 2.** Releasing this project has two stages. This skill covers
> **stage 2** (publishing the Dart package to pub.dev). It does **not** release
> the native `openmls_frb` crate — that is **stage 1**, handled by the
> [release-frb-crate](../release-frb-crate/SKILL.md) skill / `make release-frb`.
>
> **Run stage 1 first and let its native build finish.** The published package's
> build hook downloads the precompiled `openmls_frb-<crate>` binary, so that
> binary must already exist before you tag the pub.dev release. `make release`
> verifies this automatically (see below).

## How to run

```bash
# From a clean, up-to-date main, after the stage-1 native build has finished:
make release ARGS="--version 6.1.0"
```

`make release` (`scripts/release.dart`) does the whole stage-2 release in one
command:

1. **Preconditions** — refuses unless you are on a clean `main`, up to date with
   `origin/main`, the version is greater than the current `pubspec.yaml` version,
   and the `vX.Y.Z` tag does not already exist (local or remote).
2. **Verifies the stage-1 native release exists** — checks that the GitHub
   Release `openmls_frb-<version in rust/Cargo.toml>` is published (via `gh`).
   Fails closed if it is missing or can't be verified — the published build hook
   downloads it, so releasing without it would break consumers.
3. **Validates** the package with `make publish-dry-run` on the clean, pre-bump
   tree, aborting if it reports errors. (Runs before the bump because
   `dart pub publish --dry-run` exits non-zero on any warning, and dry-running a
   bumped-but-uncommitted tree would warn about the modified files.)
4. **Bumps** the `version:` in `pubspec.yaml`.
5. **Finalizes the CHANGELOG** — renames `## [Unreleased]` to `## [X.Y.Z] -
   <today>` in place (no empty `## [Unreleased]` is left behind — the next
   unreleased change recreates it), and updates the bottom compare links
   (`[Unreleased]` → `vX.Y.Z...HEAD`, retained, and a new `[X.Y.Z]` →
   `vPREV...vX.Y.Z`).
6. Shows the diff and asks for confirmation (skip with `--yes`).
7. Creates a **signed commit** and a **signed tag** `vX.Y.Z`.
8. **Pushes** `main` and the tag (skip with `--no-push`), which triggers
   `publish.yml` → pub.dev.

### Signing passphrase

The commit, tag, and push run with an inherited terminal, so **you enter your
signing passphrase interactively during the command** — there is no separate
manual commit/tag step. Run it from a terminal (not an IDE task runner) so both
the passphrase prompt and the pre-commit hook (`make format-check` + `rust-check`
+ `analyze`) work.

**Get it wrong and it just asks again.** `ssh-keygen`/`gpg` do not re-prompt on
their own, so a mistyped passphrase used to abort the release outright. Every
signing and push step now prints the error and runs itself again, so the
passphrase prompt comes straight back — no question to answer, no attempt limit.
**Ctrl-C is how you give up.** From the third failure in a row it pauses 2s
between attempts and says so, so a step failing for a reason no passphrase will
fix cannot scroll past you. With a non-interactive stdin (CI) there is no retry
at all: the step throws on its first failure, as before.

**A run that died anyway is resumed by re-running the exact same command.** If
you Ctrl-C out or lose the terminal after the release commit was created, the
command detects that commit and continues from the tag/push step — it does not
bump the version or edit the CHANGELOG a second time. Interrupt it *before* the
commit and the next run tells you the one command that discards the half-applied
edits. Nothing has to be reverted or tagged by hand.

### Options

- `--version <X.Y.Z>` — new package version (required)
- `--no-push` — commit and tag locally only (push later yourself)
- `--yes`, `-y` — skip the confirmation prompt
- `--skip-frb-check` — skip the stage-1 native-binary existence check (only if
  you have verified the `openmls_frb-<crate>` release exists manually)
- `--date <Y-M-D>` — CHANGELOG date to stamp (default: today)

## Choosing the version (SemVer for the Dart package)

The pub.dev package version follows [Semantic Versioning](https://semver.org/)
for the **public Dart API**, independent of the `openmls_frb` crate version and
of upstream openmls's version.

| Change Type | Version Bump | Examples |
|-------------|--------------|----------|
| Breaking API changes | MAJOR | Removed/renamed public APIs, changed function signatures |
| New features | MINOR | New public APIs, new platform support |
| Bug fixes | PATCH | Bug fixes, dependency updates, documentation |

The CHANGELOG (`[Unreleased]` section) is the source of truth for what changed —
review it and pick the bump that matches. See the changelog format in
`CLAUDE.md` → Changelog Format.

## Prerequisite: stage 1 must exist

`make release` checks this for you, but to confirm manually: `make version` shows
the crate version from `rust/Cargo.toml`, and a GitHub Release named
`openmls_frb-<that version>` must be published. If it is not, run stage 1
first:

```bash
make release-frb ARGS="--version <crate X.Y.Z>"   # then let the build finish
```

## Publishing flow

This project uses **tag-triggered CI** for publishing — you do NOT run `dart pub
publish` manually:

1. `make release` pushes a git tag matching `vX.Y.Z`.
2. The `publish.yml` workflow triggers automatically on the tag.
3. It validates the tag matches `pubspec.yaml`, runs tests, and publishes to
   pub.dev via OIDC (gated by the `pub.dev` environment's required reviewers).
4. It creates a GitHub Release with the extracted changelog section.

## Manual fallback

If you cannot use `make release` (e.g. `make`/`gh` unavailable, or you are not an
Admin and must land the version bump through a PR instead of pushing to `main`):

```bash
# 1. Quality checks
make analyze && make test && make format-check && make rust-check && make rust-audit

# 2. Bump pubspec.yaml `version:` and finalize CHANGELOG.md:
#    - rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` in place
#      (do NOT add a fresh empty `## [Unreleased]` — the next unreleased
#      change recreates it)
#    - rewrite `[Unreleased]: .../compare/vX.Y.Z...HEAD` (kept at the bottom)
#      and add `[X.Y.Z]: .../compare/vPREV...vX.Y.Z`

# 3. Validate
make publish-dry-run

# 4. Commit (signed), tag (signed, annotated), push
git commit -am "chore: prepare release vX.Y.Z"
git tag -s vX.Y.Z -m "Release vX.Y.Z"
git push origin main && git push origin vX.Y.Z
```

Non-admins: open a PR for the bump commit, merge it, then push the `vX.Y.Z` tag
(tag creation is not gated by the pull-request rule).

### If CI fails

Fix the issue, then delete and re-create the tag:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
# fix + commit on main, then re-run:
make release ARGS="--version X.Y.Z"
```

## Resources

- Publish workflow: `.github/workflows/publish.yml`
- Release script: `scripts/release.dart` (logic in `scripts/src/release.dart`)
- Stage 1: [release-frb-crate](../release-frb-crate/SKILL.md) / `make release-frb`
- Two-stage flow overview: `CLAUDE.md` → Release Flow
- [pub.dev Publishing Guide](https://dart.dev/tools/pub/publishing)
- [Semantic Versioning](https://semver.org/) · [Keep a Changelog](https://keepachangelog.com/)
