---
name: release-frb-crate
description: Release a new openmls_frb native crate version (stage 1 of the two-stage release). Use when the user wants to build/publish new native binaries after openmls dependency updates, bump the openmls_frb crate, or push a openmls_frb-* tag. NOT for the Dart pub.dev release (that is release-package).
---

# Release the openmls_frb Native Crate (Stage 1)

Releasing this project happens in **two stages**, each its own command and tag:

| Stage | What | Command | Tag | Trigger |
|-------|------|---------|-----|---------|
| **1. Native crate** (this skill) | Build & publish the `openmls_frb` native binaries | `make release-frb ARGS="--version X.Y.Z"` | `openmls_frb-X.Y.Z` | builds `build-openmls.yml` |
| **2. Dart package** ([release-package](../release-package/SKILL.md)) | Publish to pub.dev | tag `vX.Y.Z` | `vX.Y.Z` | publishes `publish.yml` |

**Order matters: stage 1 must fully finish before stage 2.** The published Dart
package's build hook downloads the precompiled `openmls_frb-<crate>` binary, so
that binary must already exist on GitHub Releases before you tag the pub.dev
release.

## Why this is separate from dependency updates

Automated libsignal update PRs (`check-openmls-updates.yml`) **no longer bump
the `openmls_frb` crate version** — they only update the openmls dependency
and the CHANGELOG. Multiple dependency updates accumulate on `main` without
publishing a throwaway native binary. When you decide to cut a release, this
skill bumps the crate version once and builds the binary for that snapshot.

## When to run

Run stage 1 when you want to ship the current `main` state as a new native
binary — typically right before a Dart package release, after one or more
openmls dependency-update PRs have merged.

## How to run

```bash
# From a clean, up-to-date main:
make release-frb ARGS="--version 5.2.0"
```

The script (`scripts/release_frb.dart`) does all of this in one command:

1. **Preconditions** — refuses unless you are on a clean `main`, up to date with
   `origin/main`, the version is greater than the current crate version, and the
   `openmls_frb-<version>` tag does not already exist (local or remote).
2. **Bumps** the `[package]` version in `rust/Cargo.toml`.
3. **Stamps** `- **openmls_frb vX.Y.Z** — Rust FFI bindings` into the CHANGELOG
   `[Unreleased]` Highlights (inserts, or replaces an existing frb line; creates
   the `## [Unreleased]` section if the previous release removed it).
4. Shows the diff and asks for confirmation (skip with `--yes`).
5. Creates a **signed commit** and a **signed tag** `openmls_frb-X.Y.Z`.
6. **Pushes** `main` and the tag (skip with `--no-push`), which triggers the
   native build.

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

- `--version <X.Y.Z>` — new crate version (required)
- `--no-push` — commit and tag locally only (push later yourself)
- `--yes`, `-y` — skip the confirmation prompt

## Choosing the crate version (SemVer for `openmls_frb`)

The `openmls_frb` version is the **binary-content version** and follows SemVer
for the FFI surface, independent of the pub.dev package version and of upstream
openmls's version. Judge the bump from what changed since the **last frb
release**, not from the upstream version numbers:

| Bump | When |
|------|------|
| **major** | The generated bindings' wire signature changed in a breaking way, or a required callback/behavior changed (a stale binary would crash) |
| **minor** | New backwards-compatible bindings/functionality |
| **patch** | Dependency/security update with no binding-surface change |

**Heuristic:** if `make codegen` produced a non-empty diff under `lib/src/rust/`
for any dependency update since the last frb release, the wire signature moved —
bump at least minor, and major if the change is breaking. (This is the same
codegen-diff signal that decides whether a stale binary is safe.) When unsure,
prefer the more severe bump.

## After the native build succeeds

1. Watch the build: `gh run watch` (or the Actions tab). It creates the GitHub
   Release `openmls_frb-<version>` with all platform archives.
2. Only then proceed to **stage 2** — the Dart package release
   ([release-package](../release-package/SKILL.md)): bump `pubspec.yaml`,
   finalize the CHANGELOG `[Unreleased]` → `[X.Y.Z]`, tag `vX.Y.Z`, push.

## Tag naming

The tag is `openmls_frb-<crate version>` (no `v` prefix, matching the release
artifact name), e.g. `openmls_frb-5.2.0`. It must equal the `rust/Cargo.toml`
crate version — the build workflow validates this and fails on a mismatch. The
tag you push IS the release tag (no duplicate tags).

## If the build fails

Fix the issue on `main`, then delete and re-create the tag:

```bash
git tag -d openmls_frb-X.Y.Z
git push origin :refs/tags/openmls_frb-X.Y.Z
# fix + commit on main, then:
make release-frb ARGS="--version X.Y.Z"
```

## Resources

- Native build workflow: `.github/workflows/build-openmls.yml`
- Release script: `scripts/release_frb.dart` (logic in `scripts/src/release_frb.dart`)
- Two-stage flow overview: `CLAUDE.md` → Release Flow
