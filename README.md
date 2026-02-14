# openmls - MLS Protocol for Dart

[![pub package](https://img.shields.io/pub/v/openmls.svg)](https://pub.dev/packages/openmls)
[![CI](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml/badge.svg)](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml)
[![Coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/djx-y-z/a5b2cf3b4ecf95155f76512df95d74c2/raw/coverage.json)](https://gist.github.com/djx-y-z/a5b2cf3b4ecf95155f76512df95d74c2)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.10.0-brightgreen.svg)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/flutter-%3E%3D3.38.0-blue.svg)](https://flutter.dev)
[![openmls](https://img.shields.io/badge/openmls-v0.8.1-orange.svg)](https://github.com/openmls/openmls)

Dart bindings for [OpenMLS](https://github.com/openmls/openmls), providing a Rust implementation of the Messaging Layer Security (MLS) protocol ([RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)) for secure group messaging.

## Platform Support

|             | Android | iOS   | macOS  | Linux      | Windows | Web |
|-------------|---------|-------|--------|------------|---------|-----|
| **Support** | SDK 24+ | 13.0+ | 10.15+ | arm64, x64 | x64     | WASM |
| **Arch**    | arm64, armv7, x64 | arm64 | arm64, x64 | arm64, x64 | x64 | wasm32 |

## Features

- **MLS Protocol (RFC 9420)**: Secure group messaging with forward secrecy and post-compromise security
- **Group Key Agreement**: Efficient tree-based group key agreement (TreeKEM)
- **Encrypted Storage**: All MLS state encrypted at rest — SQLCipher on native, Web Crypto AES-256-GCM on WASM
- **Basic & X.509 Credentials**: Support for both credential types
- **Flutter & CLI Support**: Works with Flutter apps and standalone Dart CLI applications
- **Automatic Builds**: Native libraries downloaded automatically via build hooks
- **High Performance**: Direct Rust integration via Flutter Rust Bridge

## Implementation Status

| Category | Status | Description |
|----------|:------:|-------------|
| Group Lifecycle | Done | Create, join (Welcome, external commit), leave, inspect |
| Member Management | Done | Add, remove, swap members |
| Messaging | Done | Encrypt/decrypt application messages with AAD |
| Proposals | Done | Add, remove, self-update, PSK, custom, group context extensions |
| Commits | Done | Pending proposals, flexible commit, merge/clear |
| Key Packages | Done | Create with options (lifetime, last-resort) |
| Credentials | Done | Basic and X.509 credential types |
| State Queries | Done | Members, epoch, extensions, ratchet tree, group info, PSK export |
| Storage | Done | Encrypted at rest via `MlsEngine` (SQLCipher / Web Crypto) |

<details>
<summary>Full API reference</summary>

**Key Packages**: `createKeyPackage`, `createKeyPackageWithOptions`

**Group Lifecycle**: `createGroup`, `createGroupWithBuilder`, `joinGroupFromWelcome`, `joinGroupFromWelcomeWithOptions`, `inspectWelcome`, `joinGroupExternalCommit`, `joinGroupExternalCommitV2`

**State Queries**: `groupId`, `groupEpoch`, `groupIsActive`, `groupMembers`, `groupCiphersuite`, `groupOwnIndex`, `groupCredential`, `groupExtensions`, `groupPendingProposals`, `groupHasPendingProposals`, `groupMemberAt`, `groupMemberLeafIndex`, `groupOwnLeafNode`, `groupConfirmationTag`, `exportRatchetTree`, `exportGroupInfo`, `exportSecret`, `exportGroupContext`, `getPastResumptionPsk`

**Mutations**: `addMembers`, `addMembersWithoutUpdate`, `removeMembers`, `selfUpdate`, `selfUpdateWithNewSigner`, `swapMembers`, `leaveGroup`, `leaveGroupViaSelfRemove`

**Proposals**: `proposeAdd`, `proposeRemove`, `proposeSelfUpdate`, `proposeExternalPsk`, `proposeGroupContextExtensions`, `proposeCustomProposal`, `proposeRemoveMemberByCredential`

**Commit/Merge**: `commitToPendingProposals`, `mergePendingCommit`, `clearPendingCommit`, `clearPendingProposals`, `setConfiguration`, `updateGroupContextExtensions`, `flexibleCommit`

**Messages**: `createMessage`, `processMessage`, `processMessageWithInspect`, `mlsMessageExtractGroupId`, `mlsMessageExtractEpoch`, `mlsMessageContentType`

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

## Building from Source

### For End Users

**No setup required!** Precompiled native libraries are downloaded automatically from GitHub Releases during `flutter build`.

### For Contributors / Source Builds

If you want to build from source (or precompiled binaries are not available):

- [Flutter](https://flutter.dev/) 3.38+
- [FVM](https://fvm.app/) (optional, for version management)
- **Rust toolchain** (1.88+):
  - [rustup](https://rustup.rs/) - Rust toolchain installer
  - `cargo` - Rust package manager (installed with rustup)

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
- **Rust Implementation** - All cryptographic operations run in Rust (OpenMLS with RustCrypto backend)
- **Encrypted at Rest** - All MLS state encrypted via SQLCipher (native) or Web Crypto AES-256-GCM (WASM)
- **Web Crypto on WASM** - Encryption key stored as non-extractable `CryptoKey` via `crypto.subtle` — raw bytes never persist in WASM memory
- **Memory Safety** - Rust's ownership model prevents memory-related vulnerabilities
- **No `unsafe` code** in the wrapper layer (except `Send + Sync` for `CryptoKey` on single-threaded WASM)

**Best Practices:**
- Keep the library updated to the latest version
- Store the 32-byte encryption key in platform secure storage (Keychain, Android Keystore, `flutter_secure_storage`)
- Never log or expose serialized key material (`signer.serialize()`, private keys)
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

## Related Projects

- [OpenMLS](https://github.com/openmls/openmls) - The underlying Rust MLS library
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) - The Messaging Layer Security (MLS) Protocol
- [Flutter Rust Bridge](https://cjycode.com/flutter_rust_bridge/) - Dart/Flutter <-> Rust binding generator
