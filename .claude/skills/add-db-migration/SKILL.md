---
name: add-db-migration
description: Add a new database migration to EncryptedDb. Use when changing storage schema, data format, or serialization in the native library.
---

# Add Database Migration

Guide for adding a new migration to `rust/src/encrypted_db.rs`. Migrations run automatically when `EncryptedDb::open()` is called.

## Architecture

Two separate version counters:
- **`LATEST_SCHEMA_VERSION`** — data migrations (both platforms, always in sync)
- **`IDB_STRUCTURAL_VERSION`** — IDB object store changes (WASM only, bump separately)

| Platform | Schema tracking | Migration atomicity |
|----------|----------------|---------------------|
| Native (SQLCipher) | `db_meta.schema_version` row | SQL transaction per migration |
| WASM (IndexedDB) | Encrypted `WASM_META_KEY` in `mls_storage` | IDB transaction per migration |

## Step-by-Step Checklist

### 1. Bump `LATEST_SCHEMA_VERSION`

```rust
// rust/src/encrypted_db.rs
pub(crate) const LATEST_SCHEMA_VERSION: u32 = 2; // was 1
```

### 2. Add native migration function

```rust
/// vN-1 -> vN: <description of what changes>.
fn migrate_native_v{N-1}_to_v{N}(conn: &rusqlite::Connection) -> Result<(), String> {
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("Migration v{N-1}->v{N}: failed to begin transaction: {e}"))?;

    // DDL changes:
    // tx.execute_batch("ALTER TABLE mls_storage ADD COLUMN new_col BLOB;")?;

    // Data transforms:
    // let mut stmt = tx.prepare("SELECT key, value FROM mls_storage WHERE ...")?;
    // ... transform and update rows ...

    // Write new version (INSIDE the transaction = atomic).
    tx.execute(
        &format!("INSERT OR REPLACE INTO db_meta (key, value) VALUES ('{META_SCHEMA_VERSION}', '{N}')"),
        [],
    )
    .map_err(|e| format!("Migration v{N-1}->v{N}: failed to write version: {e}"))?;
    tx.commit()
        .map_err(|e| format!("Migration v{N-1}->v{N}: commit failed: {e}"))?;
    Ok(())
}
```

### 3. Wire native migration into `run_migrations()`

```rust
// In the native run_migrations():
if version < N {
    Self::migrate_native_v{N-1}_to_v{N}(&conn)?;
}
```

### 4. Add WASM migration function

```rust
/// vN-1 -> vN: <description of what changes>.
async fn migrate_wasm_v{N-1}_to_v{N}(&self) -> Result<(), String> {
    // For data transforms, pre-encrypt all values BEFORE opening IDB transaction.
    // IDB auto-commits when the event loop is idle (any .await kills the txn).

    // Example: read all, transform, write back
    // let all = self.idb_get_all().await?;
    // let mut transformed = Vec::new();
    // for (k, enc_v) in all {
    //     let v = wasm_decrypt(&self.key.0, &enc_v).await?;
    //     let new_v = transform(v);
    //     let enc_new_v = wasm_encrypt(&self.key.0, &new_v).await?;
    //     transformed.push((k, enc_new_v));
    // }
    // // Now open IDB transaction and write all at once
    // ...

    // Write new version.
    self.idb_write_schema_version(N).await?;
    Ok(())
}
```

### 5. Wire WASM migration into `run_migrations()`

```rust
// In the WASM run_migrations():
if version < N {
    self.migrate_wasm_v{N-1}_to_v{N}().await?;
}
```

### 6. If adding a new IDB object store

Also bump the structural version:

```rust
const IDB_STRUCTURAL_VERSION: u32 = 2; // was 1
```

And add to `idb_ensure_stores()`:

```rust
if old_version < 2.0 {
    db.create_object_store("new_store_name", params).unwrap();
}
```

### 7. Add tests

In `test/storage_test.dart`:

```dart
test('schema_version returns expected value after migration', () async {
  final engine = await createTestEngine();
  expect(engine.schemaVersion(), N); // matches LATEST_SCHEMA_VERSION
});
```

Existing tests implicitly verify migration idempotency (every `createTestEngine()` runs migrations on a fresh DB).

### 8. Verify

```bash
make build          # Rust compiles
make codegen        # FRB bindings regenerate (if schema_version() signature changed)
make analyze        # Clean analysis
make test           # All tests pass
```

## When to bump which version

| Change | `LATEST_SCHEMA_VERSION` | `IDB_STRUCTURAL_VERSION` |
|--------|:-----------------------:|:------------------------:|
| New SQL column/table | Yes | No |
| Changed data serialization | Yes | No |
| Data restructuring (merge/split) | Yes | No |
| New IDB object store | Yes | Yes |
| Remove IDB object store | Yes | Yes |
| Bug fix (no data change) | No | No |
| New Rust API function | No | No |

## Safety rules

1. **Native**: Each migration gets its own SQL transaction. Version is written **inside** the same transaction. Failure = full rollback, version unchanged.
2. **WASM**: Pre-encrypt all values before opening IDB transaction. Version written atomically with data.
3. **Never skip versions**: Migrations run sequentially `if version < N`. A DB at v1 upgrading to v3 runs v1->v2, then v2->v3.
4. **Test with fresh AND existing DBs**: Fresh DB (version 0 -> latest) is tested by every test. For existing DB upgrades, consider adding a dedicated test that pre-populates data.

## Reference: Wire core-crypto patterns

Wire uses the same approach (refinery for native SQL + custom WASM framework):
- 22 SQL migrations (V1__schema.sql through V22__unhex_id_columns.sql)
- "Meta-migrations" for complex Rust data transforms between SQL steps
- IDB migrations applied one-at-a-time with version stepping
- Builder chaining for IDB structural changes

Our system is simpler (single KV table vs 18+ entity tables) but architecturally equivalent.
