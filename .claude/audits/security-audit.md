# Security Audit — openmls_dart v1.0.0

## Objective

Comprehensive security review of the openmls_dart wrapper layer. This is a cryptographic library (MLS protocol, RFC 9420) where security is paramount. The audit focuses on the **wrapper code** (not the upstream OpenMLS Rust library itself).

## Project Context

- **Package**: `openmls_dart` — Dart/Flutter wrapper for OpenMLS via Flutter Rust Bridge (FRB)
- **Upstream**: OpenMLS v0.8.0 (Rust, well-audited)
- **Crypto backend**: RustCrypto (pure Rust, no C dependencies)
- **Architecture**: Dart calls async Rust functions via FRB; storage callbacks bridge sync StorageProvider trait to async Dart via `futures::executor::block_on()`

### Files to Audit

| File | Language | Lines | Description |
|---|---|---|---|
| `rust/src/api/provider.rs` | Rust | ~1662 | 56 public API functions |
| `rust/src/api/keys.rs` | Rust | ~156 | Signature key pair management |
| `rust/src/api/credential.rs` | Rust | ~121 | Credential management (Basic + X.509) |
| `rust/src/api/config.rs` | Rust | ~69 | Group configuration |
| `rust/src/api/types.rs` | Rust | ~251 | Shared types and conversions |
| `rust/src/dart_storage.rs` | Rust | ~881 | StorageProvider trait implementation |
| `lib/src/mls_client.dart` | Dart | ~735 | MlsClient convenience wrapper |
| `lib/src/in_memory_mls_storage.dart` | Dart | ~51 | In-memory storage implementation |
| `lib/src/security/secure_bytes.dart` | Dart | ~83 | SecureBytes wrapper |
| `lib/src/security/secure_uint8list.dart` | Dart | ~12 | Uint8List zeroing extension |

## Audit Categories

---

### A. Key Material Handling

#### A1. Signer Serialization Format

**File**: `rust/src/api/keys.rs`

The signer (private + public key + scheme) is serialized as JSON via `serde_json`:

```rust
pub fn serialize_signer(
    ciphersuite: MlsCiphersuite,
    mut private_key: Vec<u8>,
    public_key: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let result = serde_json::to_vec(&SerializableSigner {
        private: private_key.clone(),
        public: public_key,
        scheme: cs.signature_algorithm() as u16,
    });
    private_key.zeroize();
    result
}
```

**Check**:
- [ ] Is JSON an appropriate format for private key material? (human-readable, not compact)
- [ ] The `private_key.clone()` before `zeroize()` — does the clone create a copy that isn't zeroized? The cloned data goes into `SerializableSigner` → `serde_json::to_vec` → caller. The original `private_key` is zeroized. But the intermediate `SerializableSigner.private` field is NOT zeroized (it's moved into the JSON serializer).
- [ ] `signer_from_bytes()` (line 148) zeroizes `signer_bytes` input after deserialization. But the deserialized `SerializableSigner` struct's `.private` field is moved into `SignatureKeyPair::from_raw()` — is this field zeroized by OpenMLS?

#### A2. Private Key Exposure in `MlsSignatureKeyPair`

**File**: `rust/src/api/keys.rs`

```rust
pub fn private_key(&self) -> Vec<u8> {
    self.inner.private().to_vec()
}
```

**Check**:
- [ ] This returns a `Vec<u8>` of private key bytes. The caller (Dart) receives this as `Uint8List`. Is this ever necessary? Who calls it?
- [ ] The returned `Vec<u8>` is NOT zeroized by us — it becomes Dart-side data. Recommend using `SecureBytes.wrap()` in Dart.
- [ ] `private()` requires `test-utils` feature on `openmls_basic_credential`. Is enabling test-utils in production a security concern?

#### A3. Key Zeroization in `from_raw()`

**File**: `rust/src/api/keys.rs`

```rust
pub fn from_raw(
    ciphersuite: MlsCiphersuite,
    mut private_key: Vec<u8>,
    public_key: Vec<u8>,
) -> Result<MlsSignatureKeyPair, String> {
    let kp = SignatureKeyPair::from_raw(cs.signature_algorithm(), private_key.clone(), public_key);
    private_key.zeroize();
    Ok(MlsSignatureKeyPair { inner: kp })
}
```

**Check**:
- [ ] `private_key.clone()` creates a copy that is passed to `from_raw()`. The original is zeroized. But the clone is now owned by `SignatureKeyPair`. Is this properly zeroized on drop?
- [ ] Does the `zeroize` crate derive on `SignatureKeyPair` ensure the private key is zeroized?

#### A4. Signer Storage in Provider

**File**: `rust/src/api/provider.rs` (multiple locations)

Several functions call `signer.store(provider.storage())`:
- `createGroup` (line 228)
- `createGroupWithBuilder` (line 272)
- `joinGroupFromWelcome` (line 338)
- `joinGroupFromWelcomeWithOptions` (line 380)
- `joinGroupExternalCommit` (line 464)
- `joinGroupExternalCommitV2` (line 525)
- `selfUpdateWithNewSigner` (line 1060)

**Check**:
- [ ] This stores the full `SignatureKeyPair` (including private key) in Dart's storage via the write callback. The private key is stored in the Dart-side database. Is this expected behavior? (Yes — OpenMLS needs to load the signer from storage later.)
- [ ] Is the stored key material encrypted? (That's the Dart implementation's responsibility via `MlsStorage`.)

---

### B. Storage Security

#### B1. Key Format

**File**: `rust/src/dart_storage.rs`

Storage keys are composite bytes: `[LABEL || serde_json(key_data) || VERSION_BE_U16]`

**Check**:
- [ ] Are storage keys predictable? Could an attacker infer what's stored by observing key patterns?
- [ ] Labels are constant strings (e.g., `b"SignatureKeyPair"`, `b"EpochSecrets"`). This leaks storage category metadata even if values are encrypted.
- [ ] Is there a risk of key collision between different label types?

#### B2. Value Serialization

All values are serialized via `serde_json`. This means:
- Group secrets, epoch secrets, message secrets are JSON-encoded
- Private keys stored by OpenMLS are JSON-encoded in storage

**Check**:
- [ ] Is JSON appropriate for cryptographic material? (human-readable, includes type metadata)
- [ ] Does JSON serialization normalize values in a way that could cause issues? (e.g., number precision for epoch values)
- [ ] The `serde_json` serialization matches OpenMLS's `MemoryStorage` format exactly. This ensures compatibility.

#### B3. `block_on()` Safety

**File**: `rust/src/dart_storage.rs`

```rust
fn kv_write(&self, key: Vec<u8>, value: Vec<u8>) {
    futures::executor::block_on((self.write_fn)(key, value));
}
```

**Check**:
- [ ] `block_on` blocks the current thread waiting for the Dart callback to complete. If Dart's storage implementation hangs or deadlocks, the Rust thread blocks forever. Is there a timeout?
- [ ] On WASM, `block_on` works because FRB's DartFnFuture uses a channel mechanism (confirmed by libsignal_dart). Verify this is still true.
- [ ] Could a malicious/broken storage implementation cause denial-of-service by never completing callbacks?

#### B4. `InMemoryMlsStorage` Security

**File**: `lib/src/in_memory_mls_storage.dart`

- Uses `Map<String, Uint8List>` with base64-encoded keys
- No encryption at rest
- No access control
- Data lost on GC/app restart

**Check**:
- [ ] This is clearly labeled for testing only. But is there a risk that users use it in production?
- [ ] Keys are base64-encoded in the Map. Could this cause issues with Map performance for large datasets?
- [ ] The `clear()` method doesn't zeroize values before removing them.

---

### C. Error Handling Security

#### C1. Error Message Content

All 56 API functions return `Result<T, String>` with error messages like:
```rust
.map_err(|e| format!("Failed to create group: {}", e))
```

**Check**:
- [ ] Do any error messages include sensitive data (key material, secrets, credentials)?
- [ ] OpenMLS errors may contain internal state information. Does `format!("{}", e)` on OpenMLS errors leak sensitive data?
- [ ] The `DartStorageError::Serialization(String)` variant includes the `serde_json` error message. Could deserialization errors leak stored values?

#### C2. Error Recovery

**Check**:
- [ ] After a failed operation, is the group state still consistent?
- [ ] If `merge_pending_commit` fails after a successful `add_members`, the group has a pending commit in an inconsistent state. Is there recovery?
- [ ] If a storage callback fails (throws in Dart), `block_on` will panic. Is this caught?

---

### D. Protocol Correctness

#### D1. Message Processing

**File**: `rust/src/api/provider.rs` — `process_message` (line 1484)

**Check**:
- [ ] `processMessage` auto-merges staged commits. This means the caller cannot inspect the commit before applying it. Is this a security concern?
- [ ] `processMessageWithInspect` returns `StagedCommitInfo` but then also auto-merges. Wait — does it? Check line 1585: `group.merge_staged_commit(&provider, *staged_commit)`. Yes, it does auto-merge. So "inspect" means "see info about the commit" but it still gets applied. Is this correct?
- [ ] Proposal messages are auto-stored via `store_pending_proposal`. This means any received proposal is kept. Is there validation?

#### D2. Replay Protection

**Check**:
- [ ] OpenMLS handles replay protection via epoch tracking. Our wrapper doesn't add any replay protection. Is this correct?
- [ ] If the same message is processed twice, does OpenMLS reject it?

#### D3. Welcome Processing

**Check**:
- [ ] Welcome messages include secrets. After `joinGroupFromWelcome`, are the welcome secrets properly consumed and not lingering in memory?
- [ ] The `inspectWelcome` function creates a `ProcessedWelcome` that contains secrets. This is created with a fresh provider (separate storage). Are those secrets cleaned up?

#### D4. External Commit Security

**Check**:
- [ ] `joinGroupExternalCommit` is marked `#[allow(deprecated)]`. Should we use v2 only?
- [ ] External commits allow anyone with a GroupInfo to join. Is GroupInfo export properly gated?
- [ ] The `export_group_info` function requires a signer. This is correct — GroupInfo must be signed.

---

### E. Memory Safety (Rust Side)

#### E1. No `unsafe` Code

**Check**:
- [ ] Verify no `unsafe` blocks in our wrapper code (`provider.rs`, `keys.rs`, `credential.rs`, `config.rs`, `types.rs`, `dart_storage.rs`)
- [ ] FRB-generated code (`frb_generated.rs`) may contain `unsafe`. This is expected and audited by FRB.

#### E2. Zeroize Usage

**File**: `rust/src/api/keys.rs`

```rust
use zeroize::Zeroize;
// ...
private_key.zeroize(); // In serialize_signer and from_raw
signer_bytes.zeroize(); // In signer_from_bytes
```

**Check**:
- [ ] All paths that handle private key material call `.zeroize()` on temporary buffers
- [ ] Are there any temporary `Vec<u8>` containing private keys that are NOT zeroized?
- [ ] The `serde_json` serialization creates intermediate buffers — are those zeroized?

#### E3. Panic Safety

**Check**:
- [ ] If `block_on` panics (e.g., Dart callback throws), does this unwind safely?
- [ ] Are there any `unwrap()` calls in our code that could panic?
- [ ] What happens if `serde_json::from_slice` encounters invalid data in storage?

---

### F. Memory Safety (Dart Side)

#### F1. SecureBytes

**File**: `lib/src/security/secure_bytes.dart`

**Check**:
- [ ] `Finalizer` callback zeros data when GC collects. But Dart GC may have already moved/copied the data. This is documented as a limitation.
- [ ] `dispose()` zeros immediately and detaches finalizer. This is the recommended pattern.
- [ ] Multiple `dispose()` calls are safe (idempotent).
- [ ] `bytes` getter throws `StateError` after dispose. This prevents use-after-free at the Dart level.
- [ ] `SecureBytes.wrap()` takes ownership of the input buffer. The caller's reference still points to the same memory, which is now zeroed on dispose. This is correct behavior but could surprise callers.

#### F2. SecureUint8List Extension

**File**: `lib/src/security/secure_uint8list.dart`

```dart
void zeroize() => fillRange(0, length, 0);
```

**Check**:
- [ ] This zeros the backing buffer. But if the `Uint8List` is a view of a `ByteBuffer`, only the view range is zeroed, not the full buffer. Is this a concern?
- [ ] Dart's optimizer could potentially elide the zeroing if the list is not used afterward. (Unlikely with `fillRange`, but possible in theory.)

---

### G. Supply Chain Security

#### G1. Dependencies

**File**: `rust/Cargo.toml`

```toml
flutter_rust_bridge = "=2.11.1"   # Pinned exact version
openmls = { git = "...", tag = "openmls-v0.8.0", features = ["test-utils"] }
openmls_rust_crypto = { git = "...", tag = "openmls-v0.8.0" }
openmls_basic_credential = { git = "...", tag = "openmls-v0.8.0", features = ["test-utils"] }
openmls_traits = { git = "...", tag = "openmls-v0.8.0" }
thiserror = "2.0"
zeroize = "1.8"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
futures = "0.3"
```

**Check**:
- [ ] `test-utils` feature enabled on `openmls` and `openmls_basic_credential`. Does this add any code that shouldn't be in production? (It adds `tree_hash()` access and `private()` key access.)
- [ ] All OpenMLS crates are pinned to `openmls-v0.8.0` git tag. This is good — no floating references.
- [ ] `flutter_rust_bridge` is pinned to exact `=2.11.1`. This prevents unexpected updates.
- [ ] Other crates use semver ranges. Could a malicious minor version update introduce vulnerabilities?
- [ ] Run `cargo audit` to check for known vulnerabilities.

#### G2. Build Security

**Check**:
- [ ] Release profile: `lto = true, opt-level = "z", strip = true`. LTO and stripping reduce attack surface.
- [ ] Pre-built binaries are downloaded from GitHub Releases with SHA256 verification.
- [ ] Build is reproducible (automated CI).

---

### H. Specific Code Review Items

#### H1. `BasicCredential::new()` Hardcoding

Multiple functions create `BasicCredential::new(credential_identity)` from raw identity bytes:
- `createKeyPackage` (line ~126)
- `createKeyPackageWithOptions` (line ~160)
- `createGroup` (line ~218)
- `createGroupWithBuilder` (line ~264)
- `joinGroupExternalCommit` (line ~456)
- `joinGroupExternalCommitV2` (line ~517)
- `selfUpdateWithNewSigner` (line ~1062)

**Security concern**: If a user has X.509 credentials, these functions cannot be used — they always create BasicCredential. The credential type should ideally be determined by the input, not hardcoded. However, this is an API design issue rather than a direct security vulnerability, since the wrong credential type would simply fail at the protocol level.

#### H2. Proposal Queue Processing

**File**: `rust/src/dart_storage.rs` — `queue_proposal()` and `clear_proposal_queue()`

**Check**:
- [ ] `queue_proposal` stores proposals individually AND appends to a refs list. Could this lead to inconsistency if one write succeeds and the other fails?
- [ ] `clear_proposal_queue` reads all refs, deletes each proposal, then deletes the refs list. If the process is interrupted (app crash), orphaned proposals could remain in storage. Is this a concern?

#### H3. AAD (Additional Authenticated Data)

`createMessage` and `flexibleCommit` support AAD via `group.set_aad()`.

**Check**:
- [ ] Is AAD properly cleared after use? If `createMessage` sets AAD for one message, does it persist for subsequent messages on the same group instance? (The group is loaded fresh each time, so no — each call creates a new group instance from storage.)

#### H4. Group Info Export

```rust
pub async fn export_group_info(...) -> Result<Vec<u8>, String> {
    let group_info = group.export_group_info(provider.crypto(), &signer, true)?;
    // 'true' = include ratchet tree extension
}
```

**Check**:
- [ ] GroupInfo is always exported with ratchet tree extension (`true`). Should this be configurable?
- [ ] GroupInfo allows external commits. Should there be a way to export without enabling external joins?

---

### I. Concurrency and Thread Safety

#### I1. Storage Callbacks

Each API call creates a fresh `DartOpenMlsProvider` with its own set of callbacks.

**Check**:
- [ ] If multiple API calls happen concurrently (from different Dart isolates or async tasks), they share the same `MlsStorage` instance. Could this cause race conditions?
- [ ] The `InMemoryMlsStorage` uses a plain `Map` — no synchronization. Concurrent access from multiple async tasks could corrupt data.
- [ ] In practice, MLS groups should be accessed sequentially (messages must be processed in order). But the API doesn't enforce this.

#### I2. `block_on` Thread Blocking

**Check**:
- [ ] FRB runs Rust functions on a separate thread pool. `block_on` blocks the Rust thread but not the Dart isolate. This is correct.
- [ ] If many concurrent API calls are made, all Rust threads could be blocked waiting for Dart callbacks. Could this exhaust the thread pool?

---

## How to Run This Audit

1. **Read all source files** listed in the table above
2. **For each check item**, verify by reading the code and mark as:
   - `PASS` — No issue found
   - `ISSUE` — Security issue found (describe severity and recommendation)
   - `NOTE` — Not a security issue but worth documenting
3. **Run `cargo audit`** to check for known vulnerabilities:
   ```bash
   make rust-audit
   ```
4. **Review error messages** — grep for `format!` in all Rust files and verify no sensitive data
5. **Review all `unwrap()`** calls — there should be none in our code
6. **Review all `zeroize` usage** — verify all private key paths are covered

## Expected Output

A report with:
1. Summary of findings by severity (Critical / High / Medium / Low / Info)
2. Detailed finding for each issue with:
   - Location (file:line)
   - Description
   - Severity
   - Recommendation
3. Verification that SECURITY.md accurately describes the security properties
4. Recommendations for v1.0.0 vs. future releases

## Reference Documents

- [SECURITY.md](/Users/djxyz/_DISK_/PROJECTS/Flutter/packages/openmls_dart/SECURITY.md) — Current security documentation
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) — MLS Protocol specification
- [OpenMLS Security](https://github.com/openmls/openmls/blob/main/SECURITY.md) — Upstream security policy
- [OWASP Cryptographic Failures](https://owasp.org/Top10/A02_2021-Cryptographic_Failures/) — Common crypto issues
