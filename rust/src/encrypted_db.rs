//! EncryptedDb — platform-specific encrypted key-value storage.
//!
//! Native: SQLCipher via rusqlite (AES-256 transparent encryption).
//! WASM: IndexedDB via `idb` crate + AES-256-GCM per-value encryption
//!       (via `crypto.subtle` — non-extractable CryptoKey).
//!
//! Schema:
//! ```sql
//! CREATE TABLE mls_storage (key BLOB PRIMARY KEY, value BLOB NOT NULL, group_id BLOB);
//! CREATE INDEX idx_group_id ON mls_storage(group_id);
//! CREATE TABLE db_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
//! ```

use zeroize::Zeroize;

/// Current database schema version.
///
/// **When to bump:** Increment this when the storage schema or data format changes:
/// - New SQL table/column/index (native DDL change)
/// - Changed serialization format (e.g. OpenMLS upgrades TLS encoding)
/// - Data restructuring (merge/split/rename stored entries)
/// - New IDB object store (also bump `IDB_STRUCTURAL_VERSION`)
///
/// **When NOT to bump:** Bug fixes, new Rust API functions, or Dart-side changes
/// that don't affect the on-disk data format.
///
/// **Adding a migration:** Use the `/add-db-migration` Claude skill for a guided walkthrough,
/// or follow the template in `run_migrations()` comments.
pub(crate) const LATEST_SCHEMA_VERSION: u32 = 1;

/// Key in the native `db_meta` table that stores the schema version.
#[cfg(not(target_arch = "wasm32"))]
const META_SCHEMA_VERSION: &str = "schema_version";

/// Reserved key in the WASM `mls_storage` object store for schema version.
/// Cannot collide with OpenMLS keys (those start with labels like `KeyPackage`, `Tree`, etc.).
#[cfg(target_arch = "wasm32")]
const WASM_META_KEY: &[u8] = b"__openmls_schema_version__";

/// IDB structural version — bump only when adding/removing object stores.
#[cfg(target_arch = "wasm32")]
const IDB_STRUCTURAL_VERSION: u32 = 1;

/// Labels for globally-scoped keys (not tied to a specific group).
const GLOBAL_LABELS: &[&[u8]] = &[
    b"KeyPackage",
    b"Psk",
    b"EncryptionKeyPair",
    b"SignatureKeyPair",
];

/// Check if a storage key belongs to the global scope (not group-specific).
pub fn is_global_key(key: &[u8]) -> bool {
    GLOBAL_LABELS.iter().any(|label| key.starts_with(label))
}

/// Updates to persist after a snapshot operation.
pub struct StorageUpdates {
    pub upserts: Vec<(Vec<u8>, Vec<u8>)>,
    pub deletes: Vec<Vec<u8>>,
}

/// Wrapper around `web_sys::CryptoKey` that is `Send + Sync`.
///
/// WASM is single-threaded, so this is safe. FRB requires opaque types to be
/// `Send + Sync` for its generated code.
#[cfg(target_arch = "wasm32")]
struct WasmCryptoKey(web_sys::CryptoKey);

#[cfg(target_arch = "wasm32")]
unsafe impl Send for WasmCryptoKey {}
#[cfg(target_arch = "wasm32")]
unsafe impl Sync for WasmCryptoKey {}

pub struct EncryptedDb {
    #[cfg(not(target_arch = "wasm32"))]
    conn: std::sync::Mutex<rusqlite::Connection>,
    #[cfg(target_arch = "wasm32")]
    db_name: String,
    #[cfg(target_arch = "wasm32")]
    key: WasmCryptoKey,
}

// ═══════════════════════════════════════════════════════════════
// NATIVE IMPLEMENTATION (SQLCipher)
// ═══════════════════════════════════════════════════════════════

#[cfg(not(target_arch = "wasm32"))]
impl EncryptedDb {
    /// Open or create an encrypted database.
    ///
    /// - `db_path`: File path, or `":memory:"` for in-memory DB.
    /// - `encryption_key`: 32-byte AES-256 key for SQLCipher.
    pub async fn open(db_path: String, mut encryption_key: Vec<u8>) -> Result<Self, String> {
        if encryption_key.len() != 32 {
            encryption_key.zeroize();
            return Err(format!(
                "encryption_key must be 32 bytes, got {}",
                encryption_key.len()
            ));
        }

        let conn = rusqlite::Connection::open(&db_path)
            .map_err(|e| format!("Failed to open database: {e}"))?;

        // Set the encryption key via PRAGMA key (hex-encoded for SQLCipher).
        let hex_key = hex_string(&encryption_key);
        encryption_key.zeroize();
        conn.pragma_update(None, "key", format!("x'{hex_key}'"))
            .map_err(|e| format!("Failed to set encryption key: {e}"))?;

        // Verify key is correct by querying.
        conn.execute_batch("SELECT count(*) FROM sqlite_master;")
            .map_err(|e| format!("Encryption key verification failed (wrong key?): {e}"))?;

        let db = Self {
            conn: std::sync::Mutex::new(conn),
        };
        db.run_migrations()?;
        Ok(db)
    }

    fn run_migrations(&self) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();

        // Ensure the metadata table exists (needed to read version).
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS db_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )
        .map_err(|e| format!("Failed to create db_meta table: {e}"))?;

        let version: u32 = conn
            .query_row(
                &format!(
                    "SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM db_meta WHERE key = '{META_SCHEMA_VERSION}'), 0)"
                ),
                [],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to read schema version: {e}"))?;

        // Downgrade detection.
        if version > LATEST_SCHEMA_VERSION {
            return Err(format!(
                "Database schema version {version} is newer than supported {LATEST_SCHEMA_VERSION}. Update the app."
            ));
        }

        // Already at latest — nothing to do.
        if version >= LATEST_SCHEMA_VERSION {
            return Ok(());
        }

        if version < 1 {
            Self::migrate_native_v0_to_v1(&conn)?;
        }

        // Future migrations:
        // if version < 2 { Self::migrate_native_v1_to_v2(&conn)?; }

        Ok(())
    }

    /// v0 → v1: Create the `mls_storage` table and `group_id` index.
    fn migrate_native_v0_to_v1(conn: &rusqlite::Connection) -> Result<(), String> {
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| format!("Migration v0→v1: failed to begin transaction: {e}"))?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS mls_storage (
                key BLOB PRIMARY KEY,
                value BLOB NOT NULL,
                group_id BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_group_id ON mls_storage(group_id);",
        )
        .map_err(|e| format!("Migration v0→v1 failed: {e}"))?;
        tx.execute(
            &format!("INSERT OR REPLACE INTO db_meta (key, value) VALUES ('{META_SCHEMA_VERSION}', '1')"),
            [],
        )
        .map_err(|e| format!("Migration v0→v1: failed to write version: {e}"))?;
        tx.commit()
            .map_err(|e| format!("Migration v0→v1: commit failed: {e}"))?;
        Ok(())
    }

    /// Load all entries with `group_id IS NULL` (global entries).
    pub async fn load_global(&self) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT key, value FROM mls_storage WHERE group_id IS NULL")
            .map_err(|e| format!("Failed to prepare load_global: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
            })
            .map_err(|e| format!("Failed to query load_global: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Row error: {e}"))?);
        }
        Ok(result)
    }

    /// Load all entries for a group (group-specific + global).
    pub async fn load_for_group(&self, group_id: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT key, value FROM mls_storage WHERE group_id = ?1 OR group_id IS NULL",
            )
            .map_err(|e| format!("Failed to prepare load_for_group: {e}"))?;
        let rows = stmt
            .query_map(rusqlite::params![group_id], |row| {
                Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
            })
            .map_err(|e| format!("Failed to query load_for_group: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Row error: {e}"))?);
        }
        Ok(result)
    }

    /// Save updates (upserts + deletes) in a transaction.
    pub async fn save_updates(
        &self,
        updates: StorageUpdates,
        group_id: Option<&[u8]>,
    ) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| format!("Failed to begin transaction: {e}"))?;

        for (key, value) in &updates.upserts {
            let gid: Option<&[u8]> = if is_global_key(key) {
                None
            } else {
                group_id
            };
            tx.execute(
                "INSERT OR REPLACE INTO mls_storage (key, value, group_id) VALUES (?1, ?2, ?3)",
                rusqlite::params![key, value, gid],
            )
            .map_err(|e| format!("Failed to upsert: {e}"))?;
        }

        for key in &updates.deletes {
            tx.execute(
                "DELETE FROM mls_storage WHERE key = ?1",
                rusqlite::params![key],
            )
            .map_err(|e| format!("Failed to delete: {e}"))?;
        }

        tx.commit()
            .map_err(|e| format!("Failed to commit transaction: {e}"))?;
        Ok(())
    }

    /// Delete all entries for a specific group.
    pub async fn delete_group(&self, group_id: &[u8]) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM mls_storage WHERE group_id = ?1",
            rusqlite::params![group_id],
        )
        .map_err(|e| format!("Failed to delete group: {e}"))?;
        Ok(())
    }

    /// Close the database connection explicitly.
    pub async fn close(self) -> Result<(), String> {
        // Dropping self closes the connection.
        Ok(())
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ═══════════════════════════════════════════════════════════════
// WASM IMPLEMENTATION (IndexedDB + Web Crypto AES-256-GCM)
// ═══════════════════════════════════════════════════════════════

#[cfg(target_arch = "wasm32")]
impl EncryptedDb {
    /// Open or create an encrypted database.
    ///
    /// - `db_path`: Used as the IndexedDB database name. If `":memory:"`, a unique
    ///   random name is generated to match SQLite's per-connection ephemeral behavior.
    /// - `encryption_key`: 32-byte AES-256-GCM key. Imported as a non-extractable
    ///   `CryptoKey` via `crypto.subtle`, then zeroized from WASM memory.
    pub async fn open(db_path: String, mut encryption_key: Vec<u8>) -> Result<Self, String> {
        if encryption_key.len() != 32 {
            encryption_key.zeroize();
            return Err(format!(
                "encryption_key must be 32 bytes, got {}",
                encryption_key.len()
            ));
        }

        // Import raw bytes as a non-extractable CryptoKey, then zeroize raw bytes.
        let crypto_key = match wasm_import_key(&encryption_key).await {
            Ok(k) => {
                encryption_key.zeroize();
                k
            }
            Err(e) => {
                encryption_key.zeroize();
                return Err(e);
            }
        };

        // Validate key works by encrypting/decrypting a test value.
        let test_ct = wasm_encrypt(&crypto_key, b"key_validation_test").await?;
        let test_pt = wasm_decrypt(&crypto_key, &test_ct).await?;
        if test_pt != b"key_validation_test" {
            return Err("Key validation failed".into());
        }

        // On WASM, `:memory:` has no special meaning in IndexedDB (it's just a name).
        // Generate a unique random name so each engine gets its own isolated database,
        // matching SQLite's behavior where each `:memory:` connection is independent.
        let actual_name = if db_path == ":memory:" {
            let r1 = (js_sys::Math::random() * 4_294_967_296.0) as u64;
            let r2 = (js_sys::Math::random() * 4_294_967_296.0) as u64;
            format!("openmls_memory_{r1:08x}{r2:08x}")
        } else {
            db_path
        };

        let db = Self {
            db_name: actual_name,
            key: WasmCryptoKey(crypto_key),
        };
        db.run_migrations().await?;
        Ok(db)
    }

    async fn run_migrations(&self) -> Result<(), String> {
        // Phase A: Structural changes (create/delete object stores).
        self.idb_ensure_stores().await?;

        // Phase B: Data migrations (versioned via reserved WASM_META_KEY).
        let version = self.idb_read_schema_version().await?;

        // Downgrade detection.
        if version > LATEST_SCHEMA_VERSION {
            return Err(format!(
                "Database schema version {version} is newer than supported {LATEST_SCHEMA_VERSION}. Update the app."
            ));
        }

        // Already at latest — nothing to do.
        if version >= LATEST_SCHEMA_VERSION {
            return Ok(());
        }

        // v0 → v1: Initial schema. No data transform needed, just write the version.
        if version < 1 {
            self.idb_write_schema_version(1).await?;
        }

        // Future migrations:
        // if version < 2 { self.migrate_wasm_v1_to_v2().await?; }

        Ok(())
    }

    /// Phase A: Ensure all required IDB object stores exist.
    async fn idb_ensure_stores(&self) -> Result<(), String> {
        use idb::{DatabaseEvent, Factory, ObjectStoreParams};

        let factory = Factory::new().map_err(|e| format!("Factory::new failed: {e}"))?;
        let mut open_req = factory
            .open(&self.db_name, Some(IDB_STRUCTURAL_VERSION))
            .map_err(|e| format!("Factory::open failed: {e}"))?;

        open_req.on_upgrade_needed(|event| {
            let db = event.database().unwrap();
            let old_version = event.old_version();

            if old_version < 1.0 {
                if !db.store_names().contains(&"mls_storage".to_string()) {
                    let params = ObjectStoreParams::new();
                    db.create_object_store("mls_storage", params).unwrap();
                }
            }

            // Future structural changes:
            // if old_version < 2.0 { db.create_object_store("new_store", ...); }
        });

        let db = open_req
            .await
            .map_err(|e| format!("open_request.await failed: {e}"))?;
        db.close();
        Ok(())
    }

    /// Read the schema version from the reserved WASM_META_KEY in mls_storage.
    /// Returns 0 if the key does not exist (fresh database).
    async fn idb_read_schema_version(&self) -> Result<u32, String> {
        use idb::TransactionMode;
        use js_sys::Uint8Array;

        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadOnly)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        let js_key = Uint8Array::from(WASM_META_KEY);
        let js_val = store
            .get(js_key.into())
            .map_err(|e| format!("get schema_version failed: {e}"))?
            .await
            .map_err(|e| format!("get schema_version.await failed: {e}"))?;

        db.close();

        match js_val {
            None => Ok(0),
            Some(val) => {
                let enc_bytes = Uint8Array::new(&val).to_vec();
                let plain = wasm_decrypt(&self.key.0, &enc_bytes).await?;
                if plain.len() != 4 {
                    return Err(format!(
                        "Corrupt schema version: expected 4 bytes, got {}",
                        plain.len()
                    ));
                }
                Ok(u32::from_be_bytes([plain[0], plain[1], plain[2], plain[3]]))
            }
        }
    }

    /// Write the schema version to the reserved WASM_META_KEY in mls_storage.
    async fn idb_write_schema_version(&self, version: u32) -> Result<(), String> {
        use idb::TransactionMode;
        use js_sys::Uint8Array;

        // Pre-encrypt before opening transaction (IDB auto-commits on idle).
        let enc_version = wasm_encrypt(&self.key.0, &version.to_be_bytes()).await?;

        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadWrite)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        let js_key = Uint8Array::from(WASM_META_KEY);
        let js_val = Uint8Array::from(enc_version.as_slice());
        store
            .put(&js_val, Some(&js_key.into()))
            .map_err(|e| format!("put schema_version failed: {e}"))?
            .await
            .map_err(|e| format!("put schema_version.await failed: {e}"))?;

        txn.commit()
            .map_err(|e| format!("commit schema_version failed: {e}"))?
            .await
            .map_err(|e| format!("commit schema_version.await failed: {e}"))?;

        db.close();
        Ok(())
    }

    /// Load all global entries (key starts with a global label prefix).
    pub async fn load_global(&self) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        let all = self.idb_get_all().await?;
        let mut result = Vec::new();
        for (k, enc_v) in all {
            if is_global_key(&k) {
                let v = wasm_decrypt(&self.key.0, &enc_v).await?;
                result.push((k, v));
            }
        }
        Ok(result)
    }

    /// Load all entries for a group (group-specific + global).
    ///
    /// On WASM we store `group_id` as a metadata prefix in the IDB key, but for simplicity
    /// we load all entries and filter. The mls_storage key format already embeds the group_id
    /// for group-scoped entries, and global entries have global label prefixes.
    ///
    /// Since OpenMLS storage keys are opaque, we must load everything and filter by prefix.
    /// For WASM with typical MLS group sizes this is efficient enough.
    pub async fn load_for_group(&self, _group_id: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        let all = self.idb_get_all().await?;
        let mut result = Vec::new();
        for (k, enc_v) in all {
            // On WASM we load everything — the SnapshotStorageProvider only
            // accesses keys relevant to its operations.
            let v = wasm_decrypt(&self.key.0, &enc_v).await?;
            result.push((k, v));
        }
        Ok(result)
    }

    /// Save updates (upserts + deletes).
    pub async fn save_updates(
        &self,
        updates: StorageUpdates,
        _group_id: Option<&[u8]>,
    ) -> Result<(), String> {
        use idb::TransactionMode;
        use js_sys::Uint8Array;
        use wasm_bindgen::JsValue;

        // Pre-encrypt all values before opening the transaction.
        // IDB transactions auto-commit when the event loop is idle, so we must
        // avoid any await (like crypto.subtle) between transaction open and commit.
        let mut encrypted_upserts = Vec::with_capacity(updates.upserts.len());
        for (key, value) in &updates.upserts {
            let enc_value = wasm_encrypt(&self.key.0, value).await?;
            encrypted_upserts.push((key, enc_value));
        }

        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadWrite)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        for (key, enc_value) in &encrypted_upserts {
            let js_key = Uint8Array::from(key.as_slice());
            let js_val = Uint8Array::from(enc_value.as_slice());
            store
                .put(&js_val, Some(&js_key.into()))
                .map_err(|e| format!("put failed: {e}"))?
                .await
                .map_err(|e| format!("put.await failed: {e}"))?;
        }

        for key in &updates.deletes {
            let js_key: JsValue = Uint8Array::from(key.as_slice()).into();
            store
                .delete(js_key)
                .map_err(|e| format!("delete failed: {e}"))?
                .await
                .map_err(|e| format!("delete.await failed: {e}"))?;
        }

        txn.commit()
            .map_err(|e| format!("commit failed: {e}"))?
            .await
            .map_err(|e| format!("commit.await failed: {e}"))?;
        db.close();
        Ok(())
    }

    /// Delete all entries for a specific group.
    /// On WASM, deletes all non-global entries (since we can't filter by group_id column).
    pub async fn delete_group(&self, _group_id: &[u8]) -> Result<(), String> {
        let all_keys = self.idb_get_all_keys().await?;
        let non_global: Vec<_> = all_keys.into_iter().filter(|k| !is_global_key(k)).collect();
        if non_global.is_empty() {
            return Ok(());
        }

        use idb::TransactionMode;
        use js_sys::Uint8Array;
        use wasm_bindgen::JsValue;

        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadWrite)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        for key in &non_global {
            let js_key: JsValue = Uint8Array::from(key.as_slice()).into();
            store
                .delete(js_key)
                .map_err(|e| format!("delete failed: {e}"))?
                .await
                .map_err(|e| format!("delete.await failed: {e}"))?;
        }

        txn.commit()
            .map_err(|e| format!("commit failed: {e}"))?
            .await
            .map_err(|e| format!("commit.await failed: {e}"))?;
        db.close();
        Ok(())
    }

    /// Close the database. On WASM, this is a no-op (IDB connections are per-operation).
    pub async fn close(self) -> Result<(), String> {
        Ok(())
    }

    // -- IDB helpers --

    async fn idb_open(&self) -> Result<idb::Database, String> {
        use idb::{DatabaseEvent, Factory, ObjectStoreParams};

        let factory = Factory::new().map_err(|e| format!("Factory::new failed: {e}"))?;
        let mut open_req = factory
            .open(&self.db_name, Some(IDB_STRUCTURAL_VERSION))
            .map_err(|e| format!("Factory::open failed: {e}"))?;

        open_req.on_upgrade_needed(|event| {
            let db = event.database().unwrap();
            if !db.store_names().contains(&"mls_storage".to_string()) {
                let params = ObjectStoreParams::new();
                db.create_object_store("mls_storage", params).unwrap();
            }
        });

        open_req
            .await
            .map_err(|e| format!("open_request.await failed: {e}"))
    }

    async fn idb_get_all(&self) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        use idb::TransactionMode;
        use js_sys::Uint8Array;

        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadOnly)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        let keys = store
            .get_all_keys(None, None)
            .map_err(|e| format!("get_all_keys failed: {e}"))?
            .await
            .map_err(|e| format!("get_all_keys.await failed: {e}"))?;

        let mut result = Vec::with_capacity(keys.len());
        for js_key in &keys {
            let key_array = Uint8Array::new(js_key);
            let key = key_array.to_vec();
            // Skip the reserved metadata key — not MLS data.
            if key == WASM_META_KEY {
                continue;
            }
            let js_val = store
                .get(js_key.clone())
                .map_err(|e| format!("get failed: {e}"))?
                .await
                .map_err(|e| format!("get.await failed: {e}"))?;
            if let Some(val) = js_val {
                let val_array = Uint8Array::new(&val);
                result.push((key, val_array.to_vec()));
            }
        }

        db.close();
        Ok(result)
    }

    async fn idb_get_all_keys(&self) -> Result<Vec<Vec<u8>>, String> {
        use idb::TransactionMode;
        use js_sys::Uint8Array;

        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadOnly)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        let keys = store
            .get_all_keys(None, None)
            .map_err(|e| format!("get_all_keys failed: {e}"))?
            .await
            .map_err(|e| format!("get_all_keys.await failed: {e}"))?;

        let result = keys
            .iter()
            .map(|js_key| Uint8Array::new(js_key).to_vec())
            .filter(|key| key.as_slice() != WASM_META_KEY)
            .collect();
        db.close();
        Ok(result)
    }
}

// -- WASM encryption helpers (Web Crypto API) --

/// Import raw key bytes as a non-extractable AES-GCM CryptoKey.
#[cfg(target_arch = "wasm32")]
async fn wasm_import_key(raw: &[u8]) -> Result<web_sys::CryptoKey, String> {
    use js_sys::{Array, Object, Reflect, Uint8Array};
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let subtle = web_sys::window()
        .ok_or("crypto.subtle requires a secure context (HTTPS or localhost)")?
        .crypto()
        .map_err(|_| "crypto.subtle requires a secure context (HTTPS or localhost)")?
        .subtle();

    // Algorithm: { name: "AES-GCM" }
    let algorithm = Object::new();
    Reflect::set(&algorithm, &"name".into(), &"AES-GCM".into())
        .map_err(|e| format!("Reflect::set failed: {e:?}"))?;

    // Key usages: ["encrypt", "decrypt"]
    let usages = Array::new();
    usages.push(&"encrypt".into());
    usages.push(&"decrypt".into());

    let key_data = Uint8Array::from(raw);
    let promise = subtle
        .import_key_with_object("raw", &key_data.into(), &algorithm, false, &usages)
        .map_err(|e| format!("importKey failed: {e:?}"))?;
    let result = JsFuture::from(promise)
        .await
        .map_err(|e| format!("importKey promise rejected: {e:?}"))?;

    result
        .dyn_into::<web_sys::CryptoKey>()
        .map_err(|e| format!("importKey result is not CryptoKey: {e:?}"))
}

/// Encrypt plaintext with AES-256-GCM via `crypto.subtle`.
/// Output format: `[12-byte IV || ciphertext + 16-byte tag]`.
#[cfg(target_arch = "wasm32")]
async fn wasm_encrypt(key: &web_sys::CryptoKey, plaintext: &[u8]) -> Result<Vec<u8>, String> {
    use js_sys::Uint8Array;
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    // Generate 12-byte random IV.
    let mut iv = [0u8; 12];
    getrandom::fill(&mut iv).map_err(|e| format!("getrandom failed: {e}"))?;

    let params = web_sys::AesGcmParams::new("AES-GCM", &Uint8Array::from(&iv[..]));
    let subtle = web_sys::window()
        .ok_or("window unavailable")?
        .crypto()
        .map_err(|_| "crypto unavailable".to_string())?
        .subtle();

    let data = Uint8Array::from(plaintext);
    let promise = subtle
        .encrypt_with_object_and_buffer_source(&params, key, &data)
        .map_err(|e| format!("encrypt failed: {e:?}"))?;
    let result = JsFuture::from(promise)
        .await
        .map_err(|e| format!("encrypt promise rejected: {e:?}"))?;

    let ct_array = Uint8Array::new(&result.unchecked_into::<js_sys::ArrayBuffer>());
    let mut out = Vec::with_capacity(12 + ct_array.length() as usize);
    out.extend_from_slice(&iv);
    out.extend_from_slice(&ct_array.to_vec());
    Ok(out)
}

/// Decrypt ciphertext with AES-256-GCM via `crypto.subtle`.
/// Input format: `[12-byte IV || ciphertext + 16-byte tag]`.
#[cfg(target_arch = "wasm32")]
async fn wasm_decrypt(key: &web_sys::CryptoKey, data: &[u8]) -> Result<Vec<u8>, String> {
    use js_sys::Uint8Array;
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    if data.len() < 12 {
        return Err("ciphertext too short".into());
    }
    let (iv_bytes, ciphertext) = data.split_at(12);

    let params = web_sys::AesGcmParams::new("AES-GCM", &Uint8Array::from(iv_bytes));
    let subtle = web_sys::window()
        .ok_or("window unavailable")?
        .crypto()
        .map_err(|_| "crypto unavailable".to_string())?
        .subtle();

    let ct = Uint8Array::from(ciphertext);
    let promise = subtle
        .decrypt_with_object_and_buffer_source(&params, key, &ct)
        .map_err(|e| format!("decrypt failed: {e:?}"))?;
    let result = JsFuture::from(promise)
        .await
        .map_err(|e| format!("decrypt failed: {e:?}"))?;

    let pt_array = Uint8Array::new(&result.unchecked_into::<js_sys::ArrayBuffer>());
    Ok(pt_array.to_vec())
}
