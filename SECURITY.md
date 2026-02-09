# Security

## Architecture Overview

This library uses **Flutter Rust Bridge (FRB)** with the **OpenMLS** Rust crate.

**Key security properties:**

- **Memory safety** is handled by Rust's ownership system
- **Cryptographic operations** are implemented in OpenMLS (with RustCrypto backend)
- **No manual memory management** in Dart - FRB handles all cleanup automatically
- **No `dispose()` calls needed** - Rust drops resources when they go out of scope

## Security Considerations

### A: Memory Safety (Rust-handled)

With FRB, memory management is handled automatically:

```dart
// FRB Architecture - no cleanup needed
final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
final signerBytes = serializeSigner(
  ciphersuite: ciphersuite,
  privateKey: keyPair.privateKey(),
  publicKey: keyPair.publicKey(),
);
// keyPair is automatically cleaned up when no longer referenced
```

Rust's ownership system ensures:
- No use-after-free
- No double-free
- No memory leaks
- Deterministic cleanup

### B: Key Material Handling

Never expose key material in logs or errors:

```dart
// WRONG - exposes key material
print('Signer key: $signerBytes');
throw Exception('Failed with key: $keyBytes');

// CORRECT - no key material in logs
print('Generated new signing key pair');
throw Exception('Key operation failed');
```

### C: Store Security

`MlsStorage` persists sensitive cryptographic state (group secrets, key packages, ratchet trees). For production:

```dart
// WRONG - testing only, data lost on restart
final storage = InMemoryMlsStorage();

// CORRECT - production stores persist securely
final storage = SecureSqliteStorage();  // Implement MlsStorage yourself
```

**Store security requirements:**

- **Encrypt at rest** - storage contains key material
- **Access control** - only the app should read/write MLS state
- **Backup considerations** - MLS state includes forward-secrecy keys; restoring old state breaks protocol guarantees

### D: Initialization

Always initialize the library before use:

```dart
void main() async {
  await Openmls.init();  // Initialize FRB runtime
  runApp(MyApp());
}
```

### E: Group State Integrity

MLS group state must be consistent. Avoid:

- Processing the same message twice (replay)
- Skipping messages (causes epoch mismatch)
- Restoring old group state from backup (breaks forward secrecy)

The library returns errors for protocol violations. Handle them appropriately rather than silently ignoring.

## Supply Chain Security

- **SHA256 Checksums**: All pre-built native libraries are verified against checksums before use
- **Signed Releases**: GitHub Releases include checksum files for verification
- **Dependency Auditing**: `cargo audit` is run in CI to detect known vulnerabilities in Rust dependencies

## Build Security

- **Reproducible Builds**: CI builds are automated and reproducible
- **Minimal Dependencies**: We keep dependencies minimal and well-audited
- **LTO and Stripping**: Release builds use Link-Time Optimization and symbol stripping

## What's Handled by Rust/FRB

These concerns are handled automatically by the architecture:

| Concern | Handled By |
|---------|------------|
| FFI pointer management | Rust ownership |
| Resource cleanup | Rust drop semantics |
| Double-free prevention | Rust borrow checker |
| Buffer overflow prevention | Rust bounds checking |
| Use-after-free | Rust ownership |
| Cryptographic operations | OpenMLS + RustCrypto |
| Key zeroization | Rust (zeroize crate) |

## Zeroing Sensitive Data

### SecureBytes wrapper (automatic zeroing)

```dart
// Wrap takes ownership - no extra copy
final secureData = SecureBytes.wrap(sensitiveBytes);
try {
  // ... use secureData.bytes ...
} finally {
  secureData.dispose(); // Immediate zeroing (recommended)
}

// Copy constructor - original NOT zeroed (caller responsible)
final secureCopy = SecureBytes(sensitiveBytes);
sensitiveBytes.zeroize(); // Zero the original yourself
```

### Manual zeroing extension

```dart
final sensitiveList = Uint8List.fromList([...]);
try {
  // ... use sensitiveList ...
} finally {
  sensitiveList.zeroize(); // Zero all bytes
}
```

### APIs that Return Sensitive Data

The following APIs return data that should be zeroized after use (via `SecureBytes.wrap()` or `.zeroize()`):

| API | Returns | Sensitivity |
|-----|---------|-------------|
| `MlsSignatureKeyPair.privateKey()` | Private signing key | HIGH — long-term key material |
| `serializeSigner()` | JSON with private key | HIGH — contains private key bytes |
| `MlsClient.exportSecret()` | MLS exporter secret | HIGH — derived secret |
| `MlsClient.getPastResumptionPsk()` | Resumption PSK | HIGH — pre-shared key |

These return `Uint8List` or `List<int>` due to FRB signature constraints. Callers must zeroize.

### Limitations

- Dart's garbage collector may copy data before zeroing occurs
- These utilities provide defence-in-depth, not absolute security guarantees
- For critical secrets, prefer keeping them in Rust (opaque types with `zeroize` crate)

## Known Limitations

1. **Dart VM memory:** Dart's garbage collector may copy data before Rust can zero it. This is a platform limitation. OpenMLS uses the `zeroize` crate for sensitive data on the Rust side.

2. **In-memory storage:** `InMemoryMlsStorage` loses all state on app restart. Production apps must implement persistent `MlsStorage`.

3. **No `unsafe` code:** The wrapper layer contains no `unsafe` Rust code. All `unsafe` usage is in upstream OpenMLS and RustCrypto crates, which are well-audited.

4. **Storage callback timeout:** The `block_on()` bridge from Rust's synchronous `StorageProvider` trait to Dart's async callbacks has no built-in timeout. Storage backends must complete promptly to avoid blocking the Rust thread pool.

5. **Concurrency:** There is no internal synchronization for concurrent access to the same MLS group. Callers must serialize operations on the same group (e.g., process messages in order from a single async task).

6. **Storage atomicity:** Storage operations are not transactional. If the app crashes mid-operation, storage may be left in an inconsistent state. Production backends should use transactions or write-ahead logging.

7. **`test-utils` feature dependency:** The `openmls` and `openmls_basic_credential` crates are compiled with the `test-utils` feature enabled. This is required for `SignatureKeyPair::private()`, which powers the `privateKey()` API. The feature only enables accessor methods — no test-only code paths are activated in production.

8. **Automatic commit merging:** `processMessage` and `processMessageWithInspect` automatically merge staged commits after processing. There is no mechanism to inspect a commit and then reject it — this is by design, as MLS requires commits to be applied in order. `processMessageWithInspect` returns commit details (adds, removes, updates) for logging/UI purposes.

9. **Unconditional proposal acceptance:** `flexibleCommit` and `joinGroupExternalCommitV2` accept all pending proposals unconditionally (the internal proposal filter callback returns `true` for all proposals). Applications should validate proposals at the application layer before calling commit operations, or use `removePendingProposal` to reject unwanted proposals first.

10. **X.509 certificate chain validation:** The `MlsCredential.x509()` function does not validate certificate chains (expiration, signatures, revocation, trust anchors). The application layer must validate X.509 chains before use.

11. **serde_json intermediate buffers:** During signer serialization/deserialization, `serde_json` creates temporary `Vec<u8>` buffers containing sensitive data. These are dropped without zeroization. This is a platform limitation — Rust's allocator does not guarantee memory is not copied, so zeroizing every intermediate buffer provides limited benefit.

## Code Review Security Checklist

When reviewing code changes, verify:

- [ ] No in-memory stores in production code
- [ ] No key material in logs or error messages
- [ ] `Openmls.init()` called before any operations
- [ ] Store operations properly secured (encryption at rest)
- [ ] Error handling doesn't leak sensitive information
- [ ] MLS protocol messages processed in order
- [ ] Sensitive data in Dart uses `SecureBytes` or `.zeroize()` extension
- [ ] No hardcoded keys or secrets

## Upstream Security

This package wraps OpenMLS. For security issues in the underlying library:

- Check the upstream repository: [openmls/openmls](https://github.com/openmls/openmls)
- Security advisories may be published there first

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. Use [GitHub's private vulnerability reporting](https://github.com/djx-y-z/openmls_dart/security/advisories/new) to report the issue
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Development**: Depends on severity and complexity
- **Public Disclosure**: Coordinated with reporter after fix is available

## Security Updates

Subscribe to releases on this repository to receive notifications about security updates.
