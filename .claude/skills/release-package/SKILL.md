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
   downloads it, so releasing without it would break consumers. It also checks
   that the release was **built from this tree**: `rust/` (all but `rust/fuzz`
   and `rust/deny.toml`) and `lib/src/rust/` at its tag must equal `HEAD`'s.
   Any commit touching them after stage 1 therefore needs a new crate — a
   test-only change under `rust/src` or a docstring-only regeneration
   included, since the check cannot tell those apart and refuses them all.
3. **Validates** the package with `make publish-dry-run` on the clean, pre-bump
   tree, aborting if it reports errors. (Runs before the bump because
   `dart pub publish --dry-run` exits non-zero on any warning, and dry-running a
   bumped-but-uncommitted tree would warn about the modified files.) The target
   runs `make verify-pub-limits` first — see step 6.
4. **Bumps** the `version:` in `pubspec.yaml`.
5. **Finalizes the CHANGELOG** — renames `## [Unreleased]` to `## [X.Y.Z] -
   <today>` in place (no empty `## [Unreleased]` is left behind — the next
   unreleased change recreates it), and updates the bottom compare links
   (`[Unreleased]` → `vX.Y.Z...HEAD`, retained, and a new `[X.Y.Z]` →
   `vPREV...vX.Y.Z`).
6. **Measures the files pub.dev limits**, as this release will commit them:
   `README.md`, `CHANGELOG.md`, `LICENSE` and the example against 256 KiB,
   `pubspec.yaml` against 128 KiB. pub.dev refuses the upload over either, the
   dry-run checks neither, and the refusal arrives after the tag — so a file
   over its limit reverts the bump and the CHANGELOG edit and stops here.
7. Shows the diff and asks for confirmation (skip with `--yes`).
8. Creates a **signed commit** and a **signed tag** `vX.Y.Z`.
9. **Pushes** `main` and the tag (skip with `--no-push`), which triggers
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
- `--skip-frb-check` — skip both checks of step 2, that `openmls_frb-<crate>`
  exists and that it was built from this tree (only if you have verified the
  binary by hand)
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

**Then run the suite against that binary.** No workflow does: `publish.yml`
and `test.yml` — its `workflow_run` after the native build included — build the
library from source with `make build`. Check `HEAD` out in a fresh sibling
worktree, which has no `rust/target/`, and run the suite there without
`make build`: the build hook then downloads `openmls_frb-<crate>` from the
release, checks it against the release's checksums, and every test runs
against that release's library for this host, the one platform the check
covers.

```bash
git worktree add --detach ../stage2-check HEAD
cd ../stage2-check && make get && make test   # no make build: the hook downloads
cd - && git worktree remove ../stage2-check
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
# 1. What `make release` checks first: the stage-1 release exists, and its tag
#    holds the native sources HEAD does. <crate> is the crate version
#    `make version` prints; without `gh`, find the release on the Releases page.
gh release view openmls_frb-<crate>
git fetch origin tag openmls_frb-<crate>
git diff --quiet openmls_frb-<crate> HEAD -- rust lib/src/rust ':!rust/fuzz' ':!rust/deny.toml'
#    Non-zero: those sources moved since the tag, so release a new crate first.
#    Then run the suite against the release in a fresh worktree, as above.

# 2. Quality checks
make analyze && make test && make format-check && make rust-check && make rust-audit

# 3. Bump pubspec.yaml `version:` and finalize CHANGELOG.md:
#    - rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` in place
#      (do NOT add a fresh empty `## [Unreleased]` — the next unreleased
#      change recreates it)
#    - rewrite `[Unreleased]: .../compare/vX.Y.Z...HEAD` (kept at the bottom)
#      and add `[X.Y.Z]: .../compare/vPREV...vX.Y.Z`

# 4. Validate (runs `make verify-pub-limits` first: pub.dev's size limits,
#    which the dry-run itself does not check)
make publish-dry-run

# 5. Commit (signed), tag (signed, annotated), push
git commit -am "chore: prepare release vX.Y.Z"
git tag -s vX.Y.Z -m "Release vX.Y.Z"
git push origin main && git push origin vX.Y.Z
```

Without Admin you cannot push the bump to `main`, so open a PR for the bump
commit, merge it, and repeat step 1 on the merged commit. The tag is a separate
gate: the `Protect release tags` ruleset lets only Admin create one, so ask an
Admin to push the signed `vX.Y.Z` tag on the merged commit.

### If CI fails

Find out why before touching the tag: `make release` will not cut a version it
has already cut.

**A transient failure** — a runner that never started, a network timeout — is
retried on the same tag: re-run the failed jobs of the tag's run (Actions → the
run → *Re-run failed jobs*, or `gh run rerun <run-id> --failed`).

**A failure caused by the code or the package** — a failing test, a dry-run
error, an upload pub.dev refuses — cannot be retried, because the tag points at
the release commit. The version is spent: its bump is on `main`, so
`make release` refuses it as not greater than the current version, and the tag
ruleset reserves deleting the tag to Admin — which tidies up but does not free
the version. Fix the cause on `main`. The release renamed `## [Unreleased]`, so
start a new one above the section the failed release created, with the fix and
a Highlights line saying that `X.Y.Z` was tagged but never published. Push, let
CI go green, and release the next patch:

```bash
make release ARGS="--version X.Y.W"   # W = Z + 1
```

## Resources

- Publish workflow: `.github/workflows/publish.yml`
- Release script: `scripts/release.dart` (logic in `scripts/src/release.dart`)
- Stage 1: [release-frb-crate](../release-frb-crate/SKILL.md) / `make release-frb`
- Two-stage flow overview: `CLAUDE.md` → Release Flow
- [pub.dev Publishing Guide](https://dart.dev/tools/pub/publishing)
- [Semantic Versioning](https://semver.org/) · [Keep a Changelog](https://keepachangelog.com/)
