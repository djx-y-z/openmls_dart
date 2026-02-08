---
name: frb-patterns
description: Flutter Rust Bridge patterns and best practices for this project. Use when writing Rust API code, adding new bindings, implementing DartFn callbacks, or troubleshooting FRB issues.
---

# FRB Patterns for openmls_dart

Patterns and templates for writing correct Flutter Rust Bridge code in this project.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│          OpenMLS (Rust crate)                   │  Core MLS implementation
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

## Key Components

| Component | File | Purpose |
|-----------|------|---------|
| DartStorageProvider | `rust/src/dart_storage.rs` | Implements OpenMLS `StorageProvider` trait via 3 DartFn callbacks |
| DartOpenMlsProvider | `rust/src/dart_storage.rs` | Combines RustCrypto + DartStorageProvider |
| Provider API | `rust/src/api/provider.rs` | ~53 async API functions with storage callbacks |
| MlsClient | `lib/src/mls_client.dart` | Dart wrapper that injects MlsStorage into every call |
| MlsStorage | `lib/src/mls_client.dart` | Abstract KV interface (read/write/delete) |

## Provider-Based API Pattern

Every API function that accesses MLS state takes 3 storage callbacks:

```rust
pub async fn create_group(
    config: MlsGroupConfig,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    group_id: Option<Vec<u8>>,
    // Storage callbacks - always these 3
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CreateGroupProviderResult, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    // ... OpenMLS operations using provider
}
```

### Internal Helpers

```rust
// Creates DartOpenMlsProvider from callbacks (not pub - internal only)
fn make_provider(
    read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> DartOpenMlsProvider

// Loads existing group from storage
fn load_group(group_id: &[u8], provider: &DartOpenMlsProvider) -> Result<MlsGroup, String>
```

### Adding a New API Function

1. Add `pub async fn` in `rust/src/api/provider.rs`
2. Accept 3 storage callbacks as the last parameters
3. Create provider via `make_provider()`
4. Load group via `load_group()` if operating on existing group
5. Return a result struct (not opaque)
6. Run `make codegen` to generate Dart bindings
7. Add wrapper method to `MlsClient` in `lib/src/mls_client.dart`

Example:

```rust
pub async fn my_new_function(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;
    // ... implementation using group and provider
    Ok(result_bytes)
}
```

Corresponding MlsClient wrapper:

```dart
Future<Uint8List> myNewFunction({
  required List<int> groupIdBytes,
  required List<int> signerBytes,
}) => provider.myNewFunction(
  groupIdBytes: groupIdBytes,
  signerBytes: signerBytes,
  storageRead: storage.read,
  storageWrite: storage.write,
  storageDelete: storage.delete,
);
```

## DartStorageProvider (Sync/Async Bridge)

OpenMLS `StorageProvider` trait methods are **synchronous**. DartFn callbacks return **async** `DartFnFuture`. The bridge uses `futures::executor::block_on()`:

```rust
fn kv_write(&self, label: &[u8], key_bytes: &[u8], value: &[u8]) -> Result<(), Self::Error> {
    let composite_key = build_key::<VERSION>(label, key_bytes);
    futures::executor::block_on((self.write_fn)(composite_key, value.to_vec()));
    Ok(())
}
```

This works because FRB runs Rust functions on separate threads, not the Dart isolate.

### Key Format

Composite keys match OpenMLS `MemoryStorage` format:
```rust
fn build_key<const V: u16>(label: &[u8], key: &[u8]) -> Vec<u8> {
    let mut out = label.to_vec();
    out.extend_from_slice(key);
    out.extend_from_slice(&u16::to_be_bytes(V));
    out
}
```

### Storage Helper Methods

The 52 `StorageProvider` trait methods reduce to 6 helper patterns:

| Helper | Purpose |
|--------|---------|
| `kv_write` | Store key-value pair |
| `kv_read<V>` | Load and deserialize value |
| `kv_delete` | Remove key |
| `kv_append` | Read list, push item, write back |
| `kv_read_list<V>` | Read JSON array |
| `kv_remove_from_list` | Read list, remove matching item, write back |

## Opaque Type Pattern

For types that stay in Rust (not serialized across FFI):

```rust
#[frb(opaque)]
pub struct MlsSignatureKeyPair {
    pub(crate) native: openmls_basic_credential::SignatureKeyPair,
}

impl MlsSignatureKeyPair {
    #[flutter_rust_bridge::frb(sync)]
    pub fn generate(ciphersuite: MlsCiphersuite) -> Result<MlsSignatureKeyPair, String> {
        // ...
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn serialize(&self) -> Vec<u8> {
        // ...
    }
}
```

**Dart usage:**
```dart
final signer = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
final bytes = signer.serialize();
final pubKey = signer.publicKey();
```

## Transparent Struct Pattern

For result/config types that cross FFI as plain data:

```rust
pub struct CreateGroupProviderResult {
    pub group_id: Vec<u8>,
}

pub struct MlsGroupConfig {
    pub ciphersuite: MlsCiphersuite,
    pub wire_format_policy: MlsWireFormatPolicy,
    pub use_ratchet_tree_extension: bool,
    // ...
}
```

FRB generates Dart classes with constructors for these automatically.

## Sync vs Async Functions

### Sync (simple operations, no storage)

```rust
impl MlsSignatureKeyPair {
    #[flutter_rust_bridge::frb(sync)]
    pub fn serialize(&self) -> Vec<u8> { ... }
}
```

### Async (storage operations)

```rust
// No #[frb(sync)] - FRB generates Future<T> in Dart
pub async fn create_group(
    // ... params + storage callbacks
) -> Result<CreateGroupProviderResult, String> { ... }
```

### Sync standalone functions

```rust
// Sync utility functions (no storage needed)
pub fn mls_message_extract_group_id(message_bytes: Vec<u8>) -> Result<Vec<u8>, String> { ... }
pub fn mls_message_content_type(message_bytes: Vec<u8>) -> Result<String, String> { ... }
```

## Error Handling

Convert OpenMLS errors to String for FRB:

```rust
pub async fn some_function(...) -> Result<SomeResult, String> {
    let group = MlsGroup::new(provider, &signer, &config, credential)
        .map_err(|e| format!("Failed to create group: {e}"))?;
    Ok(SomeResult { ... })
}
```

FRB automatically converts `Result<T, String>` to Dart exceptions.

## Vec<u8> for Serialization

All serialized data crosses FFI as `Vec<u8>` / `List<int>` / `Uint8List`:

```rust
// Serialize: Rust type -> Vec<u8>
let bytes = group_id.as_slice().to_vec();

// Deserialize: Vec<u8> -> Rust type
let group_id = GroupId::from_slice(&group_id_bytes);
```

## Memory Management

**FRB handles cleanup automatically via Rust's ownership system.**

- No manual `dispose()` needed in Dart
- No finalizers to register
- No double-free concerns
- Opaque types are dropped when Dart GC collects them

```dart
// Dart - no cleanup needed!
final signer = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
final serialized = signer.serialize();
// signer is automatically cleaned up when no longer referenced
```

## Regenerating Bindings

After modifying Rust code in `rust/src/api/`:

```bash
make codegen
```

This runs `flutter_rust_bridge_codegen generate` using `flutter_rust_bridge.yaml` config.

**When to regenerate:**
- After modifying any `pub fn` or `pub async fn` in `rust/src/api/`
- After changing struct/enum definitions in `rust/src/api/types.rs`
- After updating OpenMLS version (if API changed)

## Files Reference

| Pattern | Reference File |
|---------|----------------|
| Opaque types | `rust/src/api/keys.rs` |
| Provider API functions | `rust/src/api/provider.rs` |
| Storage callbacks | `rust/src/dart_storage.rs` |
| Transparent structs | `rust/src/api/types.rs` |
| Config types | `rust/src/api/config.rs` |
| Credential types | `rust/src/api/credential.rs` |
| MlsClient wrapper | `lib/src/mls_client.dart` |
| MlsStorage interface | `lib/src/mls_client.dart` |

## Common Issues

### "method not found" after codegen

- Check that the method is `pub`
- Check that return types are supported by FRB
- Run `make codegen` after any Rust changes

### Callback lifetime issues

Ensure callbacks have `Send + Sync + 'static`:

```rust
storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
```

### Type not transferable

Use `Vec<u8>` for complex types instead of trying to pass OpenMLS types directly across FFI.

### `block_on` panics

`futures::executor::block_on()` requires a non-async context. This works because FRB runs Rust functions on separate threads. Do NOT call storage callbacks from an async Rust context without `block_on`.

## Web/WASM Considerations

- `block_on()` works on WASM (confirmed by libsignal_dart usage pattern)
- `getrandom` uses Web Crypto API on WASM
- Configuration in `rust/.cargo/config.toml`:
  ```toml
  [target.wasm32-unknown-unknown]
  rustflags = ['--cfg', 'getrandom_backend="wasm_js"']
  ```
