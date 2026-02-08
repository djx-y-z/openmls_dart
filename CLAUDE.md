# openmls - Claude Code Configuration

## Important Rules

**ALWAYS use Makefile commands.** Never call scripts or cargo directly. The Makefile is the single entry point for all operations.

```bash
# Correct - pass arguments via ARGS variable
make build ARGS="--target aarch64-apple-darwin"
make codegen
make test
make analyze ARGS="--fatal-infos"

# Wrong - never do this
cargo build --release
flutter_rust_bridge_codegen generate
make build --target aarch64-apple-darwin  # make interprets --target as its own flag!
```

## Available Makefile Commands

### Setup
```bash
make setup                        # Full setup (FVM + Rust tools)
make setup-fvm                    # Install FVM + Flutter only
make setup-rust-tools             # Install Rust tools (cargo-audit, frb_codegen)
make setup-web                    # Install web build tools (wasm-pack)
make setup-android                # Install Android build tools (cargo-ndk)
```

### Code Generation
```bash
make codegen                      # Generate Dart bindings from Rust code
```

**Note:** `make codegen` automatically creates a `.skip_openmls_hook` marker file to prevent Build Hooks from downloading libraries during codegen. The marker is automatically removed after completion.

### Build
```bash
make build                              # Build for current platform (debug)
make build ARGS="--release"             # Build for current platform (release)
make build ARGS="--target <target>"     # Build for specific Rust target
make build-android                      # Build for Android (all ABIs)
make build-android ARGS="--target arm64-v8a"  # Build for specific Android ABI
make build-web                          # Build WASM for web
```

### Rust Quality
```bash
make rust-check                   # Check Rust code compiles
make rust-audit                   # Audit Rust dependencies for vulnerabilities
```

### Dart Quality
```bash
make test                                # Run all tests
make test ARGS="test/example_test.dart"  # Run specific test file
make coverage                            # Run tests with coverage report
make analyze                             # Run static analysis
make analyze ARGS="--fatal-infos"        # Strict analysis
make format                              # Format Dart code
make format-check                        # Check formatting without changes
make doc                                 # Generate documentation
```

### Utilities
```bash
make get                          # Get dependencies
make clean                        # Clean build artifacts (including rust/target)
make version                      # Show current crate version
make rust-update                  # Update Cargo.lock
make check-new-openmls-version  # Check for new upstream openmls version
make check-new-openmls-version ARGS="--update"  # Apply update
make check-template-updates       # Check for copier template updates
make update-changelog ARGS="--version vX.Y.Z"  # Update CHANGELOG with AI
make help                         # Show all available commands
```

## Project Overview

Dart Flutter Rust Bridge wrapper for openmls.

### Key Features
- Flutter Rust Bridge integration for type-safe FFI
- Pre-built native libraries for all platforms
- Automated builds via GitHub Actions
- Web/WASM support

### Upstream Repository
- **openmls**: https://github.com/openmls/openmls

## Project Structure

```
openmls/
├── lib/                            # Dart library code
│   └── src/rust/                   # FRB-generated Dart bindings
├── rust/                           # Rust crate
│   ├── Cargo.toml                  # Rust dependencies + version
│   └── src/
│       ├── lib.rs                  # Crate entry point
│       ├── frb_generated.rs        # FRB-generated Rust code
│       └── api/                    # Your Rust API modules
├── scripts/                        # Utility scripts (use via Makefile!)
├── hook/                           # Dart Build Hook for library download
├── test/                           # Tests
├── Makefile                        # Entry point for all commands
├── pubspec.yaml                    # Package config
├── flutter_rust_bridge.yaml        # FRB configuration
└── .github/workflows/              # CI/CD workflows
```

## Development Workflow

### 1. Implement Rust API

Add your Rust functions in `rust/src/api/`:

```rust
// rust/src/api/greeting.rs
pub fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}
```

Register the module in `rust/src/api/mod.rs`:

```rust
pub mod greeting;
```

### 2. Generate Dart Bindings

```bash
make codegen
```

This generates Dart code in `lib/src/rust/`.

### 3. Build Native Library

```bash
# For current platform
make build

# For specific target
make build ARGS="--target aarch64-apple-darwin"
```

### 4. Run Tests

```bash
make test
```

## Update Crate Version

Version is stored in `rust/Cargo.toml`.

```bash
# 1. Edit rust/Cargo.toml - update version
# 2. Run tests
make test

# 3. Commit and push (CI will build native libraries)
git add rust/Cargo.toml
git commit -m "Bump crate version to X.Y.Z"
git push
```

## Native Library Version

The openmls version is specified in `pubspec.yaml`:

```yaml
openmls:
  native_version: "1.0.0"  # Current version
```

To check/update the version:
```bash
make check-new-openmls-version              # Check for updates
make check-new-openmls-version ARGS="--update"  # Apply update
make rust-update                    # Update Cargo.lock after version bump
make update-changelog ARGS="--version v1.0.0"  # Generate AI changelog entry
```

### AI-Powered Changelog

The `update-changelog` command uses GitHub Models API to analyze release notes and generate changelog entries. Requires `AI_MODELS_TOKEN` environment variable:

```bash
# Get token from https://github.com/settings/tokens (Models → Read only)
AI_MODELS_TOKEN=xxx make update-changelog ARGS="--version v1.0.0"
```

## Supported Platforms

| Platform | Rust Target | Library |
|----------|------------|---------|
| Linux x86_64 | x86_64-unknown-linux-gnu | libopenmls_frb.so |
| Linux arm64 | aarch64-unknown-linux-gnu | libopenmls_frb.so |
| macOS arm64 | aarch64-apple-darwin | libopenmls_frb.dylib |
| macOS x86_64 | x86_64-apple-darwin | libopenmls_frb.dylib |
| Windows x86_64 | x86_64-pc-windows-msvc | openmls_frb.dll |
| iOS device | aarch64-apple-ios | libopenmls_frb.dylib |
| iOS simulator arm64 | aarch64-apple-ios-sim | libopenmls_frb.dylib |
| iOS simulator x86_64 | x86_64-apple-ios | libopenmls_frb.dylib |
| Android arm64 | aarch64-linux-android | libopenmls_frb.so |
| Android arm32 | armv7-linux-androideabi | libopenmls_frb.so |
| Android x86_64 | x86_64-linux-android | libopenmls_frb.so |
| Web (WASM) | wasm32-unknown-unknown | openmls_frb.wasm |


## Security Considerations

> **Important:** See [SECURITY.md](SECURITY.md) for full security policy and best practices.

### Supply Chain Security
- All native libraries are built from source in GitHub Actions
- SHA256 checksums verify downloaded libraries
- Pin to specific upstream releases

### Code Review Checklist
1. No hardcoded keys or secrets
2. Memory properly freed after use
3. Sensitive data zeroed before freeing
4. No timing side-channels

## FVM (Flutter Version Management)

This project uses FVM for consistent Flutter/Dart versions.

**Version:** Flutter 3.38.4

FVM is automatically installed by `make setup`.

## Windows Users

On Windows, install `make` first:
- Chocolatey: `choco install make`
- Scoop: `scoop install make`
- Or use Git Bash / WSL

## Changelog Format

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format:

```markdown
## X.Y.Z

### Added
- New features

### Changed
- Changes in existing functionality

### Fixed
- Bug fixes

### Security
- Security-related changes
```

## Publishing Checklist

```bash
# 1. Run quality checks
make analyze
make test
make format-check

# 2. Update version in pubspec.yaml
# 3. Update CHANGELOG.md

# 4. Dry run
make publish-dry-run

# 5. Create annotated tag and push (CI will publish)
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

## Claude Skills

Claude Code skills available in this project (invoke with `/<skill>` or used automatically by Claude):

| Skill | Description |
|-------|-------------|
| `release-package` | Prepare a new version for publication to pub.dev |
| `update-template` | Update copier template to latest version |
