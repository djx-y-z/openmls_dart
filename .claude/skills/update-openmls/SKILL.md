---
name: update-openmls
description: Update openmls native library version. Use when checking for updates, upgrading openmls, bumping version, or updating native dependencies.
---

# Update openmls Version

Guide for updating the openmls native library version in this project.

## Review Automated PR (Most Common)

When the CI creates an automated PR for openmls update, follow these steps:

### Step 1: Analyze Upstream Changes (IMPORTANT — go beyond release notes)

Release notes are often terse or incomplete. Always examine what actually
changed between the two releases. `$OLD` is the version being replaced (see the
PR title/diff), `$NEW` is the new one.

This project takes openmls from crates.io, so the two releases
are compared by the commits their published crates record rather than by tags —
which tags upstream cuts, and how it names them, is exactly what a registry
source does not depend on. `$OLD` and `$NEW` are those commits, and every
command below takes them as they are; find them first:

```bash
commit_of() {  # the commit `cargo package` recorded inside the published crate
  curl -sL "https://static.crates.io/crates/openmls/openmls-$1.crate" \
    | tar -xzOf - "openmls-$1/.cargo_vcs_info.json" | jq -r .git.sha1
}
OLD=$(commit_of X.Y.Z)   # the version being replaced
NEW=$(commit_of X.Y.Z)   # the new one
```

**1a. Release notes (starting point, not the whole story)** — crates.io carries
none, so they are the release's section of `CHANGELOG.md` (or a
`RELEASE_NOTES.md`) at the new commit:

```bash
gh api "repos/openmls/openmls/contents/CHANGELOG.md?ref=$NEW" \
  -H 'Accept: application/vnd.github.raw' | less
```

**1b. Full commit list between the releases:**

```bash
gh api "repos/openmls/openmls/compare/$OLD...$NEW" --paginate \
  --jq '.commits[].commit.message | split("\n")[0]'
```

**1c. Which files changed, scoped to the crates we bind:**

```bash
gh api "repos/openmls/openmls/compare/$OLD...$NEW" --paginate --jq '.files[].filename' \
  | grep -E 'openmls|openmls_rust_crypto|openmls_basic_credential|openmls_traits|openmls_libcrux_crypto'
```

For large ranges the compare API truncates `files` — fall back to a shallow clone:

```bash
git clone --filter=blob:none https://github.com/openmls/openmls /tmp/upstream
git -C /tmp/upstream diff $OLD..$NEW --stat -- <crate dirs>
```

**1d. Check the public API surface we actually bind.** List the upstream
types/functions referenced in `rust/src/api/*.rs`, then look for them in the
diff:

```bash
git -C /tmp/upstream diff $OLD..$NEW -- <crate>/src | grep -E '^[-+].*(pub fn|pub struct|pub enum|pub trait)'
```

**1e. Upstream `Cargo.toml` deltas** — MSRV bumps, new/removed features,
dependency updates with security advisories.

⚠ **An MSRV bump moves more than one file.** `rust-version` in
`rust/Cargo.toml` is what CI reads — `test-reusable.yml` greps it and feeds it
to the toolchain action — but that line is *rendered* from the `rust_version`
answer in `.copier-answers.yml`, and so is the version README.md and
CONTRIBUTING.md advertise to contributors. `make check-msrv ARGS="--update"`
raises them together, to the highest floor a crate of the resolved graph
declares, and the update workflow runs it after `make rust-update`. Raised in
the manifest alone, the next `copier update` renders the stale number straight
back over it. It reads what crates declare, so a crate that uses a feature
newer than its own floor still only shows up in the MSRV job.

Summarize findings as:
- **Breaking changes** (API removals, signature changes) → Rust wrapper must adapt
- **New features / new APIs** → candidates to expose in `rust/src/api/`
- **Security fixes** → must be called out in CHANGELOG.md
- **Internal-only changes** → one CHANGELOG line ("does not affect this library's API")

### Step 2: Check Why Codegen Failed (if applicable)

```bash
# Check if Rust code compiles
make rust-check
```

Common issues:
- **Removed traits** (e.g., `Ord` for `PublicKey`)
- **Changed function signatures**
- **Renamed types**
- **An item moved behind a cargo feature.** `E0599: no variant named X` (or
  `no method named X`) reads exactly like a removal, and upstream release notes
  tend to say "gated" rather than "removed", so the two are easy to conflate —
  the wrong diagnosis costs a wrapper rewritten to live without something that
  is still there. Check the feature table in that crate's `Cargo.toml` before
  adapting anything. Features are **not** transitive across crates: enabling
  one on the top-level crate does not enable it for a sibling crate this
  project depends on directly, so every dependency line in `rust/Cargo.toml`
  that names the gated item needs the feature of its own.

### Step 2b: Keep diagnostic features out of the shipped binary

Cargo features are additive and unified across every dependency table, so a
feature enabled anywhere — including under
`[target.'cfg(target_arch = "wasm32")'.dependencies]` — is enabled everywhere
the crate is built. There is no "for tests only", and no "native only": the
published library and the wasm module carry it too.

The features worth watching are the ones that change what error *values*
contain rather than what the API offers. One that turns errors into symbolized
backtraces needs no panic to reach a caller: the string travels the ordinary
error channel, crosses FFI, and lands in the consuming application's logs
naming internal paths and, on some platforms, absolute build paths.

When a bump adds such a feature, or moves an existing one, check the artifacts
rather than the manifest — the manifest is where the mistake looks harmless:

```bash
make build && make build-web
# 0 hits required, on the native library AND the wasm module
strings <built artifact> | grep -c '<a string the feature introduces>'
```

### Step 3: Fix Rust Code (if needed)

If `make rust-check` fails, fix the errors in `rust/src/api/`:
- Update code to match new openmls API
- Add workarounds for removed functionality

### Step 4: Regenerate FRB Bindings

```bash
make codegen
```

### Step 5: Run Tests

```bash
make test
```

### Step 6: Run Analysis

```bash
make analyze
```

### Step 7: Update CHANGELOG.md

Verify the AI-generated entry against YOUR findings from Step 1 — the AI only
sees the release notes and commit subjects, not the diffs:
- Fix incorrect descriptions
- Add breaking changes, workarounds, and security fixes you found in the diff
- Leave the `openmls_frb` line out of Highlights: `make release-frb` stamps
  it when the crate is released

### Step 8: Leave the openmls_frb Version Alone

The automated update does not touch `[package] version` in `rust/Cargo.toml`,
and neither should the review. The crate version is chosen when the crate is
released — `make release-frb ARGS="--version X.Y.Z"`, by SemVer of the FFI
surface across everything merged since the last `openmls_frb-*` tag — so
an update that lands now is versioned together with whatever lands after it.
What this review contributes to that choice is the codegen diff (see *Binding
Regeneration* below), and, if adapting to upstream forced a breaking change in
`rust/src/api/`, a CHANGELOG entry that says so.

### Step 9: Sync Cargo.lock

```bash
make rust-check
```

### Step 9b: Re-validate the advisory ignores

`.cargo/audit.toml` and `rust/deny.toml` carry ignores that were justified
against the dependency graph as it stood when each was added. A bump moves that
graph: an advisory can become unreachable, or a new one can arrive in the same
crate an old entry silently covers.

Empty both lists, run `make rust-audit` and `make rust-deny`, and re-add only
what fires again — each with a reason written for the graph as it is now. An
entry that matches nothing is reported by cargo-deny as `advisory-not-detected`
and should be deleted rather than kept in case the crate comes back; the two
files are not interchangeable either, since cargo-deny also reports
*unmaintained* advisories that `cargo audit` does not fail on.

### Step 10: Commit Changes

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/src/api/ lib/src/rust/ CHANGELOG.md
git commit -m "fix: adapt for openmls vX.Y.Z breaking changes"
```

### Checklist Summary

- [ ] Read release notes AND the actual commit list / diff between the releases
- [ ] Check the diff against the API surface bound in `rust/src/api/`
- [ ] Fix Rust compilation errors (if any)
- [ ] `make codegen` — regenerate FRB bindings
- [ ] `make test` — all tests pass
- [ ] `make analyze` — no issues
- [ ] CHANGELOG.md — accurate and complete (breaking changes, security fixes)
- [ ] `rust/Cargo.toml` — `[package] version` untouched (`make release-frb` moves it)
- [ ] An `E0599` was checked against the upstream feature table before being
      treated as a removal
- [ ] No diagnostic/test-only upstream feature ships — checked with `strings`
      on the built artifacts, not by reading the manifest
- [ ] Advisory ignores emptied and re-added from what still fires
- [ ] MSRV: `make check-msrv` passes (`--update` raises every copy together)
- [ ] `make rust-check` — sync Cargo.lock
- [ ] Commit all changes

### X-Wing / RustSec checklist (extra steps on every upstream bump)

- [ ] Remove the RUSTSEC ignore entries from `.cargo/audit.toml` and re-run
      `make rust-audit` — if advisories still fire, re-verify reachability
      before re-adding ignores (justifications are inline in that file)
- [ ] Verify `HpkeKemType::XWingKemDraft6` and
      `MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` (0x004D) still exist
      upstream with unchanged wire semantics (a draft bump would be a NEW
      identifier per upstream policy — groups on 0x004D must keep working)
- [ ] Check whether upstream moved them behind a **cargo feature**, and that the
      feature is enabled on **all five** openmls crates we depend on. 0.9.0 put
      both behind `draft-ietf-mls-pq-ciphersuites` without renaming anything,
      and the resulting `E0599 ... no variant named XWingKemDraft6` reads
      exactly like a removal. Enabling it only on `openmls` is not enough:
      `openmls_libcrux_crypto` is a direct dependency, does not receive the
      feature transitively, and its own `kem_mode` match then fails to compile
      upstream. `openmls_rust_crypto` and `openmls_traits` need it too, and so
      does `openmls_basic_credential` — without it `SignatureKeyPair::new` has
      no ML-DSA arms and the four ML-DSA ciphersuites cannot build an identity
      at all. Count the occurrences in `rust/Cargo.toml`: five dependency lines
      must name the feature.
- [ ] `make build-web` passes (libcrux WASM compile; getrandom features)
- [ ] Run the example app's **Post-Quantum** demo tab on native AND Chrome
      (dart2js) — full X-Wing lifecycle smoke must print `RESULT: PASS`

### Shipped cargo features (extra steps on every upstream bump)

- [ ] `openmls/test-utils` must stay **absent** from `rust/Cargo.toml`. It
      implies `openmls/backtrace`, under which `LibraryError::custom()` formats
      a symbolized Rust backtrace — build-machine paths, symbol names, crate
      layout — into an error that reaches the Dart caller through the *ordinary*
      error channel, no panic involved. Features are additive, so it cannot be
      turned on "only for tests": anything enabling it puts it in the shipped
      binary, on **every** platform — cargo unifies features across the
      `[target.'cfg(...)'.dependencies]` tables, so the wasm32 build gets it too.
      Verify with `strings <artifact> | grep 'Backtrace:'` — zero hits on both
      `rust/target/release/libopenmls_frb.dylib` and
      `rust/target/wasm32/openmls_frb_bg.wasm`.
- [ ] `MlsGroup::public_group()`, `PublicGroup::group_context()` and
      `GroupContext::{tree_hash, confirmed_transcript_hash}` must still be
      public and un-gated — `api/engine.rs::export_group_context` uses that
      chain precisely *instead of* the `test-utils`-gated
      `MlsGroup::export_group_context()`. If upstream re-gates any of them, do
      not re-add `test-utils`; raise it upstream, as was done for the accessors
      that 0.9.0 opened up.
- [ ] `openmls_basic_credential/test-utils` is a **different** crate's feature
      and stays — it is what makes `SignatureKeyPair::private()` reachable for
      `privateKey()`, and it implies no backtrace.

---

## Quick Update (Automatic)

```bash
# Check for updates
make check-new-openmls-version

# Check and apply updates automatically
make check-new-openmls-version ARGS="--update"
```

This will:
1. Check crates.io for latest openmls release
2. Update `rust/Cargo.toml` with new openmls dependency versions
3. Show next steps for completing the update

## Manual Update Process

### Step 1: Check Current Version

Check `rust/Cargo.toml`:
```toml
[dependencies]
openmls = "=0.9.1"
```

### Step 2: Update Version

Edit `rust/Cargo.toml`: pin `openmls` to the new version, exactly
(`"=X.Y.Z"`), on every declaration of it, and move every other upstream crate to
the requirement that release itself declares (crates.io lists it under the
version's dependencies). `make check-new-openmls-version ARGS="--update"`
does both, and records them in `.copier-answers.yml`.

### Step 3: Update Cargo.lock

```bash
make rust-update
```

### Step 4: Regenerate FRB Bindings (if API changed)

```bash
make codegen
```

### Step 5: Run Tests

```bash
make test
```

### Step 6: Commit Changes

```bash
git add rust/Cargo.toml rust/Cargo.lock
git commit -m "chore(deps): update openmls to vX.Y.Z"
git push
```

## Check Options

```bash
# Just check (no changes)
make check-new-openmls-version

# Check and update
make check-new-openmls-version ARGS="--update"

# Update to specific version
make check-new-openmls-version ARGS="--update --version X.Y.Z"

# Force update even if versions match
make check-new-openmls-version ARGS="--update --force"

# JSON output for CI
make check-new-openmls-version ARGS="--json"
```

## Version Locations

Files automatically updated by `make check-new-openmls-version ARGS="--update"`:

| File | What | Description |
|------|------|-------------|
| `rust/Cargo.toml` | upstream versions | Native library dependency version |
| `.copier-answers.yml` | `upstream_version`, `upstream_crate_versions` | What the next `copier update` renders |
| `README.md` | Badge | Version badge in header |
| `CLAUDE.md` | Example | Code example in documentation |

Not touched: `[package] version` in `rust/Cargo.toml`. The `openmls_frb`
version moves with `make release-frb`, not with an upstream update.

Files that need manual update:

| File | What | Description |
|------|------|-------------|
| `rust/Cargo.lock` | Dependencies | Run `make rust-update` after changing Cargo.toml |
| `CHANGELOG.md` | Entry | AI-generated in CI; verify against the upstream diff |

## Breaking Changes to Watch For

**Step 2 and Step 2b above are the list.** What a compiler can tell you —
removed traits, changed signatures, renamed types, an item moved behind a cargo
feature — is there, together with what to check before concluding that
something was removed. Step 2b covers the kind that compiles cleanly and still
reaches a consumer: a feature that changes what error *values* carry.

What neither step can see, because nothing in this repository fails when it
changes, is the upstream's own semantics:

- a protocol version the upstream now speaks, or stops speaking
- a cryptographic algorithm added, deprecated or given a new code point
- a default that moved while its signature did not

Those are read out of the upstream release notes, not out of a build, and they
belong in the changelog entry whether or not this package's API moved.

### Binding Regeneration

After updating, run:
```bash
make codegen
```

An empty diff under `lib/src/rust/` is itself the answer: the FFI surface did
not move, which is what decides whether the next release is a minor. A
non-empty one has to be read — `codegen-guard` refuses bindings that do not
match `rust/src/api/`, so committing what it generates is not optional.

## Troubleshooting

### "No updates available"
- You're already on the latest version
- Check https://crates.io/crates/openmls/versions

### "Cargo build failed"
- New openmls version may have breaking API changes
- Check openmls release notes
- May need to update Rust wrapper code in `rust/src/api/`

### Tests fail after update
- API may have changed
- Protocol version may have changed
- Review openmls changelog for breaking changes

## Upstream Resources

- [openmls on crates.io](https://crates.io/crates/openmls)
- [openmls Repository](https://github.com/openmls/openmls)
