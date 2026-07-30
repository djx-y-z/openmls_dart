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
changed between the two tags. `vOLD` is the version being replaced (see the
PR title/diff), `vNEW` is the new one.

**1a. Release notes (starting point, not the whole story):**

```bash
gh api repos/openmls/openmls/releases/tags/vNEW --jq '.body'
```

**1b. Full commit list between the tags:**

```bash
gh api "repos/openmls/openmls/compare/vOLD...vNEW" --paginate \
  --jq '.commits[].commit.message | split("\n")[0]'
```

**1c. Which files changed, scoped to the crates we bind:**

```bash
gh api "repos/openmls/openmls/compare/vOLD...vNEW" --paginate --jq '.files[].filename' \
  | grep -E 'openmls|openmls_rust_crypto|openmls_basic_credential|openmls_traits|openmls_libcrux_crypto'
```

For large ranges the compare API truncates `files` — fall back to a shallow clone:

```bash
git clone --filter=blob:none https://github.com/openmls/openmls /tmp/upstream
git -C /tmp/upstream diff vOLD..vNEW --stat -- <crate dirs>
```

**1d. Check the public API surface we actually bind.** List the upstream
types/functions referenced in `rust/src/api/*.rs`, then look for them in the
diff:

```bash
git -C /tmp/upstream diff vOLD..vNEW -- <crate>/src | grep -E '^[-+].*(pub fn|pub struct|pub enum|pub trait)'
```

**1e. Upstream `Cargo.toml` deltas** — MSRV bumps, new/removed features,
dependency updates with security advisories.

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
- Ensure `openmls_frb` version in Highlights matches `rust/Cargo.toml`

### Step 8: Verify openmls_frb Version Bump

The automated update bumps the version in `rust/Cargo.toml` in two stages:
a deterministic bump mirroring the upstream SemVer delta, then an AI severity
check (from the release notes and commit list) that can raise it — e.g. to
major when a 0.x upstream ships breaking changes in a minor release.

- If the PR carries the **`bump-unverified`** label (or the ⚠️ warning in the
  PR body), the AI check did not run — classify the update yourself using
  your Step 1 findings and fix the version if needed.
- Even when verified, adjust if the *wrapper's own* API changed differently —
  e.g. bump major if adapting to upstream forced breaking changes in
  `rust/src/api/`:

```toml
version = "X.Y.Z"
```

### Step 9: Sync Cargo.lock

```bash
make rust-check
```

### Step 10: Commit Changes

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/src/api/ lib/src/rust/ CHANGELOG.md
git commit -m "fix: adapt for openmls vX.Y.Z breaking changes"
```

### Checklist Summary

- [ ] Read release notes AND the actual commit list / diff between the tags
- [ ] Check the diff against the API surface bound in `rust/src/api/`
- [ ] Fix Rust compilation errors (if any)
- [ ] `make codegen` — regenerate FRB bindings
- [ ] `make test` — all tests pass
- [ ] `make analyze` — no issues
- [ ] CHANGELOG.md — accurate and complete (breaking changes, security fixes)
- [ ] `rust/Cargo.toml` — `openmls_frb` version bumped (automatic; verify)
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
- [ ] `make build-web` passes (libcrux WASM compile; getrandom features)
- [ ] Run the example app's **Post-Quantum** demo tab on native AND Chrome
      (dart2js) — full X-Wing lifecycle smoke must print `RESULT: PASS`

---

## Quick Update (Automatic)

```bash
# Check for updates
make check-new-openmls-version

# Check and apply updates automatically
make check-new-openmls-version ARGS="--update"
```

This will:
1. Check GitHub for latest openmls release
2. Update `rust/Cargo.toml` with new openmls dependency tags
3. Show next steps for completing the update

## Manual Update Process

### Step 1: Check Current Version

Check `rust/Cargo.toml`:
```toml
[dependencies]
openmls = { git = "https://github.com/openmls/openmls", tag = "openmls-v0.8.0" }
```

### Step 2: Update Version

Edit `rust/Cargo.toml` and update the tag for upstream crates.

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
make check-new-openmls-version ARGS="--update --version vX.Y.Z"

# Force update even if versions match
make check-new-openmls-version ARGS="--update --force"

# JSON output for CI
make check-new-openmls-version ARGS="--json"
```

## Version Locations

Files automatically updated by `make check-new-openmls-version ARGS="--update"`:

| File | What | Description |
|------|------|-------------|
| `rust/Cargo.toml` | upstream tags | Native library dependency version |
| `rust/Cargo.toml` | `version` | `openmls_frb` bump mirroring upstream SemVer delta (adjust manually if wrapper API changed differently) |
| `README.md` | Badge | Version badge in header |
| `CLAUDE.md` | Example | Code example in documentation |

Files that need manual update:

| File | What | Description |
|------|------|-------------|
| `rust/Cargo.lock` | Dependencies | Run `make rust-update` after changing Cargo.toml |
| `CHANGELOG.md` | Entry | AI-generated in CI; verify against the upstream diff |

## Breaking Changes to Watch For

### API Changes
- New functions in upstream crate
- Removed functions
- Changed function signatures
- New struct fields

### Behavior Changes
- Protocol version updates
- New cryptographic algorithms
- Changed error types

### Binding Regeneration

After updating, if API changed, run:
```bash
make codegen
```

Then check for:
- Compilation errors in `rust/src/api/` files
- Missing functions that your code depends on
- Changed function signatures

## Troubleshooting

### "No updates available"
- You're already on the latest version
- Check https://github.com/openmls/openmls/releases

### "Cargo build failed"
- New openmls version may have breaking API changes
- Check openmls release notes
- May need to update Rust wrapper code in `rust/src/api/`

### Tests fail after update
- API may have changed
- Protocol version may have changed
- Review openmls changelog for breaking changes

## Upstream Resources

- [openmls Releases](https://github.com/openmls/openmls/releases)
- [openmls Repository](https://github.com/openmls/openmls)
