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
- **Storage callbacks** use DartFn to bridge Dart MlsStorage to Rust

## Security Categories

### A: API Usage Correctness

- [ ] Correct constructor patterns used (`MlsSignatureKeyPair.generate()`)
- [ ] Proper async/await for provider operations
- [ ] Storage callbacks correctly wired via MlsClient
- [ ] `Openmls.init()` called before any operations

```dart
// CORRECT
await Openmls.init();
final client = MlsClient(storage);
final result = await client.createGroup(...);

// WRONG - not initialized
final result = await client.createGroup(...);
```

### B: Store Security

- [ ] Production apps use persistent MlsStorage (not InMemoryMlsStorage)
- [ ] Storage backend encrypts data at rest
- [ ] Storage access is restricted to the application

```dart
// WRONG - in-memory stores lose state on restart
final storage = InMemoryMlsStorage();

// CORRECT - production stores persist securely
final storage = SecureSqliteMlsStorage();
```

### C: Key Material Handling

- [ ] Private keys not logged or printed
- [ ] Serialized signers not stored in plain text
- [ ] Key material not included in error messages

```dart
// WRONG - exposes key material
print('Signer: ${signer.serialize()}');
throw Exception('Failed with key: $signerBytes');

// CORRECT - no key material in logs
print('Generated new signing key pair');
throw Exception('Key operation failed');
```

### D: Group State Integrity

- [ ] MLS messages processed in order (no skipping)
- [ ] Same message not processed twice (replay prevention)
- [ ] Old group state not restored from backup (breaks forward secrecy)
- [ ] Welcome messages processed correctly (not re-processing add commits)

```dart
// CORRECT - process messages in order
final result = await client.processMessage(
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
  final result = await client.processMessage(
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
// CORRECT - check member credentials
final members = await client.groupMembers(groupIdBytes: groupId);
for (final member in members) {
  // Verify member identity
  if (!isKnownMember(member.credential)) {
    // Handle unknown member
  }
}
```

## Quick Checklist

```
[ ] No InMemoryMlsStorage in production code
[ ] No key material in logs/errors
[ ] Openmls.init() called at startup
[ ] Messages processed in order
[ ] Storage backend encrypts at rest
[ ] Welcome/commit processed correctly (no duplicate processing)
[ ] Error handling doesn't leak sensitive data
```

## Red Flags

- `InMemoryMlsStorage` in production code
- `print()` or logging with signer bytes or key material
- Processing the same commit message multiple times
- Restoring MLS group state from old backups
- Missing `await` on provider operations
- Ignoring errors from `processMessage`

## Example Review Output

```
## Security Review: lib/src/my_feature.dart

### Issues Found

1. **Line 45**: Using InMemoryMlsStorage in production
   - Category: B
   - Severity: HIGH
   - Fix: Implement persistent MlsStorage with encryption at rest

2. **Line 78**: Signer bytes logged
   - Category: C
   - Severity: HIGH
   - Fix: Remove key material from log statement

3. **Line 102**: Error message includes message bytes
   - Category: E
   - Severity: MEDIUM
   - Fix: Log operation type only, not the raw bytes

### Recommendations

- Add encryption at rest for MlsStorage implementation
- Validate member credentials after group joins
```

## Files to Review

| Area | Files |
|------|-------|
| Storage implementation | `lib/src/mls_client.dart`, `lib/src/in_memory_mls_storage.dart` |
| Provider API | `rust/src/api/provider.rs` |
| Storage bridge | `rust/src/dart_storage.rs` |
| Key management | `rust/src/api/keys.rs` |
| Credentials | `rust/src/api/credential.rs` |
| Tests | `test/` |

## Reference

- See `SECURITY.md` for full security guidelines
- See `.claude/skills/frb-patterns/SKILL.md` for FRB architecture patterns
