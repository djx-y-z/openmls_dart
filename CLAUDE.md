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
make setup-rust-tools             # Install Rust tools (cargo-audit, cargo-deny, frb_codegen)
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
make build                              # Build for current platform (always release)
make build ARGS="--target <target>"     # Build for specific Rust target
make build-android                      # Build for Android (all ABIs)
make build-android ARGS="--target arm64-v8a"  # Build for specific Android ABI
make build-web                          # Build WASM for web
```

### Web

```bash
make test-web                     # Browser suite: headless Chrome, real DOM APIs
make test-web CHROMEDRIVER=/path/to/chromedriver   # pin the driver (see below)
make test-web ARGS="--release"    # release profile, when the suite gets slow
make test-web ARGS="-- --nocapture"                # show console::log output
```

`make test-web` is the **only** command here that EXECUTES web code. `make test`
is the Dart VM and `make build-web` only compiles, so without it every
`cfg(target_arch = "wasm32")` branch in the crate is covered by nothing — and
those branches are exactly the ones nothing else can reach, because a wasm32
body is a *different implementation* of the same function rather than the same
code on another host.

⚠ **Pin chromedriver.** wasm-pack looks for one on `$PATH`, honours
`--chromedriver`, and otherwise DOWNLOADS THE LATEST — an unpinned network
fetch on every run. The `CHROMEDRIVER` **environment variable is not honoured**
— wasm-pack overwrites it with its own — hence the make variable, which becomes
the flag. CI resolves the runner image's preinstalled driver and fails closed if
there is none.

⚠ **That pins the DRIVER and not the BROWSER, and a green run is no evidence
otherwise.** With no `webdriver.json` and no `WASM_BINDGEN_TEST_WEBDRIVER_JSON`,
the test runner sends empty capabilities and ChromeDriver launches whatever
Chrome is installed. To pin it, point that variable at a file carrying
`{"goog:chromeOptions": {"binary": "<browser path>"}}`; the run then prints `Ok`
instead of `Not found` under "Try find webdriver.json". `Ok` alone only proves
the file was READ — check that a deliberately bad path fails, or the pin may be
parsed and dropped.

⚠ **A mismatched driver does not necessarily fail loudly**, so "it went green"
does not mean the driver matched the browser.

⚠ **`WASM_BINDGEN_TEST_TIMEOUT` is raised to 120 s in the Makefile.** The
browser runs every test on one JS thread, so a test that blocks it starves the
callbacks every concurrently-driven test is waiting on. The failure that
produces names whichever test was scheduled LAST rather than the slow one, so it
reads as a hang somewhere unrelated.

### Rust Quality
```bash
make rust-check                   # Check Rust code compiles
make rust-clippy                  # Lint Rust code with clippy (warnings = errors)
make rust-doc                     # Rustdoc GATE: intra-doc links, -D warnings
make rust-geiger                  # Unsafe-expression census (DIAGNOSTIC, not gated)
make rust-audit                   # Audit Rust dependencies for vulnerabilities
make rust-deny                    # Check advisories/licenses/sources (cargo-deny)
```

### Fuzzing
```bash
make setup-fuzz                   # One-time: install nightly + cargo-fuzz
make fuzz-list                    # List available fuzz targets
make fuzz-seed                    # Generate seed corpus (extend rust/fuzz/examples/gen_corpus.rs)
make fuzz ARGS="mls_message -- -max_total_time=60"  # Run a fuzz target
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
make doc                                 # Generate documentation (FAILS on unresolved doc refs)
```

**`make doc` is a gate, not just a generator.** `dartdoc_options.yaml` promotes
`unresolved-doc-reference` to an error, so the target exits non-zero when a
docstring references a symbol dartdoc cannot resolve, and CI runs it. This
matters because `lib/src/rust/` is generated from the Rust docstrings in
`rust/src/api/`: a Rust intra-doc reference (``[`Type::method`]``) is copied
verbatim and reaches pub.dev as a dead link. Write references to the Dart
surface in **plain backticks with the Dart camelCase name**.

⚠ The gate cannot see a *wrong* name: plain backticks resolve nothing, so they
never warn. It proves every `[...]` reference points at a real symbol, not that
the prose names the right one.

`make rust-doc` is the counterpart for the Rust side — the intra-doc links in
the parts of `rust/src/` that stay in Rust, which `make doc` cannot see. It is
also a gate (`RUSTDOCFLAGS=-D warnings`), and CI runs it.

`dartdoc_options.yaml` is `.pubignore`d on purpose — pub.dev runs dartdoc itself
and would honour the same promotion, which could break documentation generation
for an already-published version.

### Utilities
```bash
make get                          # Get dependencies
make clean                        # Clean build artifacts (including rust/target)
make version                      # Show current crate version
make rust-update                  # Update Cargo.lock + regenerate notices
make third-party-notices          # Regenerate THIRD_PARTY_NOTICES.txt
make verify-third-party-notices   # Check it matches the dependency graph
make verify-frb-pins              # Check every file names the same FRB version
make check-new-openmls-version  # Check for new upstream openmls version
make check-new-openmls-version ARGS="--update"  # Apply update
make check-template-updates       # Check for copier template updates
make update-template ARGS="--version vX.Y.Z"  # Apply a template update (runs copier)
make check-targets                # Check deployment targets (iOS/macOS/Android)
make check-targets ARGS="--ios --set 14.0"  # Set iOS target everywhere
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

## Release Flow (two stages)

Releasing is **two independent stages**, each with its own command and tag. The
`openmls_frb` native crate (`rust/Cargo.toml` version) and the `openmls`
Dart package (`pubspec.yaml` version) are versioned and released separately.

- **Automated openmls update PRs do NOT bump the `openmls_frb`
  crate version and do NOT build binaries** — they only update the dependency +
  CHANGELOG. Updates accumulate on `main` (CI builds from source and tests them).
- **The native build is triggered by pushing a `openmls_frb-<version>` tag**
  (created by `make release-frb`), not by pushing to `main`. The tag must equal the
  `rust/Cargo.toml` crate version (the workflow validates this).
- **Stage 1 must finish before stage 2** — the published Dart package's build hook
  downloads the precompiled `openmls_frb-<crate>` binary, so it must already
  exist before you tag the pub.dev release.

### Stage 1 — release the native crate

```bash
# From a clean, up-to-date main. You enter your signing passphrase during the
# command (commit + tag are signed; the terminal is inherited).
make release-frb ARGS="--version X.Y.Z"            # bump + commit + tag + push
make release-frb ARGS="--version X.Y.Z --no-push"  # local only
```

Bumps `rust/Cargo.toml`, stamps the CHANGELOG highlight, signs a commit + tag
`openmls_frb-X.Y.Z`, and pushes — which triggers the native build workflow.
Choose `X.Y.Z` by SemVer of the FFI surface (a non-empty `lib/src/rust/` codegen
diff since the last frb release means the wire signature moved).

### Stage 2 — release the Dart package

```bash
# After the stage-1 native build has finished. Same interactive signing flow.
make release ARGS="--version X.Y.Z"   # verify frb binary + bump + finalize
                                      # CHANGELOG + dry-run + signed commit/tag/push
```

Verifies the stage-1 `openmls_frb-<crate>` release exists, runs
`make publish-dry-run` (on the clean, pre-bump tree), bumps `pubspec.yaml`,
finalizes the CHANGELOG (`[Unreleased]` → `[X.Y.Z]` + compare links; no empty
`[Unreleased]` is left behind), then signs a commit + tag `vX.Y.Z` and pushes —
`publish.yml` publishes to pub.dev.

Repository rulesets restrict who can create the `openmls_frb-*` / `v*` release
tags, and a required-reviewer `native-build` environment gates the native publish.
See `.github/rulesets/README.md`.

## Native Library Version

Two different versions live here and neither is in `pubspec.yaml`:

- **The upstream openmls version** is the git tag in `rust/Cargo.toml`
  (`tag = "openmls-v0.9.0"` on each of the six openmls dependency lines — five
  crates, with `openmls` declared a second time for `wasm32`). This
  is what `make check-new-openmls-version` reads and updates.
- **The native crate version** is `[package] version` in `rust/Cargo.toml`.
  `hook/build.dart` parses it (`_readVersion`) and downloads
  `openmls_frb-<version>` from GitHub Releases, so the archive's copy of
  `rust/Cargo.toml` is what decides which binary a consumer gets. It is also
  why stage 1 has to finish before stage 2.

To check/update the version:
```bash
make check-new-openmls-version              # Check for updates
make check-new-openmls-version ARGS="--update"  # Apply update
make rust-update                    # Update Cargo.lock after version bump
make update-changelog ARGS="--version v1.0.0"  # Generate AI changelog entry
```

### AI-Powered Changelog

`make update-changelog` (and the CHANGELOG entry `make update-template` writes)
hand the release notes to an AI model. **Which** model is configuration, not
code: `AI_MODELS` holds an ordered, comma-separated list of `provider/model`
entries and the first one that has a key and answers wins.

**There is no default list.** With `AI_MODELS` unset nothing is called and the
entry is simply not written — a model that writes into this repository's
CHANGELOG is one somebody named, not one the template picked. Keys without a
list is a misconfiguration rather than an opt-out, so that case warns loudly
instead of going quiet.

```bash
AI_MODELS=anthropic/claude-opus-5 ANTHROPIC_API_KEY=xxx \
  make update-changelog ARGS="--version v1.0.0"

# Pick a different model, or a different order, without touching the code
AI_MODELS=google/gemini-3.5-flash-lite ANTHROPIC_API_KEY=… GEMINI_API_KEY=… \
  make update-changelog ARGS="--version v1.0.0"
```

| Variable | Purpose |
|----------|---------|
| `AI_MODELS` | Ordered `provider/model` list, highest priority first. **Required** — there is no default; unset means no model is called. |
| `ANTHROPIC_API_KEY` | Key for `anthropic/…` entries ([console](https://console.anthropic.com/settings/keys)). |
| `GEMINI_API_KEY` | Key for `google/…` entries ([AI Studio](https://aistudio.google.com/apikey)). |
| `OPENROUTER_API_KEY` | Key for `openrouter/…` entries ([keys](https://openrouter.ai/keys)). |
| `AI_EFFORT` | How hard the model is asked to think: `low`, `medium` (default), `high`, `xhigh`, `max`. Ignored by providers that have no such knob. |

An entry whose key is unset is skipped silently — that is how the list says
"use this if it is available". A malformed entry or an unknown provider is
warned about loudly, because it is a typo, not a choice.

Keys are read from the environment and go out in one request header each
(`x-api-key`, `x-goog-api-key`, `Authorization`). They are never put in a URL,
in process arguments, or in the prompt, and nothing logs them — the priority
line prints model ids and variable *names* only. Provider error bodies are
quoted into logs and pull-request output, so the key is stripped from those
before they are reported.

`openrouter` is an aggregator, so its model half is itself a `vendor/model`
pair — an entry reads `openrouter/anthropic/claude-opus-5`. It buys one key for
many models (swapping model costs neither code nor a new secret), at the price
of a third party on the path and a weaker schema guarantee: structured-output
support is per model **and** per backing provider, and `strict` is enforced
exactly by some and treated as guidance by others. A model that cannot do
structured outputs is rejected outright rather than silently downgraded.

The next entry is tried only when a model produced **no** answer: a network
failure, an auth/rate-limit/server status, a refusal, or a response cut off at
the token limit. Never on the *content* of an answer — switching providers
because an entry read poorly would make the CHANGELOG silently inconsistent.

In CI these are step-scoped: `AI_MODELS` as a repository/organization
**variable**, the keys as **secrets**. The pull request body names the model
that wrote the entry.

If no model answers, nothing is guessed: the entry is left unwritten, the run
says why, and the pull request is labelled `changelog-needed`.

### What the entry is judged against

`.github/agent-prompts/changelog-scope.md` holds this project's own statement of
what it binds and exposes, and the prompt classifies every upstream change
against it: anything that cannot be tied to something named there is invisible
to this package's users and must not be presented as a feature of it. The
template writes that file once and never overwrites it, so keeping it current is
this project's job — a stale list is how somebody else's release notes end up
described as our features.

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

## Storage Architecture

This project uses a **snapshot pattern** for MLS storage (vs Wire's 18+ entity tables with direct SQL per method).

### How it works

```
1. load_for_group(gid)  → DB query → Vec<(key, value)> → HashMap (initial + current clone)
2. OpenMLS operates      → reads/writes on `current` HashMap
3. commit(provider)      → diff(initial, current) → upserts + deletes → DB write
4. Drop                  → zeroize() all values in both HashMaps → memory freed
```

**No data is held in memory between API calls.** Only the `EncryptedDb` handle persists.

### Key files

| File | Purpose |
|------|---------|
| `rust/src/snapshot_storage.rs` | SnapshotStorageProvider (HashMap-based StorageProvider impl) |
| `rust/src/encrypted_db.rs` | EncryptedDb (SQLCipher native, IDB+AES-GCM WASM) |
| `rust/src/api/engine.rs` | MlsEngine (load → operate → commit cycle) |
| `rust/src/hybrid_crypto.rs` | HybridCrypto (RustCrypto for classical suites; X-Wing PQ KEM → libcrux, lazy init) |

### Native vs WASM loading

- **Native (SQLCipher)**: Loads only target group's data + global data (key packages, signature keypairs). Other groups' data is NOT loaded.
- **WASM (IndexedDB)**: Loads ALL entries (IDB has no WHERE clause). Same user/key trust boundary — no security impact.

### Scalability

The ratchet tree is the only entry scaling with members (~500 bytes per member). A 10,000-member group = ~10 MB peak memory during a single operation. MLS protocol itself (O(N) commit processing) is the bottleneck, not our storage pattern. For groups >50K members, MLS RFC recommends fan-out (subgroups).

### Security properties

- Plaintext in memory only during single-digit milliseconds per operation
- Both HashMaps zeroized on Drop (`snapshot_storage.rs`)
- Security profile identical to Wire's direct-DB approach (both must hold plaintext while OpenMLS operates)

### Why snapshot over Wire's multi-table approach

1. **Only MLS** — no need for separate protocol tables (Wire also has Proteus + E2EI)
2. **Decouples DB schema from OpenMLS internals** — far fewer migrations needed on upgrades
3. **MLS data is small** — full group load is negligible for realistic group sizes
4. **Simpler code** — one table, one load, one diff, one save

### Database migrations

Schema version tracked in `LATEST_SCHEMA_VERSION` constant (`encrypted_db.rs`). Migrations run automatically on `EncryptedDb::open()`. Use the `/add-db-migration` skill when changing storage schema or data format.

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

Each release is a `## [X.Y.Z] - YYYY-MM-DD` heading split into **audience-scoped**
sections. Keep this structure so entries stay consistent across releases.

```markdown
## [X.Y.Z] - YYYY-MM-DD

### For Users

#### ✨ Highlights

- **<headline>** — short description (mark breaking ones **(breaking)**)
- **openmls vX.Y.Z** — ... (state "unchanged this release" if it didn't move)
- **openmls_frb vX.Y.Z** — Rust FFI bindings

#### Changed (Breaking)

- **<summary>** — what broke. Include an **Action required:** note.

#### Changed

- **<summary>** — non-breaking behavior/API change

#### Security

- **<summary>** — security-relevant, user-observable change

#### Fixed

- **<summary>** — bug fix

### For Contributors

#### Added

- **<summary>** — internal tooling only (fuzzing, cargo-deny, scripts, …)

#### Changed

- **<summary>** — CI / lints / build config / template adoption
```

Rules:
- **`### For Users`** = anything a consumer of the published package can observe
  (public API, runtime behavior, the native binary, the build hook). A change is
  "For Users" even if it feels internal when a consumer sees it at build/run time
  (e.g. `overflow-checks` in the shipped binary).
- **`### For Contributors`** = changes that do NOT affect the published package's
  behavior (CI, dev tooling, lints, fuzzing, cargo-deny, build scripts, template
  adoption).
- Every bullet starts with a **bold summary** + em-dash, then the detail.
- Omit any section/subsection with no entries. Order subsections as shown
  (Highlights → Changed (Breaking) → Changed → Security → Fixed).
- Released sections are immutable; edit the top pending version until release.

## Publishing Checklist

Releasing itself is **"Release Flow (two stages)"** above — `make release-frb`,
then `make release`. Do not bump versions, tag or push by hand: each script
requires a clean tree, bumps the right file, finalizes the CHANGELOG, and
creates a **signed** tag (`git tag -s`), which the `Protect release tags`
ruleset requires. An unsigned `git tag -a` is rejected.

What to have green before starting stage 1:

```bash
make analyze ARGS="--fatal-infos"
make format-check
make test
make rust-test
make rust-clippy
make doc                        # blocking: unresolved doc references
make rust-doc                   # blocking: intra-doc links, host + wasm32
make test-web                   # the crate's wasm32 tests, in a real browser
make rust-audit
make rust-deny
make verify-frb-pins
make verify-third-party-notices
make publish-dry-run            # exits 65 on ANY warning, a dirty tree included
```

Push first and let CI go green. `make release-frb` only *warns* when local main
is ahead of origin and then pushes those commits together with the release tag
— so commits CI has never seen would reach origin at the same moment the tag
starts the native build.

## Claude Skills

Claude Code skills available in this project (invoke with `/<skill>` or used automatically by Claude):

| Skill | Description |
|-------|-------------|
| `add-db-migration` | Add a new database migration to EncryptedDb (schema/data format changes) |
| `build-native` | Build the native libraries for a given platform |
| `frb-patterns` | Flutter Rust Bridge patterns and conventions for this project |
| `release-frb-crate` | Release a new `openmls_frb` native crate (stage 1) |
| `release-package` | Prepare a new version for publication to pub.dev (stage 2) |
| `security-review` | Review changes for security issues and secure API usage |
| `update-openmls` | Update the upstream openmls version |
| `update-template` | Update copier template to latest version |
