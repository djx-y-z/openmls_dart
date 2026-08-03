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
- [Third-party notices](#third-party-notices)
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
- **For running tests:** Rust toolchain (1.89+)

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

### Editor Setup (FVM)

`.fvmrc` and `.vscode/settings.json` are both committed, and `.fvmrc` sets
`"updateVscodeSettings": false` so that fvm manages neither of them.

`fvm install` warns on every run that it is not managing VS Code settings and
asks you to remove that setting. **Leave it as it is.** With fvm managing those
files, every `fvm install` — which `make codegen` triggers twice per run —
rewrites both, so each codegen leaves two modified files unrelated to the
generated bindings; and on a machine where fvm cannot create its own symlink it
writes an absolute, machine-local SDK path into a committed file. The warning is
cosmetic and fvm offers no way to silence it on its own.

On Windows, enable [Developer Mode][windows-dev-mode] before the first
`fvm install`: fvm needs it to create the `.fvm/flutter_sdk` symlink that
`dart.flutterSdkPath` points at.

[windows-dev-mode]: https://learn.microsoft.com/en-us/windows/apps/get-started/enable-your-device-for-development

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
| `make update-template` | Apply a copier template update (needs `copier` on PATH) |
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

# 3. Update Cargo.lock (also regenerates THIRD_PARTY_NOTICES.txt, which is
#    derived from the dependency graph and verified against it in CI)
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

### Setting up Coverage Badge

The CI automatically measures test coverage and can update a badge in your README. To enable this:

1. Create a **public** GitHub Gist at https://gist.github.com
   - Filename: `coverage.json`
   - Content: `{"schemaVersion":1,"label":"coverage","message":"0%","color":"red"}`
2. Copy the **Gist ID** from the URL (e.g., `https://gist.github.com/username/abc123` → `abc123`)
3. Create a **Fine-grained Personal Access Token** at https://github.com/settings/tokens?type=beta
   - Required permission: **Gists → Read and write**
4. Add as repository secret: Settings → Secrets and variables → Actions → New repository secret → `GIST_TOKEN`
5. Add as repository variable: Settings → Secrets and variables → Actions → Variables → New repository variable → `COVERAGE_GIST_ID` (value: the Gist ID from step 2)
6. Update `README.md`: uncomment the coverage badge line and replace `COVERAGE_GIST_ID` with your actual Gist ID

### Setting up pub.dev Publishing

The publish workflow uses OIDC authentication to publish to pub.dev without tokens. This requires a one-time setup.

**On pub.dev:**

1. Go to https://pub.dev and sign in
2. Navigate to your publisher page (or create one)
3. Go to **Admin** → **Automated publishing**
4. Click **Enable automated publishing**
5. Add your GitHub repository: `djx-y-z/openmls_dart`
6. Set **Publishing from**: **GitHub Actions with tag** → tag pattern: `v*`

See [dart.dev/tools/pub/automated-publishing](https://dart.dev/tools/pub/automated-publishing) for details.

**On GitHub (create environment):**

1. Go to your repository → **Settings → Environments**
2. Click **New environment** → name it exactly `pub.dev`
3. Under **Deployment protection rules**:
   - Check **Required reviewers** → add yourself (and/or your team) as reviewer
   - Uncheck **Allow administrators to bypass configured protection rules**
4. Click **Save protection rules**

> The `pub.dev` environment is required by the publish workflow. Protection rules ensure that every publish requires manual approval, preventing accidental releases.

## Third-party notices

`THIRD_PARTY_NOTICES.txt` is generated from the resolved Rust dependency graph
and verified byte-for-byte in CI, in `build-<package>.yml` and in both release
preflights. Regenerate it with `make third-party-notices` after any dependency
change — `make rust-update` already does. `make verify-third-party-notices`
prints the first differing line and the entries unique to each side, so a CI
failure is readable without reproducing it locally.

The crate set comes from `cargo tree --edges normal,build --target all`. The
`--target all` is load-bearing: with a specific triple, cargo still resolves
build-dependencies *and proc-macro subtrees* for the build host, so the file
would differ between a macOS, Linux and Windows contributor — with the crate
count sometimes unchanged, which makes the drift invisible in the summary. The
result over-attributes (build tooling, platform-gated crates a given build never
links); that is the deliberate trade for output that does not change with the
machine.

To re-validate completeness against an independent implementation:

```bash
cargo install cargo-about --locked --features cli   # the CLI needs that feature
cat > /tmp/about.toml <<'EOF'
accepted = ["MIT", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause",
  "BSD-3-Clause", "ISC", "Zlib", "Unicode-3.0", "Unicode-DFS-2016", "CC0-1.0",
  "MPL-2.0", "OpenSSL", "BSL-1.0", "Unlicense", "AGPL-3.0", "CDLA-Permissive-2.0", "0BSD"]
targets = ["x86_64-unknown-linux-gnu", "aarch64-apple-darwin", "x86_64-pc-windows-msvc",
  "aarch64-linux-android", "wasm32-unknown-unknown"]
ignore-build-dependencies = false
ignore-dev-dependencies = true
EOF
cargo about generate --config /tmp/about.toml --manifest-path rust/Cargo.toml \
  --format json --output-file /tmp/about.json
```

Compare the crate names in `/tmp/about.json` with those in
`THIRD_PARTY_NOTICES.txt`: the only crate cargo-about should report that the
inventory omits is this repository's own crate, which is excluded on purpose.
Note that cargo-about resolves build-dependencies for the host exactly as a
per-target `cargo tree` does, so it validates the *contents*, not the
reproducibility.

## Releasing (two stages)

Releasing happens in **two independent stages**, each with its own command and git
tag — the `openmls_frb` native crate and the `openmls` Dart package
are versioned and released separately.

1. **Native crate (stage 1)** — from a clean, up-to-date `main`:
   ```bash
   make release-frb ARGS="--version X.Y.Z"
   ```
   Bumps `rust/Cargo.toml`, stamps the CHANGELOG highlight, and creates a
   **signed** commit + tag `openmls_frb-X.Y.Z`, then pushes. The tag triggers
   the native build workflow, which builds and publishes the platform binaries.
   The commit/tag/push inherit your terminal, so you enter your signing passphrase
   interactively during the command.

2. **Dart package (stage 2)** — after the native build succeeds:
   ```bash
   make release ARGS="--version X.Y.Z"
   ```
   Verifies the stage-1 `openmls_frb-<crate>` release exists, validates with
   a publish dry-run (on the clean, pre-bump tree), bumps `pubspec.yaml`,
   finalizes the CHANGELOG (`[Unreleased]` → `[X.Y.Z]` + compare links; no empty
   `[Unreleased]` is left behind — the next unreleased change recreates it), then
   creates a **signed** commit + tag `vX.Y.Z` and pushes. `publish.yml` publishes
   to pub.dev.

   > **Do not delete the footer `[Unreleased]:` compare link** even when no
   > `## [Unreleased]` heading is present between releases — it is load-bearing
   > (the release scripts read it for the base URL and previous version, and the
   > next unreleased change re-references it). It is intentionally retained, not
   > stale.

**Order matters:** stage 1 must finish first — the published package's build hook
downloads the precompiled `openmls_frb-<crate>` binary, so it must already
exist before you tag the pub.dev release.

> Automated openmls update PRs **do not** bump the `openmls_frb`
> crate or build binaries — dependency updates accumulate on `main` (tested from
> source in CI), and you cut a native release deliberately with `make release-frb`.

## Repository rulesets & tag protection

This repository should be guarded by GitHub **repository rulesets** and a
required-reviewer **environment**, so the native/crypto library's releases can't
be published without the right people and review:

- **Signed commits** required on all branches (configure SSH or GPG signing).
- **`main`** protected (changes land via PR; force-push and deletion blocked).
- **Tags** — all tags creatable only by Admins/Maintainers and must be signed;
  the release-triggering `openmls_frb-*` / `v*` are the critical subset (they
  start native / pub.dev publishing).
- The **native-build publish** waits on a required reviewer (the `native-build`
  environment), mirroring the `pub.dev` environment that gates pub.dev publishing.

The maintainer runbook — what each ruleset does, exact `gh` commands to apply /
verify / roll back, and how to configure the `native-build` environment — is in
[`.github/rulesets/README.md`](.github/rulesets/README.md).

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
