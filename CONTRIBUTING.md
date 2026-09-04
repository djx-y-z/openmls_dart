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

- [Rust toolchain](https://rustup.rs/) (1.91+) — `rust-version` in
  `rust/Cargo.toml` is the authority; this is the same number
- [Dart SDK]( https://dart.dev/get-dart ) (^3.10.0) or Flutter
  (>=3.38.0) — `make setup` installs the pinned Flutter through fvm
- `make` (see **Windows Users** below)
- Git

Nothing here is needed to *use* the published package: consumers get a
precompiled native library through the build hook.

### Fork and Clone

1. Fork the repository on GitHub
2. Clone **your fork**, not this repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/openmls_dart.git
   cd openmls_dart
   ```
3. Add the upstream remote, so you can keep the fork current:
   ```bash
   git remote add upstream https://github.com/djx-y-z/openmls_dart.git
   ```

## Development Setup

### Quick Setup (Recommended)

Run the setup command to install everything automatically:

```bash
make setup
```

It checks that a Rust toolchain is present (and tells you where to get one if
not), installs fvm and the Flutter version pinned in `.fvmrc`, then installs
the Rust tooling the gates need — `cargo-audit`, `cargo-deny` and
`flutter_rust_bridge_codegen` at the exact version this project pins.

Optional, per platform: `make setup-android` (cargo-ndk), `make setup-web`
(wasm-pack), `make setup-fuzz` (nightly + cargo-fuzz).

### Verify Setup

```bash
# Every command this project has, with a one-line description each
make help

# The end-to-end check: this builds the native library if it is missing
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

Every task in this project runs through `make`, which Windows does not ship.
Install it first:

- Chocolatey: `choco install make`
- Scoop: `scoop install make`
- Or work in Git Bash or WSL, where it is already present

Then `make setup` as above.

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

Two of those are load-bearing conventions rather than layout: `lib/src/rust/`
is generated output that `make codegen` rewrites, so an edit there survives
exactly until the next run; and `scripts/` is called through `make`, which is
where the arguments and the environment each script expects are set.

## Making Changes

### Create a Branch

Create a branch for your changes:

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/the-thing-that-is-broken
```

### Types of Contributions

- **Bug fixes** — with a test that fails before the fix
- **Documentation** — including the comments that explain why a constraint exists
- **Tests** — especially for a path only one platform reaches
- **Features** — please open an issue first
- **Performance** — with a measurement, not an argument

### Before You Start

For anything larger than a fix, open an issue and wait for a reply. This
project pins versions, caps constraints and gates releases on grounds that are
written down but not always obvious from the diff — a change can be correct and
still be wrong here, and finding that out in review is expensive for you.

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

Before pushing, run what CI will run: `make test`, `make format-check`,
`make analyze`, and both documentation gates, `make doc` and `make rust-doc`
(`dartdoc_options.yaml` promotes an unresolved reference to an error, and
`make rust-doc` runs under `-D warnings`). If you touched a
`cfg(target_arch = "wasm32")` branch, add `make test-web` — it is the only
check that executes web code, and it needs a driver:
`make test-web CHROMEDRIVER=/path/to/chromedriver`.

### PR Checklist

Before submitting:

- [ ] Code follows the project's coding standards
- [ ] Tests pass locally (`make test`)
- [ ] Static analysis passes (`make analyze`)
- [ ] Code is formatted (`make format-check`)
- [ ] Both documentation gates pass (`make doc`, `make rust-doc`)
- [ ] A touched `wasm32` branch was run in a browser (`make test-web`)
- [ ] Generated bindings are regenerated and committed, not hand-edited
- [ ] Documentation is updated if needed
- [ ] CHANGELOG.md is updated for user-facing changes
- [ ] New constraints, pins and caps carry a comment saying why
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
| `make run-example-web` | Build the WASM and run `example/` in Chrome |
| `make test` | Run all tests |
| `make test-web` | Run the crate's browser tests (headless Chrome; needs a chromedriver) |
| `make coverage` | Run tests with coverage report |
| `make analyze` | Run static analysis |
| `make doc` | Dartdoc GATE — an unresolved doc reference is an error |
| `make rust-doc` | Rustdoc GATE — `-D warnings`, host and wasm32 |
| `make rust-audit` | Check Rust dependencies for vulnerabilities |
| `make rust-deny` | Advisories, licences and sources (cargo-deny) |
| `make rust-check` | Quick Rust type check |
| `make rust-clippy` | Lint the Rust code (warnings are errors) |
| `make rust-test` | Run the crate's native Rust tests |
| `make rust-geiger` | Unsafe-expression census (diagnostic, not a gate) |
| `make third-party-notices` | Regenerate THIRD_PARTY_NOTICES.txt |
| `make verify-third-party-notices` | Verify it still matches the dependency graph |
| `make format` | Format Dart code |
| `make format-check` | Check Dart code formatting |
| `make get` | Get dependencies |
| `make clean` | Clean build artifacts |
| `make check-new-openmls-version` | Check for upstream OpenMLS updates |
| `make check-template-updates` | Check for copier template updates |
| `make update-template` | Apply a copier template update (needs `copier` on PATH) |
| `make check-targets` | Check deployment target consistency (iOS/macOS/Android) |
| `make rust-update` | Update rust/Cargo.lock |
| `make update-changelog` | Update CHANGELOG.md with AI (requires `AI_MODELS` + a key) |
| `make verify-frb-pins` | Verify every file names the same flutter_rust_bridge version |

### Regenerating FRB Bindings

Everything under `lib/src/rust/` is generated from `rust/src/api/`. Change the
Rust API and the Dart side does not follow until you run:

```bash
make codegen
make test
```

Regenerate when you add, remove or change anything in `rust/src/api/` — a
signature, a type, an enum variant, or a doc comment, which flutter_rust_bridge
copies into the Dart output verbatim — and after an OpenMLS bump that moves the
API this crate calls. Commit the result: the bindings are checked in, CI
compares them against what codegen produces, and the runtime asserts that its
own flutter_rust_bridge version equals the one recorded in them.

Never hand-edit a generated file to fix a build. The next `make codegen`
reverts it, which turns a red build into a red build nobody can reproduce.

### Updating Upstream OpenMLS

The CI automatically checks for new openmls releases daily and creates PRs. The automation includes:
- Updating `pubspec.yaml` with new version
- Updating `Cargo.lock` dependencies
- Regenerating FRB bindings
- Generating an AI-written CHANGELOG entry, when `AI_MODELS` names a model that
  has a key — see [Setting up AI Changelog](#setting-up-ai-changelog) below.
  Without one the PR is still opened and labelled `changelog-needed`, and the
  entry is written by hand.

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

# 5. Update CHANGELOG with AI (see "Setting up AI Changelog" below)
AI_MODELS=anthropic/claude-opus-5 ANTHROPIC_API_KEY=xxx \
  make update-changelog ARGS="--version vX.Y.Z"

# 6. Test
make test
```

### Setting up AI Changelog

Which model writes the entry is configuration, not code: `AI_MODELS` holds an
ordered, comma-separated list of `provider/model` entries and the first one that
has a key and answers wins. **There is no default** — unset means no model is
called and the entry is simply not written, which is also how a project says
"no AI here".

To enable it in CI:

1. Get a key from the provider you want:
   [Anthropic](https://console.anthropic.com/settings/keys),
   [Google AI Studio](https://aistudio.google.com/apikey) or
   [OpenRouter](https://openrouter.ai/keys).
2. Add it as a repository **secret** (Settings → Secrets and variables →
   Actions): `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` or `OPENROUTER_API_KEY`.
3. Add a repository **variable** `AI_MODELS` naming the models to try, in
   order — e.g. `anthropic/claude-opus-5,google/gemini-3.5-flash-lite`.
   An entry whose key is unset is skipped; a malformed one is warned about.
4. Optionally add the variable `AI_EFFORT` (`low` | `medium` | `high` | `xhigh`
   | `max`, default `medium`) to say how hard the model should think.

The next entry is tried only when a model produced **no** answer — a network
failure, an auth/rate-limit/server status, a refusal, or a response cut off at
the token limit — never because an answer read poorly, which would make the
CHANGELOG silently inconsistent. If nothing answers, the entry is left unwritten
and the pull request is labelled `changelog-needed`.

What the entry is classified against lives in
`.github/agent-prompts/changelog-scope.md` — this project's own statement of
what it binds and exposes. It is generated once and never overwritten by a
template update, so keep it current: an upstream change that cannot be tied to
something named there is invisible to your users, and an out-of-date list is how
somebody else's release notes end up described as your features.

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

### Setting up the GitHub App

Several workflows open pull requests, file issues or push signed commits. None
of them uses the default `GITHUB_TOKEN` for that: a pull request opened with it
does not trigger workflows, which would leave the four-platform matrix — the
only oracle those pull requests have — silently absent.

1. Create a GitHub App (Settings → Developer settings → GitHub Apps) and install
   it on this repository
2. Repository permissions it needs: **Contents → Read and write**,
   **Pull requests → Read and write**, **Issues → Read and write**,
   **Workflows → Read and write** (the last one only if the automation may ever
   touch `.github/workflows/`, which template updates do)
3. Generate a private key and add it as a repository secret:
   Settings → Secrets and variables → Actions → New repository secret →
   `APP_PRIVATE_KEY`
4. Add the App's **Client ID** as a repository variable → `APP_CLIENT_ID`.
   This is the `Iv23li…` string on the App's page, **not** the numeric App ID
   shown beside it; `create-github-app-token` fails the mint if given the wrong
   one, and that failure takes out the only credential these workflows can write
   with.

### Setting up the repair and review agents

Two workflows run an agent: `repair-build.yml` attempts a fix when `main` goes
red and reports when it cannot, and `ai-review.yml` reviews pull requests and
leaves one comment. Both are **off entirely** until an engine is named — an
unset `AGENT_ENGINE` produces a notice and no run, which is what an
unconfigured repository is supposed to look like.

1. Choose the engine: variable `AGENT_ENGINE` = `claude-code` or `opencode`
2. Name the model — there is deliberately no default:
   - `claude-code` → variable `AGENT_CLAUDECODE_MODEL`, secret
     `ANTHROPIC_API_KEY`
   - `opencode` → variable `AGENT_OPENCODE_MODEL` in `provider/model` form
     (an aggregator's model half carries its own slash, e.g.
     `openrouter/openai/gpt-5.6-luna`), and the provider's own key as a secret.
     Which variable that key is read from is `AGENT_OPENCODE_PROVIDER_ENV`,
     default `OPENROUTER_API_KEY`; `AGENT_OPENCODE_API_KEY` overrides it.
3. Optional: `REVIEW_AGENT_ENGINE`, `REVIEW_AGENT_CLAUDECODE_MODEL` and
   `REVIEW_AGENT_OPENCODE_MODEL` run the reviewer on a different model from the
   repair agent — worth having, since a reviewer drawn from the same family as
   the writer shares its blind spots. Each falls back to the `AGENT_*` setting.
4. Optional: `REVIEW_ALLOWED_BOTS`, a comma-separated list including your App's
   slug. Only the `claude-code` engine reads it, and without it that engine
   refuses to review pull requests opened by a bot — which is most of them here.

Both agents hold no write credential: the job that runs the agent cannot reach
the repository, and the job that publishes runs no agent. Read the header of
either workflow before changing that split.

The reviewer **gates nothing** and has no verdict meaning "approved". Before
wiring it to anything that blocks a merge, measure its false-positive rate by
replaying merged pull requests through it — published measurements put roughly
four in five findings of this kind in the false-positive bin, and three runs
over one unchanged diff here produced three different lists.

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

## The flutter_rust_bridge pin

Five files record it, and two of them are compared with `==` at runtime:
`frb_generated.dart` carries the version of the generator that produced it, and
`RustLib.init()` throws unless the runtime package's version is the same string.
So the constraint in `pubspec.yaml` is one version written as a range,
`>=X.Y.Z <X.Y.Z+1` — a caret admits versions that assert rejects, and a bare
`X.Y.Z` admits only the right one but makes the package unpublishable, because
`dart pub publish` warns that a single-version constraint "should allow more
than one version" and exits 65 on any warning.

`make verify-frb-pins` checks all five agree and that the constraint is written
in that form. It runs in CI on the Linux leg and costs five file reads — no
build, no network. Moving the version means moving `frb_version` in
`.copier-answers.yml`, then `make setup-frb-codegen` and `make codegen` so the
installed generator and the committed bindings match; a pull request that edits
one of the five is wrong by construction, which is why Dependabot is told to
leave `flutter_rust_bridge` alone.

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
