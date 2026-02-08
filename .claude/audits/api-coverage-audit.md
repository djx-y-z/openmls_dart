# API Coverage Audit — openmls_dart v1.0.0

## Objective

Verify that openmls_dart exposes all necessary OpenMLS functionality for a production-ready MLS (RFC 9420) client library. Identify any gaps, missing features, or incorrect implementations.

## Project Context

- **Package**: `openmls_dart` — Dart/Flutter wrapper for OpenMLS via Flutter Rust Bridge (FRB)
- **Upstream**: OpenMLS v0.8.0 (`openmls-v0.8.0` git tag)
- **Architecture**: 3 Dart KV storage callbacks (read/write/delete) bridged to Rust `StorageProvider` trait via `futures::executor::block_on()`
- **Key files**:
  - `rust/src/api/provider.rs` — 56 public API functions (53 async + 3 sync)
  - `rust/src/api/keys.rs` — `MlsSignatureKeyPair` wrapper + `serializeSigner()`
  - `rust/src/api/credential.rs` — `MlsCredential` wrapper (Basic + X.509)
  - `rust/src/api/config.rs` — `MlsGroupConfig` configuration struct
  - `rust/src/api/types.rs` — Shared enums and value types
  - `rust/src/dart_storage.rs` — `DartStorageProvider` (52 `StorageProvider` trait methods)
  - `lib/src/mls_client.dart` — `MlsClient` convenience wrapper + `MlsStorage` interface
  - `lib/src/in_memory_mls_storage.dart` — `InMemoryMlsStorage`
  - `lib/src/security/secure_bytes.dart` — `SecureBytes` wrapper
  - `lib/src/security/secure_uint8list.dart` — `SecureUint8List` extension

## Audit Checklist

### 1. OpenMLS `MlsGroup` Public API Coverage

Map every public method from OpenMLS's `MlsGroup` struct against our wrapper. The upstream API can be found at: https://github.com/openmls/openmls (tag `openmls-v0.8.0`), file `openmls/src/group/mls_group/mod.rs` and related modules.

#### 1.1 Group Creation

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `MlsGroup::new()` | `createGroup` | Verify | |
| `MlsGroup::new_with_group_id()` | `createGroup` (with `group_id` param) | Verify | |
| `MlsGroup::builder()` | `createGroupWithBuilder` | Verify | Exposes: group_id, lifetime, group_context_extensions, leaf_node_extensions, capabilities |
| `MlsGroup::load()` | Internal (`load_group` helper) | Verify | Used internally by all state-loading functions |

**Check**: Does `createGroupWithBuilder` expose all builder options? Compare against `MlsGroupBuilder` methods in upstream.

#### 1.2 Joining Groups

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `StagedWelcome::new_from_welcome()` + `into_group()` | `joinGroupFromWelcome` | Verify | |
| `StagedWelcome::build_from_welcome()` (builder) | `joinGroupFromWelcomeWithOptions` | Verify | Exposes: skip_lifetime_validation |
| `ProcessedWelcome::new_from_welcome()` | `inspectWelcome` | Verify | Returns group_id, ciphersuite, psk_count, epoch |
| `MlsGroup::join_by_external_commit()` (legacy) | `joinGroupExternalCommit` | Verify | Marked `#[allow(deprecated)]` |
| `MlsGroup::external_commit_builder()` | `joinGroupExternalCommitV2` | Verify | Exposes: aad, skip_lifetime_validation |

**Check**: Does `joinGroupFromWelcomeWithOptions` expose all `StagedWelcome` builder options? Are there other options besides `skip_lifetime_validation` and `with_ratchet_tree`?

#### 1.3 State Queries

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `group_id()` | `groupId` | Verify | |
| `epoch()` | `groupEpoch` | Verify | |
| `is_active()` | `groupIsActive` | Verify | |
| `members()` | `groupMembers` | Verify | Returns TLS-serialized credentials |
| `ciphersuite()` | `groupCiphersuite` | Verify | |
| `own_leaf_index()` | `groupOwnIndex` | Verify | |
| `credential()` | `groupCredential` | Verify | Returns TLS-serialized Credential |
| `extensions()` | `groupExtensions` | Verify | Returns TLS-serialized Extensions |
| `pending_proposals()` | `groupPendingProposals` | Verify | Returns proposal type + sender index |
| `has_pending_proposals()` | `groupHasPendingProposals` | Verify | |
| `member_at()` | `groupMemberAt` | Verify | Returns Option<MlsMemberInfo> |
| `member_leaf_index()` | `groupMemberLeafIndex` | Verify | Accepts TLS-serialized Credential |
| `own_leaf_node()` | `groupOwnLeafNode` | Verify | Returns full leaf node info |
| `confirmation_tag()` | `groupConfirmationTag` | Verify | |
| `export_ratchet_tree()` | `exportRatchetTree` | Verify | |
| `export_group_info()` | `exportGroupInfo` | Verify | |
| `export_secret()` | `exportSecret` | Verify | |
| `export_group_context()` | `exportGroupContext` | Verify | Returns tree_hash and confirmed_transcript_hash |
| `get_past_resumption_psk()` | `getPastResumptionPsk` | Verify | |

**Check**: Are there any other state query methods on `MlsGroup` that we're missing? Some to look for:
- `aad()` — get current AAD
- `pending_commit()` — inspect the pending commit
- `own_leaf()` vs `own_leaf_node()` — are they the same?
- `protocol_version()`
- `treesync()` — direct tree access

#### 1.4 Member Management (Mutations)

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `add_members()` | `addMembers` | Verify | Auto-merges pending commit |
| `add_members_without_update()` | `addMembersWithoutUpdate` | Verify | Auto-merges |
| `remove_members()` | `removeMembers` | Verify | Auto-merges |
| `self_update()` | `selfUpdate` | Verify | Auto-merges |
| `self_update_with_new_signer()` | `selfUpdateWithNewSigner` | Verify | Auto-merges, hardcodes BasicCredential |
| `swap_members()` | `swapMembers` | Verify | Auto-merges |
| `leave_group()` | `leaveGroup` | Verify | Returns remove proposal message |
| `leave_group_via_self_remove()` | `leaveGroupViaSelfRemove` | Verify | Requires plaintext wire format |

**Check**: Does `selfUpdateWithNewSigner` hardcode `BasicCredential::new()` for the new credential? This would break X.509 support. Line ~1062 in provider.rs uses `BasicCredential::new(new_credential_identity)`.

#### 1.5 Proposals

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `propose_add_member()` | `proposeAdd` | Verify | |
| `propose_remove_member()` | `proposeRemove` | Verify | By leaf index |
| `propose_self_update()` | `proposeSelfUpdate` | Verify | Default LeafNodeParameters |
| `propose_external_psk()` | `proposeExternalPsk` | Verify | |
| `propose_group_context_extensions()` | `proposeGroupContextExtensions` | Verify | |
| `propose_custom_proposal_by_reference()` | `proposeCustomProposal` | Verify | |
| `propose_remove_member_by_credential()` | `proposeRemoveMemberByCredential` | Verify | Accepts TLS-serialized Credential |

**Check**: Are there other proposal methods we're missing?
- `propose_add_member_by_value()` — proposals by value vs by reference
- `propose_self_update()` with custom `LeafNodeParameters` — we always use `default()`
- `propose_external_init()` — for external join proposals
- `propose_psk()` — resumption PSK (not just external)
- `store_pending_proposal()` — already used internally in `processMessage`

#### 1.6 Commit/Merge

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `commit_to_pending_proposals()` | `commitToPendingProposals` | Verify | Auto-merges |
| `merge_pending_commit()` | `mergePendingCommit` | Verify | Standalone |
| `clear_pending_commit()` | `clearPendingCommit` | Verify | |
| `clear_pending_proposals()` | `clearPendingProposals` | Verify | |
| `set_configuration()` | `setConfiguration` | Verify | |
| `update_group_context_extensions()` | `updateGroupContextExtensions` | Verify | Auto-merges |
| `commit_builder()` | `flexibleCommit` | Verify | Full builder: adds, removals, force_self_update, consume_pending, aad, gc_extensions, group_info control |
| `merge_staged_commit()` | Internal (inside `processMessage`) | Verify | |
| `store_pending_proposal()` | Internal (inside `processMessage`) | Verify | |

**Check**: Does `flexibleCommit` expose all `CommitBuilder` options? Look for:
- PSK proposals via commit builder
- Custom proposals via commit builder
- External init proposals
- Leaf node parameters (update proposal with custom params)

#### 1.7 Messages

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `create_message()` | `createMessage` | Verify | Supports AAD |
| `process_message()` | `processMessage` | Verify | Auto-merges staged commits, stores proposals |
| `process_message()` (inspect) | `processMessageWithInspect` | Verify | Returns StagedCommitInfo before merging |
| `set_aad()` | Internal (in `createMessage`, `flexibleCommit`) | Verify | |
| `MlsMessageIn::tls_deserialize()` | Internal | Verify | |
| `try_into_protocol_message()` | Internal | Verify | |

**Check**: Standalone message utilities (sync, no storage):
- `mlsMessageExtractGroupId` — extract group ID from protocol message
- `mlsMessageExtractEpoch` — extract epoch from protocol message
- `mlsMessageContentType` — get content type ("application"/"proposal"/"commit")

#### 1.8 Key Packages

| OpenMLS Method | Our Function | Status | Notes |
|---|---|---|---|
| `KeyPackage::builder().build()` | `createKeyPackage` | Verify | Basic builder |
| `KeyPackage::builder()` (full) | `createKeyPackageWithOptions` | Verify | lifetime, last_resort, capabilities, leaf_node_extensions, key_package_extensions |

**Check**: Are there other key package operations?
- `KeyPackage::delete()` — delete from storage
- `KeyPackage::hash_ref()` — get hash reference
- Key package validation options

### 2. Credential Support

| Feature | Status | Notes |
|---|---|---|
| `BasicCredential::new()` | Verify | Via `MlsCredential.basic()` |
| X.509 credential creation | Verify | Via `MlsCredential.x509()` |
| Credential identity extraction | Verify | Via `MlsCredential.identity()` |
| Certificate chain extraction | Verify | Via `MlsCredential.certificates()` |
| Credential type inspection | Verify | Via `MlsCredential.credentialType()` |
| TLS serialization | Verify | Via `MlsCredential.serialize()` |
| TLS deserialization | Verify | Via `MlsCredential.deserialize()` |
| Raw content access | Verify | Via `MlsCredential.serializedContent()` |

**Critical check**: Several functions in `provider.rs` use `BasicCredential::new(credential_identity)` directly:
- `createKeyPackage` (line ~126)
- `createKeyPackageWithOptions` (line ~160)
- `createGroup` (line ~218)
- `createGroupWithBuilder` (line ~264)
- `joinGroupExternalCommit` (line ~456)
- `joinGroupExternalCommitV2` (line ~517)
- `selfUpdateWithNewSigner` (line ~1062)

**Question**: Should these accept a TLS-serialized `Credential` instead of raw identity bytes, to support X.509? Or is `BasicCredential` correct for creating/joining since the credential type is chosen at creation time?

### 3. Key Management

| Feature | Status | Notes |
|---|---|---|
| `MlsSignatureKeyPair::generate()` | Verify | Wraps `SignatureKeyPair::new()` |
| `MlsSignatureKeyPair::fromRaw()` | Verify | Reconstruct from private+public bytes, zeroizes private key |
| `MlsSignatureKeyPair::publicKey()` | Verify | |
| `MlsSignatureKeyPair::privateKey()` | Verify | Requires `test-utils` feature |
| `MlsSignatureKeyPair::signatureScheme()` | Verify | |
| `MlsSignatureKeyPair::serialize()` | Verify | Public key + scheme only (JSON) |
| `MlsSignatureKeyPair::deserializePublic()` | Verify | Restores public key only |
| `serializeSigner()` | Verify | Full key pair (private + public + scheme) as JSON |
| `signer_from_bytes()` | Internal | Zeroizes input bytes |

**Check**: Is the signer serialization format appropriate? It uses JSON (`serde_json`) rather than a binary format. Is this secure and efficient?

### 4. Configuration

| Feature | Status | Notes |
|---|---|---|
| Ciphersuite: X25519+AES128+SHA256+Ed25519 | Verify | |
| Ciphersuite: X25519+ChaCha20+SHA256+Ed25519 | Verify | |
| Ciphersuite: P256+AES128+SHA256+P256 | Verify | |
| Wire format: Ciphertext | Verify | Default |
| Wire format: Plaintext | Verify | Needed for `leaveGroupViaSelfRemove` |
| Ratchet tree extension | Verify | Default: true |
| Max past epochs | Verify | |
| Padding size | Verify | |
| Sender ratchet configuration | Verify | max_out_of_order, max_forward_distance |
| Number of resumption PSKs | Verify | |

**Check**: Are there ciphersuites supported by OpenMLS v0.8.0 that we don't expose?
- `MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448`
- `MLS_256_DHKEMP384_AES256GCM_SHA384_P384`
- `MLS_256_DHKEMP521_AES256GCM_SHA512_P521`

### 5. Storage Provider Coverage

The `DartStorageProvider` implements OpenMLS's `StorageProvider<CURRENT_VERSION>` trait with 52 methods. Verify all are implemented:

#### Writers (17 methods)
- [ ] `write_mls_join_config`
- [ ] `write_tree`
- [ ] `write_context`
- [ ] `write_interim_transcript_hash`
- [ ] `write_confirmation_tag`
- [ ] `write_group_state`
- [ ] `write_message_secrets`
- [ ] `write_resumption_psk_store`
- [ ] `write_own_leaf_index`
- [ ] `write_group_epoch_secrets`
- [ ] `append_own_leaf_node`
- [ ] `queue_proposal`
- [ ] `write_signature_key_pair`
- [ ] `write_encryption_key_pair`
- [ ] `write_encryption_epoch_key_pairs`
- [ ] `write_key_package`
- [ ] `write_psk`

#### Readers (16 methods)
- [ ] `mls_group_join_config`
- [ ] `tree`
- [ ] `group_context`
- [ ] `interim_transcript_hash`
- [ ] `confirmation_tag`
- [ ] `group_state`
- [ ] `message_secrets`
- [ ] `resumption_psk_store`
- [ ] `own_leaf_index`
- [ ] `group_epoch_secrets`
- [ ] `own_leaf_nodes`
- [ ] `queued_proposal_refs`
- [ ] `queued_proposals`
- [ ] `signature_key_pair`
- [ ] `encryption_key_pair`
- [ ] `encryption_epoch_key_pairs`
- [ ] `key_package`
- [ ] `psk`

#### Deleters (15 methods)
- [ ] `remove_proposal`
- [ ] `delete_own_leaf_nodes`
- [ ] `delete_group_config`
- [ ] `delete_tree`
- [ ] `delete_confirmation_tag`
- [ ] `delete_group_state`
- [ ] `delete_context`
- [ ] `delete_interim_transcript_hash`
- [ ] `delete_message_secrets`
- [ ] `delete_all_resumption_psk_secrets`
- [ ] `delete_own_leaf_index`
- [ ] `delete_group_epoch_secrets`
- [ ] `clear_proposal_queue`
- [ ] `delete_signature_key_pair`
- [ ] `delete_encryption_key_pair`
- [ ] `delete_encryption_epoch_key_pairs`
- [ ] `delete_key_package`
- [ ] `delete_psk`

**Check**: Compare against the trait definition in `openmls_traits/src/storage.rs`. Are there any methods we missed?

### 6. Dart Convenience Wrapper (`MlsClient`)

Verify every `provider.rs` function has a corresponding method in `MlsClient`:

- [ ] All 53 async functions wrapped
- [ ] Storage callbacks injected correctly (read, write, delete)
- [ ] Parameter types match
- [ ] Return types match
- [ ] No missing methods

**Note**: The 3 sync message utilities (`mlsMessageExtractGroupId`, `mlsMessageExtractEpoch`, `mlsMessageContentType`) are NOT wrapped in `MlsClient` because they don't use storage. They're called directly via `import 'package:openmls/openmls.dart'`.

### 7. Missing OpenMLS Features to Evaluate

Check if these OpenMLS features should be exposed:

| Feature | Priority | Notes |
|---|---|---|
| External senders | Medium | For server-initiated proposals |
| ReInit proposals | Low | Group reinitialization |
| Custom credential types | Low | Beyond Basic and X.509 |
| Multiple ciphersuites per group | Low | Negotiation |
| Pre-shared key bundles (external) | Medium | `write_psk`/`psk` in storage, `proposeExternalPsk` exists |
| Group deletion from storage | Medium | No `deleteGroup()` that clears all storage entries |
| Key package deletion from storage | Medium | No exposed function to delete consumed key packages |
| Branch/subgroup creation | Low | |
| Protocol version negotiation | Low | Hardcoded to MLS 1.0 |
| Application-defined extensions | Medium | We use `Extension::Unknown` — is this correct? |
| Leaf node parameters for self-update | Low | We use `LeafNodeParameters::default()` |

### 8. Auto-Merge Behavior Audit

Several mutation functions auto-merge the pending commit after the operation. This is a design choice that simplifies the API but removes the ability to inspect/cancel before merging.

Functions that auto-merge:
- `addMembers`
- `addMembersWithoutUpdate`
- `removeMembers`
- `selfUpdate`
- `selfUpdateWithNewSigner`
- `swapMembers`
- `commitToPendingProposals`
- `updateGroupContextExtensions`
- `flexibleCommit`

Functions that auto-merge on process:
- `processMessage` — auto-merges staged commits, auto-stores proposals

**Check**: Is this acceptable for all use cases? The `processMessageWithInspect` variant provides the inspect-then-merge path. But for outgoing commits, there's no "create commit without merging" except through `flexibleCommit`'s internal `stage_commit`.

### 9. Error Handling

All functions return `Result<T, String>`. Errors are formatted as human-readable strings.

**Check**:
- Is `String` error type sufficient? Should we use structured error types?
- Do error messages ever leak sensitive information (key material, secrets)?
- Are all OpenMLS error variants handled (no `unwrap()` or `panic!()`)?

### 10. Test Coverage Summary

Current: 142 tests, 100% line coverage (710/710 lines) on hand-written code.

Test files:
- `test/group_lifecycle_test.dart` — Group creation, join, add members, messaging, proposals, commits, state queries, exports
- `test/api_types_test.dart` — Type enums, structs, equality, hashCode, toString
- `test/security/secure_bytes_test.dart` — SecureBytes wrapper (8 tests)
- `test/security/secure_uint8list_test.dart` — SecureUint8List extension (4 tests)

**Check**: Are there scenarios not covered by tests?
- Multi-group operations (same storage, different groups)
- Concurrent operations on the same group
- Error recovery (rollback after failed operations)
- Large groups (> 10 members)
- All ciphersuites (currently tests use only X25519+AES128+SHA256+Ed25519)
- X.509 credential flows end-to-end
- Key package expiration and last-resort behavior
- External PSK joining
- Custom proposals end-to-end

## How to Run This Audit

1. **Read upstream OpenMLS source** (tag `openmls-v0.8.0`):
   - `openmls/src/group/mls_group/mod.rs` — `MlsGroup` public methods
   - `openmls/src/group/mls_group/builder.rs` — `MlsGroupBuilder` options
   - `openmls/src/group/mls_group/membership.rs` — member management
   - `openmls/src/group/mls_group/proposal.rs` — proposal creation
   - `openmls/src/group/mls_group/processing.rs` — message processing
   - `openmls/src/group/mls_group/exporting.rs` — export operations
   - `openmls/src/group/mls_group/commit_builder/mod.rs` — `CommitBuilder`
   - `openmls/src/group/mls_group/external_commit_builder.rs` — external commit
   - `openmls/src/key_packages/mod.rs` — `KeyPackage` builder
   - `openmls_traits/src/storage.rs` — `StorageProvider` trait

2. **Cross-reference each method** against the tables above

3. **Verify correctness** of implementation by reading:
   - `rust/src/api/provider.rs` — all 56 functions
   - `rust/src/api/keys.rs` — key management
   - `rust/src/api/credential.rs` — credential handling
   - `rust/src/api/config.rs` — configuration
   - `rust/src/api/types.rs` — type conversions
   - `rust/src/dart_storage.rs` — storage implementation
   - `lib/src/mls_client.dart` — Dart wrapper

4. **Report findings** in categories:
   - **Critical**: Missing functionality that blocks production use
   - **Important**: Missing convenience features that users would expect
   - **Nice-to-have**: Features that could be added later
   - **Correct as-is**: Verified working correctly

## Expected Output

A report with:
1. Table of all OpenMLS public methods with coverage status (covered/missing/partially covered)
2. List of issues found with severity rating
3. Recommendations for v1.0.0 vs. future releases
4. Verification that the 56 function count in CHANGELOG is accurate
