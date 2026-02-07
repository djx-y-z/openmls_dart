---
name: update-openmls
description: Update openmls native library version. Use when checking for updates, upgrading openmls, bumping version, or updating native dependencies.
---

# Update openmls Version

Guide for updating the openmls native library version in this project.

## Review Automated PR (Most Common)

When the CI creates an automated PR for openmls update, follow these steps:

### Step 1: Analyze Release Notes

```bash
# Fetch and read release notes
gh api repos/openmls/openmls/releases/tags/vX.Y.Z --jq '.body'
```

Look for:
- **Breaking changes** (API removals, signature changes)
- **New features** (new APIs exposed)
- **Security fixes**

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

Verify AI-generated entry is accurate. Update if needed:
- Fix incorrect descriptions
- Add details about breaking changes and workarounds
- Ensure `openmls_frb` version is mentioned in Highlights

### Step 8: Bump openmls_frb Version

Edit `rust/Cargo.toml`:
```toml
version = "X.Y.Z"  # Bump patch for deps, minor for new features
```

Update CHANGELOG.md Highlights:
```markdown
- **openmls vX.Y.Z** — description
- **openmls_frb vX.Y.Z** — Rust FFI bindings
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

- [ ] Read release notes for breaking changes
- [ ] Fix Rust compilation errors (if any)
- [ ] `make codegen` — regenerate FRB bindings
- [ ] `make test` — all tests pass
- [ ] `make analyze` — no issues
- [ ] CHANGELOG.md — accurate description
- [ ] `rust/Cargo.toml` — bump `openmls_frb` version
- [ ] `make rust-check` — sync Cargo.lock
- [ ] Commit all changes

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
# upstream crates with tags
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
| `README.md` | Badge | Version badge in header |
| `CLAUDE.md` | Example | Code example in documentation |

Files that need manual update:

| File | What | Description |
|------|------|-------------|
| `rust/Cargo.toml` | `version` | Rust crate version (bump patch for deps update) |
| `rust/Cargo.lock` | Dependencies | Run `make rust-update` after changing Cargo.toml |
| `CHANGELOG.md` | Entry | Document the openmls version change |

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
