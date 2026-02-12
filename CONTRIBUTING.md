# Contributing to openmls_dart

Thank you for your interest in contributing to openmls_dart! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Coding Standards](#coding-standards)
- [Advanced Development](#advanced-development)
- [Security Considerations](#security-considerations)

## Code of Conduct

Please be respectful and considerate of others. We expect all contributors to:

- Use welcoming and inclusive language
- Be respectful of differing viewpoints and experiences
- Gracefully accept constructive criticism
- Focus on what is best for the community

## Getting Started

### Prerequisites

- [Dart SDK](https://dart.dev/get-dart) (3.10.0+)
- Git
- **For running tests:** Rust toolchain (1.88+)

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/openmls_dart.git
   cd openmls_dart
   ```
3. Add upstream remote:
   ```bash
   git remote add upstream https://github.com/djx-y-z/openmls_dart.git
   ```

## Development Setup

### Quick Setup (Recommended)

Run the setup command to install everything automatically:

```bash
make setup
```

This will:
1. Check that Rust toolchain is installed (shows instructions if not)
2. Install FVM (Flutter Version Management) and project's Flutter version
3. Install cargo-audit for Rust dependency vulnerability scanning
4. Install flutter_rust_bridge_codegen for binding generation
5. Get all dependencies

### Verify Setup

```bash
# Show all available commands
make help

# Run tests to ensure everything works
make test
```

### Windows Users

On Windows, you need to install `make` first:
- Via Chocolatey: `choco install make`
- Via Scoop: `scoop install make`
- Or use Git Bash / WSL

Then run `make setup` as above.

### Project Structure

```
openmls_dart/
├── lib/                        # Main library code
│   ├── openmls.dart            # Public API exports
│   └── src/
│       ├── openmls.dart        # Initialization
│       └── rust/               # Auto-generated FRB bindings
├── rust/                       # Rust source code
│   ├── Cargo.toml              # Rust dependencies (OpenMLS version here)
│   └── src/
│       ├── api/                # FRB API functions (engine.rs is the main API)
│       ├── encrypted_db.rs     # EncryptedDb (SQLCipher native / Web Crypto WASM)
│       └── snapshot_storage.rs # SnapshotStorageProvider (HashMap-based)
├── test/                       # Test files
├── example/                    # Example Flutter application
├── scripts/                    # Build scripts (use via Makefile!)
├── hook/                       # Dart Build Hook for library download
└── Makefile                    # Entry point for all commands
```

## Making Changes

### Create a Branch

Create a branch for your changes:

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/your-bug-fix
```

### Types of Contributions

We welcome:

- **Bug fixes** - Fix issues in existing code
- **Documentation** - Improve docs, examples, comments
- **Tests** - Add or improve test coverage
- **Features** - New functionality (please discuss first)
- **Performance** - Optimizations with benchmarks

### Before You Start

For major changes:
1. Open an issue first to discuss the change
2. Wait for feedback from maintainers
3. This helps avoid wasted effort on changes that won't be merged

## Testing

### Running Tests

```bash
# Run all tests
make test

# Run specific test file
make test ARGS="test/group_lifecycle_test.dart"

# Run with verbose output
make test ARGS="--reporter=expanded"
```

### Writing Tests

- Place tests in the `test/` directory
- Name test files with `_test.dart` suffix
- Test both success and error cases
- Include edge cases for protocol operations

Example test structure:

```dart
import 'dart:typed_data';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:openmls/openmls.dart';

void main() {
  group('Group creation', () {
    test('creates group with default config', () async {
      await Openmls.init();
      final engine = await MlsEngine.create(
        dbPath: ':memory:',
        encryptionKey: Uint8List(32),
      );
      final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
      final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final signerBytes = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: keyPair.privateKey(),
        publicKey: keyPair.publicKey(),
      );

      final result = await engine.createGroup(
        config: MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite),
        signerBytes: signerBytes,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: keyPair.publicKey(),
      );

      expect(result.groupId, isNotEmpty);
    });
  });
}
```

### Coverage

```bash
make coverage
```

## Submitting Changes

### Commit Messages

Write clear, concise commit messages:

```
type: short description

Longer description if needed.

Fixes #123
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `test`: Adding or updating tests
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `perf`: Performance improvement
- `chore`: Maintenance tasks

### Pull Request Process

1. Update your branch with upstream:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. Push your branch:
   ```bash
   git push origin feature/your-feature-name
   ```

3. Create a Pull Request on GitHub

4. In your PR description:
   - Describe what the change does
   - Reference any related issues
   - Note any breaking changes
   - Include testing steps if applicable

5. Wait for review - maintainers will review and may request changes

### PR Checklist

Before submitting:

- [ ] Code follows the project's coding standards
- [ ] Tests pass locally (`make test`)
- [ ] Static analysis passes (`make analyze`)
- [ ] Code is formatted (`make format-check`)
- [ ] Documentation is updated if needed
- [ ] CHANGELOG.md is updated for user-facing changes
- [ ] Commit messages are clear and follow conventions

## Coding Standards

### Dart Style

Follow the [Effective Dart](https://dart.dev/effective-dart) guidelines:

```bash
# Format code
make format

# Check formatting without changes
make format-check

# Run static analysis
make analyze
```

- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions small and focused

### Memory Safety (FRB Architecture)

This library uses Flutter Rust Bridge (FRB) with OpenMLS (pure Rust):

- **Memory is managed automatically** by Rust's ownership system
- **No manual cleanup needed** - FRB handles all resource deallocation
- **No `dispose()` calls** - Rust drops resources when they go out of scope

When adding new Rust API functions to `MlsEngine`:

- Return `Result<T, String>` for error handling (FRB converts to Dart exceptions)
- Methods on `MlsEngine` access storage via `self.db` (EncryptedDb)
- Storage is loaded into a SnapshotStorageProvider, operated on, then saved back

Example Rust API:

```rust
impl MlsEngine {
    pub async fn my_new_function(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let (provider, group) = self.load_for_group(&group_id_bytes).await?;
        // ... operate on group using provider ...
        self.commit(&provider, Some(&group_id_bytes)).await?;
        Ok(result)
    }
}
```

## Advanced Development

### Makefile Commands Reference

All development tasks should be done via Makefile:

| Command | Description |
|---------|-------------|
| `make setup` | Install all required tools (Rust check, FVM, cargo-audit, FRB codegen) |
| `make setup-fvm` | Install FVM and project Flutter version only |
| `make setup-rust-tools` | Install Rust tools (cargo-audit, flutter_rust_bridge_codegen) |
| `make setup-web` | Install wasm-pack for web builds (optional) |
| `make setup-android` | Install cargo-ndk for Android builds (optional) |
| `make help` | Show all available commands |
| `make codegen` | Regenerate FRB bindings |
| `make build` | Build Rust library locally (native) |
| `make build-web` | Build WASM for web |
| `make build-android` | Build for Android |
| `make test` | Run all tests |
| `make coverage` | Run tests with coverage report |
| `make analyze` | Run static analysis |
| `make rust-audit` | Check Rust dependencies for vulnerabilities |
| `make rust-check` | Quick Rust type check |
| `make format` | Format Dart code |
| `make format-check` | Check Dart code formatting |
| `make get` | Get dependencies |
| `make clean` | Clean build artifacts |
| `make check-new-openmls-version` | Check for upstream OpenMLS updates |
| `make check-template-updates` | Check for copier template updates |
| `make check-targets` | Check deployment target consistency (iOS/macOS/Android) |
| `make rust-update` | Update rust/Cargo.lock |
| `make update-changelog` | Update CHANGELOG.md with AI (requires AI_MODELS_TOKEN) |

### Regenerating FRB Bindings

When modifying Rust API code in `rust/src/api/`:

```bash
# Regenerate Flutter Rust Bridge bindings
make codegen

# Test the new bindings
make test
```

**When to regenerate:**
- After modifying Rust API code in `rust/src/api/`
- After updating OpenMLS version (if API changed)

### Updating Upstream OpenMLS

**Automatic (CI):** A daily workflow checks for new OpenMLS releases and creates PRs.

**Manual update:**

```bash
# 1. Check for updates
make check-new-openmls-version

# 2. Apply update
make check-new-openmls-version ARGS="--update"

# 3. Update Cargo.lock
make rust-update

# 4. Regenerate bindings (if API changed)
make codegen

# 5. Update CHANGELOG (requires AI_MODELS_TOKEN)
AI_MODELS_TOKEN=xxx make update-changelog ARGS="--version vX.Y.Z"

# 6. Test
make test
```

### Setting up AI Changelog

To enable AI-powered changelog generation in CI:

1. Create a Personal Access Token at https://github.com/settings/tokens
2. Required permission: **Models -> Read only**
3. Add as repository secret: Settings -> Secrets and variables -> Actions -> `AI_MODELS_TOKEN`

## Security Considerations

This is a **cryptographic library**. Security is paramount.

### Reporting Security Issues

**Do not open public issues for security vulnerabilities.**

Instead, report security issues privately via GitHub's private vulnerability reporting feature.

### Security Review Checklist

For code changes:

- [ ] No hardcoded keys or secrets
- [ ] No key material in logs or error messages
- [ ] `Openmls.init()` called before any operations
- [ ] `':memory:'` databases used only for testing (not production)
- [ ] Encryption key stored in platform secure storage
- [ ] Error handling doesn't leak sensitive information

See [SECURITY.md](SECURITY.md) for full security guidelines.

## Questions?

- Open an issue for general questions
- Check existing issues before creating new ones

Thank you for contributing!
