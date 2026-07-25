## [Unreleased]

### For Users

#### Security

- **Removed undefined behavior from the snapshot storage provider** — the
  `StorageProvider` implementation reached its snapshot through 35 `&self` →
  `&mut self` pointer casts guarded by `#[allow(invalid_reference_casting)]`.
  That cast is undefined behavior regardless of threading: `&self` carries LLVM's
  `noalias`, so a release build (`lto = true`, `opt-level = "z"`) is entitled to
  cache or reorder reads across those writes. Replaced with proper interior
  mutability (`parking_lot::Mutex`), which lets the module drop its
  `#![allow(unsafe_code)]` escape hatch — the crate now denies `unsafe_code`
  everywhere except the generated FRB bridge.
- **Zeroize storage values on overwrite and delete** — replacing or removing a
  snapshot entry previously dropped the old value without wiping it, leaving
  plaintext MLS secrets in freed heap memory for the rest of the operation.

#### Fixed

- **Stopped leaking snapshot allocations on every MLS operation** —
  `into_updates()` ended with `std::mem::forget(self)`, so both `HashMap`
  backing tables were never freed. The `forget` was unnecessary: after both maps
  are drained, the `Drop` impl is a no-op.
- **Build hook no longer re-runs on every build** — the hook declared the
  `.skip_openmls_hook` marker as a build dependency unconditionally, including
  when the marker does not exist (the normal case for every consumer).
  `hooks_runner` treats a declared-but-missing file as modified during the
  build, forcing a redundant second hook pass on each build. The marker is now
  declared only while it exists, which still invalidates the skipped result once
  the marker is removed.

### For Contributors

#### Fixed

- **Repaired the scheduled openmls update check** — the upstream tag guard
  adopted with copier template v3.0.0 hardcoded `^v?\d+\.\d+\.\d+$`, which
  rejects this repo's own `openmls-v` tag prefix, so every run failed with
  `Refusing unexpected upstream tag_name format`. The workflow's blanket
  `|| true` hid that behind a green run. The pattern is now derived from the
  configured tag prefix. No upstream release was actually missed —
  `openmls-v0.8.1` is still the latest — but the next one would have been.

#### Added

- **`make rust-test` and a CI step that runs it** — the crate's unit tests were
  never executed in CI, including `classical_ops_do_not_init_libcrux`, which
  several advisory ignores in `.cargo/audit.toml` and `rust/deny.toml` cite as
  their justification.
- **Regression tests for upstream tag validation** —
  `test/scripts/check_updates_test.dart` covers the configured prefix, shell
  metacharacters, newline injection (including a bare trailing newline), path
  traversal and non-canonical version segments.

#### Changed

- **Update workflows now fail on checker errors** — `make check-…` exits 0 when
  up to date, 1 when an update is available and >1 on failure; the workflows
  distinguish these instead of swallowing every outcome with `|| true`. Manual
  `target_version` input is also validated in the workflow shell, before it is
  interpolated into `ARGS`.
- **Test workflow now triggers on `scripts/`, `hook/` and `Makefile` changes** —
  edits to the build hook, tooling scripts and the Makefile previously ran no
  tests at all. Workflow-file paths are now also watched on pull requests, not
  only on pushes.

## [1.4.2] - 2026-07-21

### For Users

#### ✨ Highlights

- **openmls** — unchanged this release (openmls-v0.8.1)
- **openmls_frb v1.5.2** — Rust FFI bindings

#### Security

- **Hardened MLS message parsing against malformed input** — incoming MLS
  messages (`mlsMessageExtractGroupId` / `mlsMessageExtractEpoch` /
  `mlsMessageContentType`, plus Welcome / GroupInfo / process-message decoding)
  are now decoded via the `Read`-based path and reject trailing bytes
  explicitly, so a malformed message returns an error instead of aborting the
  process. Reported upstream; this local guard will be removed once we depend on
  a fixed openmls release.
- **Triaged new libcrux advisories in the X-Wing PQ dependency tree
  (RUSTSEC-2026-0207/-0208/-0209/-0210/-0211/-0212)** — these advisories were
  published against libcrux crates that reach our tree only transitively via the
  experimental X-Wing ciphersuite (pinned by openmls-v0.8.1, so not fixable via
  `cargo update`). Five are structurally unreachable (the SHA3 ones explicitly
  exclude ML-KEM; the AES-GCM ones are dead code — the only X-Wing suite is
  ChaCha20Poly1305); the sixth (-0212, libcrux-secrets constant-time swap on
  aarch64) is an accepted availability-only risk (CVSS `VC:N/VI:N/VA:H` — a wrong
  ML-KEM result makes an X-Wing operation fail, never a key leak). Per-advisory
  reachability analysis is documented inline in `.cargo/audit.toml` /
  `rust/deny.toml`; all clear on the next upstream OpenMLS bump. Classical
  (non-PQ) ciphersuites are unaffected.

#### Fixed

- **Web build hook now refreshes stale WASM on upgrade** — the web build hook
  records the provisioned crate version in `web/pkg/.wasm-version` and
  re-downloads when it changes, instead of skipping whenever the two WASM files
  merely exist. Previously, upgrading the package kept the prior version's WASM
  in the app's `web/pkg/` (it survives `flutter clean`), so on web any FRB entry
  calling Dart store callbacks could panic with an argument-count mismatch
  (`called Option::unwrap() on a None value`) once the wire signature changed
  between versions. The download cache is now version-keyed (`web/<version>/`),
  WASM files are copied unconditionally (the old mtime guard skipped a
  fresh-but-older source on downgrade), and `rust/Cargo.toml` is a declared
  web-build dependency so a version bump re-runs the hook. Native platforms were
  unaffected.

### For Contributors

#### Changed

- **Adopt copier template v2.5.1 → v2.5.2** — source of the web build hook fix
  above.
- **Adopt copier template v2.5.2 → v3.0.3** — release-process and dev-tooling
  changes only; no change to the published package's runtime behavior.
  - **Two-stage release flow** (v3.0.0) — the native `openmls_frb` crate and the
    Dart package now release independently: `make release-frb` bumps, tags
    (`openmls_frb-X.Y.Z`) and builds the native binary, then `make release`
    verifies that binary exists and publishes the Dart package (`vX.Y.Z`). Adds
    `scripts/release.dart` / `scripts/release_frb.dart` and the
    `release-frb-crate` skill; the flow is documented in CLAUDE.md.
  - **Repository protections** (v3.0.0) — GitHub rulesets (`.github/rulesets/`)
    restricting who may push `main` and create release tags, a signed-commit
    rule, a `setup_repo_protections.dart` helper, and a Dependabot config.
  - **Removed vestigial Windows Flutter-plugin scaffolding** (v3.0.0) —
    `windows/CMakeLists.txt` and the generated plugin registrant; this is a
    pure-Dart FRB package (native libraries load via the build hook), so the
    scaffolding was unused.
  - **Release-tooling fixes** (v3.0.1 → v3.0.3) — the pub.dev dry-run now runs on
    the clean pre-bump tree (a bumped-but-uncommitted tree tripped
    `pub publish --dry-run`'s exit-65-on-warning), and `make release` no longer
    leaves an empty `## [Unreleased]` heading behind.

## [1.4.1] - 2026-07-14

### For Users

#### Highlights

- **Hardened release binary & fail-closed supply chain** — the shipped native
  library is now compiled with `overflow-checks` and `unsafe_code = "deny"`, and
  the download hook refuses to load a binary whose SHA256 checksum cannot be
  verified.
- **openmls** — unchanged this release (openmls-v0.8.1)
- **openmls_frb v1.5.0 → v1.5.1** — Rust FFI bindings (release binary rebuilt
  with `overflow-checks`; no API or behavior change in normal use)

#### Security

- **Hardened release binary** — the wrapper crate is now compiled with
  `overflow-checks` (integer overflow panics instead of wrapping silently) and
  `unsafe_code = "deny"` on all hand-written Rust. The few modules that
  legitimately need `unsafe` (the interior-mutability storage shim and the WASM
  `WasmCryptoKey` `Send + Sync` impl) opt in explicitly; the FRB-generated
  bridge is exempt.
- **Fail-closed download verification** — the native-library build hook now
  **aborts** if the SHA256 checksums cannot be fetched or lack an entry for the
  archive, instead of loading an unverified binary. An
  `OPENMLS_ALLOW_UNVERIFIED_DOWNLOAD=1` escape hatch is provided for older
  releases published without a checksums file.

### For Contributors

#### Added

- **cargo-deny** (`rust/deny.toml`, `make rust-deny`, CI `deny` job) — enforces
  RustSec advisories, an allowed-license list, and a source allow-list.
  Remediated RUSTSEC-2026-0204 (`crossbeam-epoch` 0.9.18 → 0.9.20); six
  unremediable/inapplicable advisories are ignored with inline justifications
  (the three libcrux crypto advisories mirror `.cargo/audit.toml`).
- **cargo-fuzz harness** (`rust/fuzz/`, `Fuzz` workflow, `make fuzz*`) with two
  targets over untrusted wire bytes — `mls_message` (MLS protocol-message
  parsers) and `credential` (`MlsCredential::deserialize`) — plus a seed-corpus
  generator (`make fuzz-seed`).
- **Rust clippy in CI** (`make rust-clippy`, `-D warnings`) and a pinned FRB
  codegen installer (`make setup-frb-codegen`) so CI and local codegen produce
  identical bindings.
- Download-cache tests (`test/hook/build_hook_test.dart`).

#### Changed

- Adopt copier template v2.4.0 → v2.5.1
  - Fixed the download cache key (crate version + full platform variant) so iOS
    device and simulator builds no longer poison each other's cache on
    Apple-silicon hosts
  - Update scripts: `check_updates.dart --update` now bumps the wrapper crate
    version, `update_changelog.dart` classifies update severity and accepts
    `--from`, and the update workflow skips regeneration when an open PR for the
    same version already exists
  - Fixed pre-existing clippy findings (`CryptoError` Copy deref;
    `too_many_arguments` on external-commit APIs)

## [1.4.0] - 2026-06-06

### For Users

#### Highlights

- **openmls_frb v1.4.0 → v1.5.0** — experimental X-Wing post-quantum ciphersuite (hybrid ML-KEM-768 + X25519)

#### Added

- **Experimental post-quantum ciphersuite**: `MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519` —
  hybrid X-Wing KEM (ML-KEM-768 + X25519, draft-connolly-cfrg-xwing-kem-06) for
  harvest-now-decrypt-later protection. HPKE operations for this suite are delegated
  to the formally verified libcrux ML-KEM implementation (`openmls_libcrux_crypto`,
  same upstream `openmls-v0.8.1` pin); all classical ciphersuites continue to run
  unchanged on RustCrypto. The libcrux provider is initialized lazily — classical
  suites never depend on it. See the README "Post-Quantum Support (Experimental)"
  section for important limitations (no IANA codepoint, limited interoperability,
  future migration to the official IETF suite).

#### Security

- `cargo audit` reports three RustSec advisories introduced into the dependency
  tree by `openmls_libcrux_crypto` (RUSTSEC-2026-0124, RUSTSEC-2026-0075,
  RUSTSEC-2026-0073). Analysis: all are DoS-class (panic) or structurally
  unreachable through this library's call paths — signatures always run on
  RustCrypto (0075 path never invoked; libcrux's KEM/HPKE code does not link
  ed25519), HPKE buffers are exact-size library-allocated (0124 trigger
  impossible), and the standalone `mac()` (0073) is never called. Fixes are
  blocked on upstream semver pins; tracked until the next upstream OpenMLS
  release. Each advisory is ignored in `.cargo/audit.toml` with its
  reachability justification inline — remove those entries when bumping the
  upstream pin. The non-libcrux routing these justifications depend on is
  enforced by the `classical_ops_do_not_init_libcrux` Rust test.

#### Documentation

- Document `flutter build web --wasm` (dart2wasm) limitation in README — Rust returns fail with `Type 'JSValue' is not a subtype of type 'List<dynamic>'` under dart2wasm. Upstream limitation in `flutter_rust_bridge` ([#2575](https://github.com/fzyzcjy/flutter_rust_bridge/issues/2575)), affects every FRB-based Dart package. Standard `flutter build web` (dart2js) target continues to work. ([#5](https://github.com/djx-y-z/openmls_dart/issues/5))

## [1.3.0] - 2026-04-01

### For Users

#### Highlights

- **openmls_frb v1.3.0 → v1.4.0** — update flutter_rust_bridge to v2.12.0

#### Changed

- Update `flutter_rust_bridge` from v2.11.1 to v2.12.0 — fixes codegen/runtime version mismatch when consumers resolve FRB 2.12.x ([#4](https://github.com/djx-y-z/openmls_dart/issues/4))

## [1.2.0] - 2026-02-18

### For Users

#### Highlights

- **openmls_frb v1.2.0 → v1.3.0** — database migration system with schema versioning

#### Added

- `MlsEngine.schemaVersion()` — returns the current database schema version (useful for diagnostics and debugging)

### For Contributors

#### Added

- Database migration system with automatic schema versioning and downgrade detection
  - Native (SQLCipher): each migration runs in its own SQL transaction with version written atomically
  - WASM (IndexedDB): two-phase approach — structural changes via IDB versioning, data migrations via encrypted metadata key
  - Downgrade detection: clear error if DB was created by a newer library version
  - Separate version counters: `LATEST_SCHEMA_VERSION` (data format, both platforms) and `IDB_STRUCTURAL_VERSION` (IDB object stores, WASM only)
- `/add-db-migration` Claude skill — step-by-step guide for adding new migrations
- Storage Architecture section in CLAUDE.md — snapshot pattern, scalability, security properties, Wire comparison
- DB migration reminder in openmls update workflow PR checklist

#### Fixed

- Fix WASM build failure caused by `idb` 0.6.5 API changes in `encrypted_db.rs` (`VersionChangeEvent::old_version()` now returns `Result<u32>`, `Uint8Array::into()` requires explicit type)

#### Changed

- Adopt copier template v2.3.1 → v2.4.0
  - Added coverage badge support in README (shields.io endpoint via GitHub Gist)
  - Added Rust dependency caching (`Swatinem/rust-cache@v2`) in CI setup-rust action — dramatically speeds up Windows builds (~10 min OpenSSL compile cached)
  - Added Strawberry Perl configuration for Windows CI to fix OpenSSL build (MSYS2 Perl from Git Bash is incompatible)
  - Added `IPHONEOS_DEPLOYMENT_TARGET` env var for iOS CI builds — fixes linker errors when vendored C code is compiled with newer Xcode
  - Added `make check-targets` command and `scripts/check_deployment_targets.dart` for checking deployment target consistency (iOS/macOS/Android) across all project files
  - Added "Setting up Coverage Badge" and "Setting up pub.dev Publishing" sections to CONTRIBUTING.md
  - Replaced `dart run scripts/` with `dart scripts/` in Makefile commands, removing `.skip_openmls_hook` workaround (scripts only use `dart:` imports, so `dart run` build hooks are unnecessary)
  - Fixed WASM build hook: local builds now take priority over cached/downloaded files, avoiding stale content hash mismatches
  - Removed `flutter:` version constraint from `pubspec.yaml` environment (pure Dart packages don't need it)
  - README: compact horizontal platform table, added "Developing Rust API", "Building Native Libraries", and "CI / Version Management" sections

## [1.1.0] - 2026-02-15

### For Users

#### Highlights

- **openmls_frb v1.0.0 → v1.2.0** — Rust FFI bindings with engine close/reopen support and openmls v0.8.1

#### Added

- `MlsEngine.close()` and `MlsEngine.isClosed()` — allow closing the engine (wiping the encryption key from RAM and closing the DB connection) when the app goes to background or the screen is locked. After close, all operations fail with "MlsEngine is closed". Close is idempotent

#### Changed

- Update openmls native library to v0.8.1 ([release notes](https://github.com/openmls/openmls/releases/tag/openmls-v0.8.1))
  - Relaxed WASM size limit to improve compatibility
  - Exposed `full_leaves` and `parents` in TreeSync for tree traversal
  - Updated libcrux and hpke-rs dependencies

#### Fixed

- README: Correct iOS minimum version from 12.0 to 13.0 and macOS from 10.14 to 10.15 in platform support table

### For Contributors

#### Added

- `make check-targets`: Unified deployment target consistency checker for iOS, macOS, and Android — verifies all project files (podspec, CI workflow, Xcode project, plist, build.gradle, README) match `.copier-answers.yml`. Supports `--update` to fix mismatches and `--set <version>` to change a platform target everywhere in one command

#### Changed

- CI: Add Rust dependency caching (`Swatinem/rust-cache`) to speed up builds, especially Windows where vendored OpenSSL compilation took ~10 minutes

## [1.0.1] - 2026-02-11

### Added

- Coverage badge

## [1.0.0] - 2026-02-11

### Added

- **MLS Protocol (RFC 9420)**: Full group key agreement with forward secrecy and post-compromise security
- **MlsEngine**: Rust-owned encrypted database with 61 API functions (58 async + 3 sync):
  - Group creation, join (Welcome, external commit), leave
  - Member management (add, remove, swap)
  - Encrypted messaging with additional authenticated data (AAD)
  - Proposals (add, remove, self-update with custom leaf node parameters, PSK, custom, group context extensions)
  - Commit handling (pending, flexible, merge/clear)
  - State queries (members, epoch, extensions, configuration, epoch authenticator, ratchet tree, group info, secrets)
  - Key package creation with options (lifetime, last-resort)
  - Storage cleanup (delete group, delete key package, remove pending proposal)
  - Basic and X.509 credential support (optional credential bytes on all creation functions)
  - 3 sync message utilities (extract group ID, epoch, content type)
- **Encrypted storage**: All MLS state encrypted at rest
  - Native: SQLCipher (AES-256 transparent full-database encryption)
  - Web: IndexedDB + AES-256-GCM per-value encryption via Web Crypto API
- **SecureBytes**: Wrapper for sensitive byte data with automatic zeroing on disposal
- **SecureUint8List**: Extension with `zeroize()` method for manual zeroing of `Uint8List`
- Cross-platform support: Android, iOS, macOS, Linux, Windows, Web (WASM)
- Automatic native library download via Dart Build Hooks
- SHA256 checksum verification for supply chain security
- Based on [OpenMLS](https://github.com/openmls/openmls) v0.8.0

### Security

- All cryptographic operations run in Rust (OpenMLS with RustCrypto backend)
- Memory safety via Rust's ownership model
- No `unsafe` code in the wrapper layer
- **Web Crypto API on WASM**: Encryption key imported as non-extractable `CryptoKey` via `crypto.subtle.importKey()` — raw key bytes zeroized from WASM memory immediately after import. Defensive error handling (no `unwrap()`) in encrypt/decrypt paths
- `SerializableSigner` derives `ZeroizeOnDrop` — private key bytes zeroed on drop
- Eliminated clone-then-zeroize pattern in `from_raw()` and `serialize_signer()` — private keys moved, not copied
- `signer_from_bytes()` zeroizes input bytes on all code paths, including deserialization errors
- X.509 `x509()` documents that application layer must validate certificate chains
- SECURITY.md: sensitive API table, known limitations, web deployment recommendations, vulnerability reporting via GitHub Security Advisories

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/djx-y-z/openmls_dart/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/djx-y-z/openmls_dart/releases/tag/v1.0.0
