---
name: security-review
description: Review openmls Dart code for security issues. Use when reviewing code changes, checking for proper API usage, verifying secure patterns, or auditing cryptographic code.
---

# Security Review for openmls_dart

Review code for security issues specific to this MLS protocol library.

## Architecture Context

This library uses Flutter Rust Bridge (FRB) with OpenMLS (pure Rust):
- **Memory safety** is handled by Rust (no manual FFI memory management)
- **Cryptographic operations** are implemented in OpenMLS with RustCrypto backend
- **Storage** is Rust-owned and encrypted — SQLCipher on native, IndexedDB + Web Crypto AES-256-GCM on WASM

## Security Categories

### A: API Usage Correctness

- [ ] Correct constructor patterns used (`MlsSignatureKeyPair.generate()`)
- [ ] Proper async/await for engine operations
- [ ] `Openmls.init()` called before any operations
- [ ] `MlsEngine.create()` called with a proper 32-byte encryption key

```dart
// CORRECT
await Openmls.init();
final engine = await MlsEngine.create(
  dbPath: 'mls_data.db',
  encryptionKey: myKey, // 32-byte key from secure storage
);
final result = await engine.createGroup(...);

// WRONG — not initialized
final result = await engine.createGroup(...);
```

### B: Storage Security

- [ ] Encryption key stored in platform secure storage (Keychain, Android Keystore)
- [ ] Encryption key is not hardcoded or logged
- [ ] `:memory:` databases only used in tests, not production
- [ ] Database path includes account identifier for multi-user isolation

```dart
// WRONG — hardcoded key in production
final engine = await MlsEngine.create(
  dbPath: 'mls.db',
  encryptionKey: Uint8List(32), // all zeros!
);

// CORRECT — key from secure storage
final key = await secureStorage.read(key: 'mls_encryption_key');
final engine = await MlsEngine.create(
  dbPath: 'mls_$accountId.db',
  encryptionKey: key,
);
```

### C: Key Material Handling

- [ ] Private keys not logged or printed
- [ ] Serialized signers not stored in plain text
- [ ] Key material not included in error messages

```dart
// WRONG — exposes key material
print('Signer: ${signer.serialize()}');
throw Exception('Failed with key: $signerBytes');

// CORRECT — no key material in logs
print('Generated new signing key pair');
throw Exception('Key operation failed');
```

### D: Group State Integrity

- [ ] MLS messages processed in order (no skipping)
- [ ] Same message not processed twice (replay prevention)
- [ ] Old group state not restored from backup (breaks forward secrecy)
- [ ] Welcome messages processed correctly (not re-processing add commits)

```dart
// CORRECT — process messages in order
final result = await engine.processMessage(
  groupIdBytes: groupId,
  messageBytes: incomingMessage,
);

// Handle result based on type
switch (result.messageType) {
  case 'application':
    // Handle application message
    break;
  case 'commit':
    // Commit already merged by processMessage
    break;
  case 'proposal':
    // Proposal stored, will be committed later
    break;
}
```

### E: Error Handling

- [ ] Cryptographic failures don't leak information
- [ ] Proper exception handling for protocol errors
- [ ] Errors logged without sensitive data

```dart
// CORRECT
try {
  final result = await engine.processMessage(
    groupIdBytes: groupId,
    messageBytes: messageBytes,
  );
} catch (e) {
  // Log operation failure, not the message bytes
  log.warning('Failed to process message in group');
  rethrow;
}
```

### F: Credential Handling

- [ ] Credential identity bytes validated before use
- [ ] X.509 certificates validated if used
- [ ] Member credentials checked after joins

```dart
// CORRECT — check member credentials
final members = await engine.groupMembers(groupIdBytes: groupId);
for (final member in members) {
  // Verify member identity
  if (!isKnownMember(member.credential)) {
    // Handle unknown member
  }
}
```

## Quick Checklist

```
[ ] No hardcoded or all-zero encryption keys in production
[ ] No key material in logs/errors
[ ] Openmls.init() called at startup
[ ] MlsEngine created with secure key from platform storage
[ ] Messages processed in order
[ ] Welcome/commit processed correctly (no duplicate processing)
[ ] Error handling doesn't leak sensitive data
[ ] :memory: databases only in tests
```

## Red Flags

- `Uint8List(32)` (all-zero key) in production code
- `print()` or logging with signer bytes or key material
- Processing the same commit message multiple times
- Restoring MLS group state from old backups
- Missing `await` on engine operations
- Ignoring errors from `processMessage`
- Hardcoded encryption key or key stored in plain text

## Example Review Output

```
## Security Review: lib/src/my_feature.dart

### Issues Found

1. **Line 45**: Hardcoded all-zero encryption key
   - Category: B
   - Severity: HIGH
   - Fix: Load encryption key from platform secure storage

2. **Line 78**: Signer bytes logged
   - Category: C
   - Severity: HIGH
   - Fix: Remove key material from log statement

3. **Line 102**: Error message includes message bytes
   - Category: E
   - Severity: MEDIUM
   - Fix: Log operation type only, not the raw bytes

### Recommendations

- Store encryption key in Keychain/Android Keystore
- Validate member credentials after group joins
```

## Files to Review

| Area | Files |
|------|-------|
| Engine API | `rust/src/api/engine.rs` |
| Encrypted storage | `rust/src/encrypted_db.rs` |
| Snapshot storage | `rust/src/snapshot_storage.rs` |
| Key management | `rust/src/api/keys.rs` |
| Credentials | `rust/src/api/credential.rs` |
| Tests | `test/` |

## Reference

- See `SECURITY.md` for full security guidelines
- See `.claude/skills/frb-patterns/SKILL.md` for FRB architecture patterns
