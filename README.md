# openmls - MLS Protocol for Dart

[![pub package](https://img.shields.io/pub/v/openmls.svg)](https://pub.dev/packages/openmls)
[![CI](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml/badge.svg)](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.10.0-brightgreen.svg)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/flutter-%3E%3D3.38.0-blue.svg)](https://flutter.dev)
[![openmls](https://img.shields.io/badge/openmls-v0.8.0-orange.svg)](https://github.com/openmls/openmls)

Dart bindings for [OpenMLS](https://github.com/openmls/openmls), providing a Rust implementation of the Messaging Layer Security (MLS) protocol ([RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)) for secure group messaging.

## Platform Support

|             | Android | iOS   | macOS  | Linux      | Windows | Web |
|-------------|---------|-------|--------|------------|---------|-----|
| **Support** | SDK 24+ | 12.0+ | 10.14+ | arm64, x64 | x64     | WASM |
| **Arch**    | arm64, armv7, x64 | arm64 | arm64, x64 | arm64, x64 | x64 | wasm32 |

## Features

- **MLS Protocol (RFC 9420)**: Secure group messaging with forward secrecy and post-compromise security
- **Group Key Agreement**: Efficient tree-based group key agreement (TreeKEM)
- **Pluggable Storage**: Bring your own database via the `MlsStorage` interface (SQLite, Hive, etc.)
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
| Storage | Done | Pluggable KV storage via `MlsStorage` interface |

<details>
<summary>Full API reference (56 functions)</summary>

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
import 'package:openmls/openmls.dart';

void main() async {
  // Initialize the library
  await Openmls.init();

  // Create client with in-memory storage (use SQLite/Hive in production)
  final storage = InMemoryMlsStorage();
  final client = MlsClient(storage);

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
  final group = await client.createGroup(
    config: config,
    signerBytes: signerBytes,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: keyPair.publicKey(),
  );
  print('Created group: ${group.groupId}');

  // Clean up
  Openmls.cleanup();
}
```

## Storage

All MLS state (groups, key packages, secrets) is persisted through the `MlsStorage` interface:

```dart
abstract class MlsStorage {
  FutureOr<Uint8List?> read(Uint8List key);
  FutureOr<void> write(Uint8List key, Uint8List value);
  FutureOr<void> delete(Uint8List key);
}
```

Keys and values are opaque byte arrays managed internally by OpenMLS. Implement this interface with any backend:

- **`InMemoryMlsStorage`** - included, for testing and prototyping
- **SQLite** - for production mobile/desktop apps
- **Hive** - for lightweight persistent storage

Wrap your storage in `MlsClient` to inject it into every API call automatically:

```dart
final storage = InMemoryMlsStorage(); // or your custom implementation
final client = MlsClient(storage);

// All operations use your storage backend
final group = await client.createGroup(...);
await client.addMembers(...);
```

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
│       rust/src/api/*.rs (Rust wrappers)         │  FRB-annotated functions
├─────────────────────────────────────────────────┤
│      lib/src/rust/*.dart (FRB generated)        │  Auto-generated Dart API
├─────────────────────────────────────────────────┤
│    MlsClient + MlsStorage (lib/src/)            │  Convenience wrapper
├─────────────────────────────────────────────────┤
│           Your Dart application code            │  Uses MlsClient
└─────────────────────────────────────────────────┘
```

## Security Notes

**Key Properties:**
- **MLS Protocol (RFC 9420)** - Standardized group key agreement with forward secrecy and post-compromise security
- **Rust Implementation** - All cryptographic operations run in Rust (OpenMLS with RustCrypto backend)
- **Memory Safety** - Rust's ownership model prevents memory-related vulnerabilities
- **No `unsafe` code** in the wrapper layer

**Best Practices:**
- Keep the library updated to the latest version
- Use a persistent `MlsStorage` implementation in production (not `InMemoryMlsStorage`)
- Never log or expose serialized key material (`signer.serialize()`, private keys)
- Use `SecureBytes.wrap()` or `.zeroize()` for sensitive data (serialized keys, shared secrets) — see [SECURITY.md](SECURITY.md)
- Process MLS messages in order to maintain group state consistency

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
