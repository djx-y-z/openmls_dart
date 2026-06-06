## [Unreleased]

### For Users

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

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/djx-y-z/openmls_dart/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/djx-y-z/openmls_dart/releases/tag/v1.0.0
