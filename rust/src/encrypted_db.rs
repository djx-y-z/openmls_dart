//! EncryptedDb — platform-specific encrypted key-value storage.
//!
//! Native: SQLCipher via rusqlite (AES-256 transparent encryption).
//! WASM: IndexedDB via `idb` crate + AES-256-GCM per-value encryption.
//!
//! Schema:
//! ```sql
//! CREATE TABLE mls_storage (key BLOB PRIMARY KEY, value BLOB NOT NULL, group_id BLOB);
//! CREATE INDEX idx_group_id ON mls_storage(group_id);
//! CREATE TABLE db_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
//! ```

use zeroize::Zeroize;

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

pub struct EncryptedDb {
    #[cfg(not(target_arch = "wasm32"))]
    conn: std::sync::Mutex<rusqlite::Connection>,
    #[cfg(target_arch = "wasm32")]
    db_name: String,
    #[cfg(target_arch = "wasm32")]
    key: zeroize::Zeroizing<Vec<u8>>,
}

impl Drop for EncryptedDb {
    fn drop(&mut self) {
        // Native: SQLCipher connection drops automatically.
        // WASM: key is Zeroizing<Vec<u8>> and auto-zeroizes on drop.
    }
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

        // Check current version.
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS db_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )
        .map_err(|e| format!("Failed to create db_meta table: {e}"))?;

        let version: i64 = conn
            .query_row(
                "SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM db_meta WHERE key = 'schema_version'), 0)",
                [],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to read schema version: {e}"))?;

        if version < 1 {
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS mls_storage (
                    key BLOB PRIMARY KEY,
                    value BLOB NOT NULL,
                    group_id BLOB
                );
                CREATE INDEX IF NOT EXISTS idx_group_id ON mls_storage(group_id);
                INSERT OR REPLACE INTO db_meta (key, value) VALUES ('schema_version', '1');",
            )
            .map_err(|e| format!("Migration v1 failed: {e}"))?;
        }

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
// WASM IMPLEMENTATION (IndexedDB + AES-256-GCM)
// ═══════════════════════════════════════════════════════════════

#[cfg(target_arch = "wasm32")]
impl EncryptedDb {
    /// Open or create an encrypted database.
    ///
    /// - `db_path`: Used as the IndexedDB database name. If `":memory:"`, a unique
    ///   random name is generated to match SQLite's per-connection ephemeral behavior.
    /// - `encryption_key`: 32-byte AES-256-GCM key.
    pub async fn open(db_path: String, mut encryption_key: Vec<u8>) -> Result<Self, String> {
        if encryption_key.len() != 32 {
            encryption_key.zeroize();
            return Err(format!(
                "encryption_key must be 32 bytes, got {}",
                encryption_key.len()
            ));
        }

        // Validate key works by encrypting/decrypting a test value.
        let key_arr: [u8; 32] = encryption_key.clone().try_into().unwrap();
        let test_ct = wasm_encrypt(&key_arr, b"key_validation_test")?;
        let test_pt = wasm_decrypt(&key_arr, &test_ct)?;
        if test_pt != b"key_validation_test" {
            encryption_key.zeroize();
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
            key: zeroize::Zeroizing::new(encryption_key),
        };
        db.run_migrations().await?;
        Ok(db)
    }

    async fn run_migrations(&self) -> Result<(), String> {
        // IndexedDB is schemaless — "migrations" just ensure the object store exists.
        // We use version=1 and create "mls_storage" store on upgrade.
        self.idb_ensure_store().await
    }

    async fn idb_ensure_store(&self) -> Result<(), String> {
        use idb::{DatabaseEvent, Factory, ObjectStoreParams};

        let factory = Factory::new().map_err(|e| format!("Factory::new failed: {e}"))?;
        let mut open_req = factory
            .open(&self.db_name, Some(1))
            .map_err(|e| format!("Factory::open failed: {e}"))?;

        open_req.on_upgrade_needed(|event| {
            let db = event.database().unwrap();
            if !db.store_names().contains(&"mls_storage".to_string()) {
                let params = ObjectStoreParams::new();
                db.create_object_store("mls_storage", params).unwrap();
            }
        });

        let db = open_req
            .await
            .map_err(|e| format!("open_request.await failed: {e}"))?;
        db.close();
        Ok(())
    }

    fn key_arr(&self) -> [u8; 32] {
        self.key.as_slice().try_into().unwrap()
    }

    /// Load all global entries (key starts with a global label prefix).
    pub async fn load_global(&self) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        let key_arr = self.key_arr();
        let all = self.idb_get_all().await?;
        let mut result = Vec::new();
        for (k, enc_v) in all {
            if is_global_key(&k) {
                let v = wasm_decrypt(&key_arr, &enc_v)?;
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
        let key_arr = self.key_arr();
        let all = self.idb_get_all().await?;
        let mut result = Vec::new();
        for (k, enc_v) in all {
            // On WASM we load everything — the SnapshotStorageProvider only
            // accesses keys relevant to its operations.
            let v = wasm_decrypt(&key_arr, &enc_v)?;
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

        let key_arr = self.key_arr();
        let db = self.idb_open().await?;
        let txn = db
            .transaction(&["mls_storage"], TransactionMode::ReadWrite)
            .map_err(|e| format!("transaction failed: {e}"))?;
        let store = txn
            .object_store("mls_storage")
            .map_err(|e| format!("object_store failed: {e}"))?;

        for (key, value) in &updates.upserts {
            let enc_value = wasm_encrypt(&key_arr, value)?;
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
            .open(&self.db_name, Some(1))
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
        use wasm_bindgen::JsCast;

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
            .collect();
        db.close();
        Ok(result)
    }
}

// -- WASM encryption helpers --

#[cfg(target_arch = "wasm32")]
fn wasm_encrypt(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    use aes_gcm::{Aes256Gcm, KeyInit, aead::Aead, AeadCore, aead::OsRng};

    let cipher = Aes256Gcm::new(key.into());
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let ciphertext = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|e| format!("encrypt failed: {e}"))?;

    let mut out = Vec::with_capacity(12 + ciphertext.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

#[cfg(target_arch = "wasm32")]
fn wasm_decrypt(key: &[u8; 32], data: &[u8]) -> Result<Vec<u8>, String> {
    use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::Aead};

    if data.len() < 12 {
        return Err("ciphertext too short".into());
    }
    let (nonce_bytes, ciphertext) = data.split_at(12);
    let cipher = Aes256Gcm::new(key.into());
    let nonce = Nonce::from_slice(nonce_bytes);
    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| format!("decrypt failed: {e}"))
}
