# openmls - MLS Protocol for Dart

[![pub package](https://img.shields.io/pub/v/openmls.svg)](https://pub.dev/packages/openmls)
[![CI](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml/badge.svg)](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml)
[![Coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/djx-y-z/a5b2cf3b4ecf95155f76512df95d74c2/raw/coverage.json)](https://gist.github.com/djx-y-z/a5b2cf3b4ecf95155f76512df95d74c2)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.10.0-brightgreen.svg)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/flutter-%3E%3D3.38.0-blue.svg)](https://flutter.dev)
[![openmls](https://img.shields.io/badge/openmls-v0.9.0-orange.svg)](https://github.com/openmls/openmls)

Dart bindings for [OpenMLS](https://github.com/openmls/openmls), providing a Rust implementation of the Messaging Layer Security (MLS) protocol ([RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)) for secure group messaging.

## Platform Support

|             | Android | iOS   | macOS  | Linux      | Windows | Web |
|-------------|---------|-------|--------|------------|---------|-----|
| **Support** | SDK 24+ | 13.0+ | 10.15+ | arm64, x64 | x64     | WASM |
| **Arch**    | arm64, armv7, x64 | arm64, x64 (sim) | arm64, x64 | arm64, x64 | x64 | wasm32 |

## Features

- **MLS Protocol (RFC 9420)**: Secure group messaging with forward secrecy and post-compromise security
- **Group Key Agreement**: Efficient tree-based group key agreement (TreeKEM)
- **Post-Quantum (Experimental)**: Ten hybrid and pure post-quantum ciphersuites (X-Wing, ML-KEM-768/1024, ML-DSA-44/65/87) — see [Post-Quantum Support](#post-quantum-support-experimental)
- **Encrypted Storage**: All MLS state encrypted at rest — SQLCipher on native, Web Crypto AES-256-GCM on WASM
- **Basic & X.509 Credentials**: Support for both credential types
- **Flutter & CLI Support**: Works with Flutter apps and standalone Dart CLI applications
- **Automatic Builds**: Native libraries downloaded automatically via build hooks
- **High Performance**: Direct Rust integration via Flutter Rust Bridge

## Post-Quantum Support (Experimental)

`supportedCiphersuites()` returns thirteen ciphersuites. Three are the
IANA-registered MLS 1.0 suites from RFC 9420; **the other ten are experimental
post-quantum suites on provisional code points.** All thirteen are exercised
end-to-end by the test suite — a full group lifecycle each, not merely a key
generation.

### The classical suites (interoperable)

| Suite | Value |
|---|---|
| `mls128DhkemX25519Aes128GcmSha256Ed25519` | 0x0001 |
| `mls128DhkemP256Aes128GcmSha256P256` | 0x0002 |
| `mls128DhkemX25519Chacha20Poly1305Sha256Ed25519` | 0x0003 |

### The post-quantum suites (experimental)

`Hybrid` means the KEM keeps a classical component, so group secrets stay
confidential if *either* half holds. `PQ-only` means there is **no classical
fallback**: a break of ML-KEM (or ML-DSA) breaks the suite outright.

| Suite | Value | KEM | Signature |
|---|---|---|---|
| `mls256XwingChacha20Poly1305Sha256Ed25519` | 0x004D | Hybrid (X-Wing) | Ed25519 |
| `mls192Mlkem1024Aes256GcmSha384P384` | 0x0042 | PQ-only ML-KEM-1024 | ECDSA P-384 |
| `mls128Mlkem768X25519Aes256GcmSha384Ed25519` | 0x004E | Hybrid (ML-KEM-768 + X25519) | Ed25519 |
| `mls128Mlkem768X25519Aes128GcmSha256Ed25519` | 0x004F | Hybrid (ML-KEM-768 + X25519) | Ed25519 |
| `mls128Mlkem768Aes256GcmSha384P256` | 0x0050 | PQ-only ML-KEM-768 | ECDSA P-256 |
| `mls192Mlkem768Aes256GcmSha384Mldsa65` | 0x0051 | PQ-only ML-KEM-768 | ML-DSA-65 |
| `mls128Mlkem768X25519Chacha20Poly1305Sha384Mldsa44` | 0x0052 | Hybrid (ML-KEM-768 + X25519) | ML-DSA-44 |
| `mls256Mlkem1024Aes256GcmSha512Mldsa87` | 0x0906 | PQ-only ML-KEM-1024 | ML-DSA-87 |
| `mls256Mlkem1024Aes256GcmSha384Mldsa87` | 0x0907 | PQ-only ML-KEM-1024 | ML-DSA-87 |
| `mls128Mlkem768Aes256GcmSha384Ed25519` | 0xF042 | PQ-only ML-KEM-768 | Ed25519 |

**Read before using — honest limitations:**

- **Experimental, not standardized.** None of these code points is registered
  with IANA. The nine `MLKEM`/`MLDSA` suites carry the provisional values from
  [draft-ietf-mls-pq-ciphersuites](https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites),
  which may be renumbered or withdrawn before publication; X-Wing (0x004D) comes
  from an *expired individual* draft. When official suites are published, groups
  created on these will need to migrate. We will track the official suites and
  provide a migration path.
- **Limited interoperability.** In practice only OpenMLS-based stacks (and, for
  X-Wing, ts-mls) implement these. Use them in closed deployments where every
  client uses this library or OpenMLS — not for cross-vendor federation.
- **`PQ-only` suites have no classical fallback.** If you want the
  harvest-now-decrypt-later protection *without* betting solely on lattice
  assumptions, choose a `Hybrid` row.
- **The underlying implementations are pre-1.0.** ML-KEM, ML-DSA and X-Wing are
  provided by the RustCrypto and libcrux stacks at pre-1.0 versions.

### X-Wing specifically

`mls256XwingChacha20Poly1305Sha256Ed25519` uses the **X-Wing** hybrid KEM
([draft-connolly-cfrg-xwing-kem](https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/)):
ML-KEM-768 combined with X25519, so group secrets stay confidential if *either*
component remains unbroken. It is the only suite whose HPKE operations run on
[libcrux](https://github.com/cryspen/libcrux) (formally verified ML-KEM); every
other suite, classical and post-quantum alike, runs on RustCrypto.

- **libcrux is pre-1.0 and not fully audited.** Its ML-KEM source is formally
  verified (hax/F*: correctness, secret independence, panic freedom), but
  compiled binaries carry no side-channel-resistance verification, and the
  maintainers themselves advise consultation before production use.
- The X-Wing construction itself is peer-reviewed
  ([IND-CCA secure if either ML-KEM-768 or X25519 holds](https://eprint.iacr.org/2024/039))
  and its wire format has been stable across draft revisions.

### What your peers see

A leaf node advertises the ciphersuites you are willing to accept. Unless you
pass explicit `capabilities`, OpenMLS fills that list with **all thirteen**
suites above — so peers may choose an experimental one for a group you join.
To advertise a narrower set, pass `MlsCapabilities` with an explicit
`ciphersuites` list (as raw `u16` values) to `createGroupWithBuilder` or
`proposeSelfUpdate`. `createKeyPackage` itself takes no capabilities argument,
so a key package built with it advertises the full list — use
`createKeyPackageWithOptions` and set `KeyPackageOptions.capabilities` to narrow
that one too.

## Implementation Status

| Category | Status | Description |
|----------|:------:|-------------|
| Group Lifecycle | Done | Create, join (Welcome, external commit), leave, inspect |
| Member Management | Done | Add, remove, swap members |
| Messaging | Done | Encrypt/decrypt application messages with AAD |
| Proposals | Done | Add, remove, self-update, PSK, custom, group context extensions |
| Commits | Done | Pending proposals, flexible commit, merge/clear |
| Key Packages | Done | Create with options (lifetime, last-resort), read and check the validity window |
| Credentials | Done | Basic and X.509 credential types |
| State Queries | Done | Members, epoch, extensions, ratchet tree, group info, PSK export |
| Storage | Done | Encrypted at rest via `MlsEngine` (SQLCipher / Web Crypto) |

<details>
<summary>Full API reference</summary>

**Key Packages**: `createKeyPackage`, `createKeyPackageWithOptions`, `keyPackageLifetime`, `checkLifetimeAt`

**Group Lifecycle**: `createGroup`, `createGroupWithBuilder`, `joinGroupFromWelcome`, `joinGroupFromWelcomeWithOptions`, `inspectWelcome`, `exportWelcomeSecret`, `joinGroupExternalCommit`, `joinGroupExternalCommitV2`

**State Queries**: `groupId`, `groupEpoch`, `groupIsActive`, `groupMembers`, `groupCiphersuite`, `groupOwnIndex`, `groupCredential`, `groupExtensions`, `groupPendingProposals`, `groupHasPendingProposals`, `groupMemberAt`, `groupMemberLeafIndex`, `groupOwnLeafNode`, `groupConfirmationTag`, `groupConfiguration`, `groupEpochAuthenticator`, `exportRatchetTree`, `exportGroupInfo`, `exportSecret`, `exportGroupContext`, `getPastResumptionPsk`

**Mutations**: `addMembers`, `addMembersWithoutUpdate`, `removeMembers`, `selfUpdate`, `selfUpdateWithNewSigner`, `swapMembers`, `leaveGroup`, `leaveGroupViaSelfRemove`

**Proposals**: `proposeAdd`, `proposeRemove`, `proposeSelfUpdate`, `proposeSelfUpdateWithNewSigner`, `proposeExternalPsk`, `proposeGroupContextExtensions`, `proposeCustomProposal`, `proposeRemoveMemberByCredential`, `removePendingProposal`

**Commit/Merge**: `commitToPendingProposals`, `mergePendingCommit`, `clearPendingCommit`, `clearPendingProposals`, `setConfiguration`, `updateGroupContextExtensions`, `flexibleCommit`

**Messages**: `createMessage`, `processMessage`, `processMessageWithInspect`, `mlsMessageExtractGroupId`, `mlsMessageExtractEpoch`, `mlsMessageContentType`

**Engine & Storage**: `close`, `isClosed`, `schemaVersion`, `deleteGroup`, `deleteKeyPackage`

</details>

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  openmls: ^x.x.x
```

Native libraries are downloaded automatically during build via Dart build hooks.

**No Rust required** for end users - precompiled binaries are downloaded from GitHub Releases.

## Usage

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:openmls/openmls.dart';

void main() async {
  // Initialize the library
  await Openmls.init();

  // Create an MlsEngine with encrypted storage.
  // - Native: SQLCipher database at the given file path
  // - Web: IndexedDB with AES-256-GCM encryption via Web Crypto API
  // Use ":memory:" for ephemeral in-memory storage (testing).
  final encryptionKey = Uint8List(32); // 32-byte key — store in platform secure storage!
  final engine = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: encryptionKey,
  );

  // Generate signing key pair
  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final signerBytes = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: keyPair.privateKey(),
    publicKey: keyPair.publicKey(),
  );

  // Create a group
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);
  final group = await engine.createGroup(
    config: config,
    signerBytes: signerBytes,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: keyPair.publicKey(),
  );
  print('Created group: ${group.groupId}');

  // Close engine (releases DB connection and encryption key resources)
  await engine.close();

  // Clean up FRB runtime (optional, for CLI apps exiting)
  Openmls.cleanup();
}
```

## Storage

All MLS state is stored in a Rust-owned encrypted database via `MlsEngine`:

| Platform | Backend | Encryption |
|----------|---------|------------|
| Native (iOS, Android, macOS, Linux, Windows) | SQLCipher | AES-256 full-database encryption |
| Web (WASM) | IndexedDB | AES-256-GCM per-value encryption via `crypto.subtle` |

```dart
// Create engine with a 32-byte encryption key.
// Store the key in platform secure storage (Keychain, Android Keystore, etc.)
final engine = await MlsEngine.create(
  dbPath: 'mls_data.db',    // file path on native, IDB name on web
  encryptionKey: myKey,       // 32-byte AES-256 key
);

// All operations go through the engine
final group = await engine.createGroup(...);
await engine.addMembers(...);

// Close the engine to release the DB connection and encryption key resources.
// After close, all operations fail with "MlsEngine is closed".
// Useful for screen lock / app background scenarios.
await engine.close();

// Re-create from secure storage on unlock
final engine2 = await MlsEngine.create(dbPath: 'mls_data.db', encryptionKey: myKey);
```

On WASM, the encryption key is imported as a **non-extractable `CryptoKey`** via the Web Crypto API. Raw key bytes are zeroized from WASM memory immediately after import.

## Known Limitations

### Web: `flutter build web --wasm` (dart2wasm) is not supported

This package works with the standard `flutter build web` (dart2js) target. It does **not** currently work when the host app is compiled with `flutter build web --wasm` / `flutter run -d chrome --wasm` (dart2wasm). Calls to the Rust side fail with:

```
Type 'JSValue' is not a subtype of type 'List<dynamic>' in type cast
```

This is an upstream limitation in [`flutter_rust_bridge`](https://github.com/fzyzcjy/flutter_rust_bridge) — its generated Dart decoders rely on implicit JS-array casts that work on dart2js but fail under dart2wasm. The pattern is hardcoded in FRB's codegen templates, so it affects every FRB-based Dart package, not just this one. Tracking upstream: [flutter_rust_bridge#2575](https://github.com/fzyzcjy/flutter_rust_bridge/issues/2575).

| Command | Status |
|---------|--------|
| `flutter run -d chrome` | Works (dart2js) |
| `flutter build web` | Works (dart2js) |
| `flutter run -d chrome --wasm` | Not supported (dart2wasm) |
| `flutter build web --wasm` | Not supported (dart2wasm) |

The Rust core of openmls ships as a `.wasm` module in both modes — `--wasm` only changes what the *Dart* code compiles to. Crypto performance and functionality are equivalent.

### Web: `flutter run -d chrome` can skip the build hook and leave `web/pkg/` empty

The build hook provisions the WASM module into your app's `web/pkg/` directory.
`flutter build web` always reaches it. `flutter run -d chrome` reaches it only while
Flutter's build system considers its `dart_build` target out of date — and that target's
cache key does **not** include the target platform. A debug `flutter run` keys its build
directory on the engine revision, the entrypoint, the build mode and the output path
alone, so a debug run for *another* platform (`flutter run -d macos`, say) leaves behind a
`dart_build` stamp naming its own dependencies; the next `flutter run -d chrome` finds
every one of them unchanged, logs `Skipping target: dart_build`, and never invokes the
hook. With `web/pkg/` not already provisioned, `RustLib.init()` then fails on a 404 for
`pkg/openmls_frb.js`.

The hook cannot defend against this — the skip happens above `hooks_runner`, so nothing
the hook declares as a dependency is ever read. Any one of these unblocks it, and
`flutter run -d chrome` serves `web/pkg/` normally afterwards:

```bash
flutter build web                 # provisions web/pkg/ through the same hook
rm -f build/*/dart_build.stamp    # drop the stale stamp, then run again
flutter clean                     # the blunt version of the same thing
```

## Building from Source

### For End Users

**No setup required!** Precompiled native libraries are downloaded automatically from GitHub Releases during `flutter build`.

### For Contributors / Source Builds

- [Flutter](https://flutter.dev/docs/get-started/install) (>=3.38.0)
- [Rust](https://rustup.rs/) (1.91+) — must match `rust-version` in `rust/Cargo.toml`
- [FVM](https://fvm.app/) (recommended for version management)
- Make (for build commands; see the Windows note in CONTRIBUTING.md)

### Setup

```bash
# Clone the repository
git clone https://github.com/djx-y-z/openmls_dart.git
cd openmls_dart

# Install FVM and dependencies
make setup

# Generate Dart bindings
make codegen

# Build native library
make build

# Run tests
make test

# See all available commands
make help
```

### Developing Rust API

1. Add your Rust functions in `rust/src/api/`:

```rust
// rust/src/api/greeting.rs
pub fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}
```

2. Register the module in `rust/src/api/mod.rs`:

```rust
pub mod greeting;
```

3. Generate Dart bindings:

```bash
make codegen
```

4. Build and test:

```bash
make build
make test
```

### Building Native Libraries

Native libraries are pre-built and downloaded automatically via build hooks.
If you need to build them locally:

```bash
# Build for current platform
make build

# Build with specific target
make build ARGS="--target aarch64-apple-darwin"

# Build for Android
make build-android

# Build for Web (WASM)
make build-web
```

## CI / Version Management

```bash
# Check for new openmls versions
make check-new-openmls-version

# Check for new copier template versions
make check-template-updates

# Check deployment target consistency (iOS/macOS/Android)
make check-targets

# Update Cargo.lock dependencies
make rust-update

# Generate AI-powered changelog entry (needs AI_MODELS + a provider key)
make update-changelog ARGS="--version v1.0.0"
```

The CI automatically checks for new openmls releases daily and creates PRs with:
- Updated `pubspec.yaml` and version badges
- Updated `Cargo.lock` (if successful)
- Regenerated FRB bindings (if successful)
- AI-generated CHANGELOG entry, when `AI_MODELS` names a model with a key
  (see CONTRIBUTING); otherwise the pull request is labelled `changelog-needed`

It also checks for copier template updates daily. When one is found it applies
it with `copier update` and opens a pull request carrying the result — a draft
when copier could not merge something, or when the update failed to record the
new version in `.copier-answers.yml`.


## Architecture

```
┌─────────────────────────────────────────────────┐
│          OpenMLS (Rust crate)                    │  Core MLS implementation
├─────────────────────────────────────────────────┤
│     MlsEngine + EncryptedDb (Rust)              │  Encrypted storage layer
├─────────────────────────────────────────────────┤
│       rust/src/api/*.rs (Rust wrappers)         │  FRB-annotated functions
├─────────────────────────────────────────────────┤
│      lib/src/rust/*.dart (FRB generated)        │  Auto-generated Dart API
├─────────────────────────────────────────────────┤
│           Your Dart application code            │  Uses MlsEngine
└─────────────────────────────────────────────────┘
```

## Security Notes

**Key Properties:**
- **MLS Protocol (RFC 9420)** - Standardized group key agreement with forward secrecy and post-compromise security
- **Rust Implementation** - All cryptographic operations run in Rust (OpenMLS with RustCrypto backend; the experimental X-Wing post-quantum KEM is delegated to libcrux)
- **Encrypted at Rest** - All MLS state encrypted via SQLCipher (native) or Web Crypto AES-256-GCM (WASM)
- **Web Crypto on WASM** - Encryption key stored as non-extractable `CryptoKey` via `crypto.subtle` — raw bytes never persist in WASM memory
- **Memory Safety** - Rust's ownership model prevents memory-related vulnerabilities
- **No `unsafe` code** in the wrapper layer (except `Send + Sync` for `CryptoKey` on single-threaded WASM)

**Best Practices:**
- Keep the library updated to the latest version
- Store the 32-byte encryption key in platform secure storage (Keychain, Android Keystore, `flutter_secure_storage`)
- Never log or expose serialized key material (`serializeSigner()`, `privateKey()`)
- Use `SecureBytes.wrap()` or `.zeroize()` for sensitive data (serialized keys, shared secrets) — see [SECURITY.md](SECURITY.md)
- Process MLS messages in order to maintain group state consistency
- **Web deployment:** Enable strict CSP headers (`script-src 'self'`) and serve over HTTPS

See [SECURITY.md](SECURITY.md) for full security guidelines.

## Acknowledgements

This library would not be possible without [OpenMLS](https://github.com/openmls/openmls), which provides the underlying Rust implementation of the MLS protocol.

## Contributing

Contributions are welcome! Please read our [Contributing Guidelines](CONTRIBUTING.md) before submitting issues or pull requests.

For major changes, please open an issue first to discuss what you would like to change.

## Security

See [SECURITY.md](SECURITY.md) for security policy and reporting vulnerabilities.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Third-party notices

The prebuilt native library is statically linked against its Rust dependency
tree (MIT, Apache-2.0, BSD, ISC and similar). Those licenses require their
notices to travel with any binary distribution — including an application that
embeds the library — and Flutter's `LicenseRegistry` does not cover them,
because it aggregates `LICENSE` files of pub packages and Rust crates are not
pub packages.

[`THIRD_PARTY_NOTICES.txt`](THIRD_PARTY_NOTICES.txt) ships at the root of this
package and inside every native release archive. It is generated from the
resolved dependency graph across all released targets — build edges included,
because that is how vendored native code reaches the binary: a `*-src` crate
carrying C sources is a build-dependency of its `*-sys` wrapper — and CI
verifies it stays in sync with `Cargo.lock`. Where a crate ships no licence
file of its own, the canonical text of the licence it declares is supplied in
its place, so the file delivers the licences and not just their names.

Regenerate it with `make third-party-notices` after a dependency change;
`make rust-update` already does that for you.

The file is deliberately **not** declared under `flutter: assets:` — a
package-declared asset is bundled into every consuming application whether or
not it is used, and most applications never display these notices. To surface
them at runtime, copy the file into your own assets and register it:

```yaml
# your app's pubspec.yaml
flutter:
  assets:
    - assets/THIRD_PARTY_NOTICES.txt
```

```dart
LicenseRegistry.addLicense(() async* {
  final text = await rootBundle.loadString('assets/THIRD_PARTY_NOTICES.txt');
  yield LicenseEntryWithLineBreaks(const ['openmls'], text);
});
```

## Related Projects

- [OpenMLS](https://github.com/openmls/openmls) - The underlying Rust MLS library
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) - The Messaging Layer Security (MLS) Protocol
- [Flutter Rust Bridge](https://cjycode.com/flutter_rust_bridge/) - Dart/Flutter <-> Rust binding generator
