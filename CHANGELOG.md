## [1.0.0] - 2026-02-08

### Added

- **MLS Protocol (RFC 9420)**: Full group key agreement with forward secrecy and post-compromise security
- **61 API functions** covering complete MLS group lifecycle:
  - Group creation, join (Welcome, external commit), leave
  - Member management (add, remove, swap)
  - Encrypted messaging with additional authenticated data (AAD)
  - Proposals (add, remove, self-update with custom leaf node parameters, PSK, custom, group context extensions)
  - Commit handling (pending, flexible, merge/clear)
  - State queries (members, epoch, extensions, configuration, epoch authenticator, ratchet tree, group info, secrets)
  - Key package creation with options (lifetime, last-resort)
  - Storage cleanup (delete group, delete key package, remove pending proposal)
  - Basic and X.509 credential support (optional credential bytes on all creation functions)
  - Message inspection utilities (extract group ID, epoch, content type)
- **MlsClient**: Convenience wrapper injecting storage callbacks into every API call
- **MlsStorage**: Abstract key-value interface for pluggable persistence (SQLite, Hive, etc.)
- **InMemoryMlsStorage**: In-memory implementation for testing and prototyping
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

[1.0.0]: https://github.com/djx-y-z/openmls_dart/releases/tag/v1.0.0
