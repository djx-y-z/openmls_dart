# openmls Scripts

Development scripts for managing the openmls Dart package.

> **Important:** Always use `make` commands instead of calling scripts directly.
> The Makefile provides the correct environment and arguments.

## Scripts

| Script | Description | Makefile Command |
|--------|-------------|------------------|
| `check_new_upstream_version.dart` | Check for new upstream openmls version | `make check-new-openmls-version` |
| `check_exists_frb_release.dart` | Check if FRB release exists on GitHub | `make check-exists-openmls-frb-release` |
| `check_template_updates.dart` | Check for new copier template version | `make check-template-updates` |

## Checking for Upstream Updates

Check for new openmls releases and optionally update rust/Cargo.toml:

```bash
# Just check for updates
make check-new-openmls-version

# Check and update rust/Cargo.toml
make check-new-openmls-version ARGS="--update"

# Update to specific version
make check-new-openmls-version ARGS="--update --version openmls-v0.8.1"

# Force update even if versions match
make check-new-openmls-version ARGS="--update --force"

# Output JSON for CI integration
make check-new-openmls-version ARGS="--json"
```

This script is used by both local development and the `check-openmls-updates.yml` workflow.

## Checking for Template Updates

Check for new versions of the copier template:

```bash
# Just check for updates
make check-template-updates

# Check against specific version
make check-template-updates ARGS="--version v1.7.0"

# Output JSON for scripting
make check-template-updates ARGS="--json"

# CI mode (write outputs to file)
make check-template-updates ARGS="--ci-output /path/to/output"
```

This script is used by the `check-template-updates.yml` workflow, which applies the update with `copier update` and opens a pull request carrying the result — a draft when copier could not merge something, or when the new version did not land in `.copier-answers.yml`.

## Regenerating FRB Bindings

When modifying Rust API code in `rust/src/api/`:

```bash
# Regenerate Flutter Rust Bridge bindings
make codegen

# Test
make test
```

When updating openmls version:

```bash
# Option 1: Automatic update (recommended)
make check-new-openmls-version ARGS="--update"

# Option 2: Manual update
# 1. Edit rust/Cargo.toml - update openmls-protocol tag to new version
# 2. Update Cargo.lock
cd rust && cargo update && cd ..

# Test
make test
```

## Build System

Native libraries are managed via **native assets** (Dart 3.10+).

- **End users**: Precompiled binaries are downloaded from GitHub Releases (no Rust needed)
- **Developers**: Local build from source (requires Rust + protoc) takes priority

The build hook (`hook/build.dart`) handles library resolution:
1. Checks for local Rust build in `rust/target/release/`
2. If not found, downloads precompiled binary from GitHub Releases
3. SHA256 checksums verify download integrity

For local development:
```bash
# Build library from source (creates rust/target/release/)
make build

# Build for specific target (cross-compilation)
make build ARGS="--target aarch64-apple-ios"

# Build for Android (requires cargo-ndk + Android NDK)
make build-android ARGS="--target aarch64-linux-android"

# Build WASM for web (requires wasm-pack)
make build-web

# Run tests (uses local build)
make test
```

## CI Integration

The `check-openmls-updates.yml` workflow:
1. Runs daily to check for new openmls releases
2. Compares with current version in `rust/Cargo.toml`
3. Creates a PR if update available
4. After merge, tests run automatically

The `check-template-updates.yml` workflow:
1. Runs daily to check for new copier template versions
2. Compares with current version in `.copier-answers.yml`
3. Applies the update with `copier update` and reports what it could not merge
4. Runs the same three gates the pre-commit hook runs, and records the results
5. Opens a PR with the applied update — a draft when it needs a human to finish it
