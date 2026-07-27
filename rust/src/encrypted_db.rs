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

// WASM's `WasmCryptoKey` newtype carries `unsafe impl Send + Sync` (sound
// because WASM is single-threaded); it needs unsafe under `unsafe_code = "deny"`.
#![allow(unsafe_code)]

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

impl StorageUpdates {
    /// Wipe the plaintext values.
    ///
    /// The values are clones of snapshot entries — MLS secrets. The snapshot
    /// wipes its own two copies when it is dropped; these clones need the same
    /// treatment. Keys stay: they are labels plus serialized group ids, epochs
    /// and leaf indices, not secrets.
    fn zeroize_values(&mut self) {
        for (_key, value) in &mut self.upserts {
            value.zeroize();
        }
    }
}

impl Drop for StorageUpdates {
    /// Wipes our copy of the values once they have been written.
    ///
    /// The copies the database layer makes are not ours to wipe: on native
    /// they live in SQLite's statement memory and page cache, which
    /// `cipher_memory_security` (set in `open`) zeroes on free; on WASM they
    /// pass through `crypto.subtle` buffers owned by the browser.
    fn drop(&mut self) {
        self.zeroize_values();
    }
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
    /// Sidecar single-writer lock — see `acquire_single_writer_lock`. `None` for
    /// databases that have no file to sit beside (`":memory:"`).
    ///
    /// Declared *after* `conn` on purpose: fields drop in declaration order, so
    /// the connection is closed before the lock is released. The reverse order
    /// would leave a window in which another process holds the lock while this
    /// one is still writing.
    #[cfg(all(unix, not(target_arch = "wasm32")))]
    _single_writer_lock: Option<std::fs::File>,
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

        // A `"file:…"` URI names its database through query parameters, so the
        // path it resolves to cannot be recovered without parsing them. Such a
        // database would silently get neither owner-only permissions nor the
        // single-writer lock file — two security properties quietly missing on
        // a database that otherwise looks like it has them. Refuse it instead.
        if db_path.starts_with("file:") {
            encryption_key.zeroize();
            return Err("db_path must be a plain file path or \":memory:\", not a \
                        \"file:…\" URI: a URI-named database would get neither \
                        owner-only permissions nor the single-writer lock file."
                .to_string());
        }

        // Create the file owner-only *before* SQLite touches it, so it never
        // exists with the default world-readable mode.
        restrict_permissions(&db_path);

        let conn = rusqlite::Connection::open(&db_path)
            .map_err(|e| format!("Failed to open database: {e}"))?;

        // Before the key, because this governs how SQLCipher allocates every
        // buffer that follows: with it on, SQLCipher wipes its own working
        // memory when freeing it and asks the OS to keep it out of swap. That
        // memory holds MLS plaintext while it is being encrypted, which is
        // exactly the residue `StorageUpdates`' own wipe cannot reach.
        conn.execute_batch("PRAGMA cipher_memory_security = ON;")
            .map_err(|e| format!("Failed to enable cipher_memory_security: {e}"))?;

        // The key has to be set before anything reads or writes the file.
        let pragma_key = raw_key_pragma(&encryption_key);
        encryption_key.zeroize();
        let keyed = conn.pragma_update(None, "key", pragma_key.as_str());
        drop(pragma_key);
        keyed.map_err(|e| format!("Failed to set encryption key: {e}"))?;

        // First access to the file: proves the key decrypts it — and is where
        // an exclusive lock held by another connection first shows up.
        conn.execute_batch("SELECT count(*) FROM sqlite_master;")
            .map_err(|e| match busy_error(&e) {
                Some(message) => message,
                None => format!("Encryption key verification failed (wrong key?): {e}"),
            })?;

        Self::apply_pragmas(&conn)?;

        // After the pragmas, so an opener that SQLite itself refuses reports
        // that without first waiting on the sidecar.
        #[cfg(unix)]
        let single_writer_lock = acquire_single_writer_lock(&db_path)?;

        let db = Self {
            conn: std::sync::Mutex::new(conn),
            #[cfg(unix)]
            _single_writer_lock: single_writer_lock,
        };
        db.run_migrations()?;
        Ok(db)
    }

    /// Durability and single-writer settings, applied to every connection.
    fn apply_pragmas(conn: &rusqlite::Connection) -> Result<(), String> {
        // Confirm the memory-security pragma set in `open()` took effect. It
        // can only be read back once SQLCipher's allocator has run, hence the
        // check here rather than next to the statement that sets it. Failing
        // to lock memory is not covered by this: SQLCipher only logs that and
        // carries on, so a small RLIMIT_MEMLOCK degrades to wiping without
        // swap protection instead of failing to open.
        let memory_security: String = conn
            .query_row("PRAGMA cipher_memory_security;", [], |row| row.get(0))
            .map_err(|e| format!("Failed to read cipher_memory_security: {e}"))?;
        if memory_security != "1" {
            return Err(format!(
                "cipher_memory_security is {memory_security:?}, expected \"1\""
            ));
        }

        // Rollback journal, never WAL. `journal_mode` is persisted *in the
        // database file*, so a file that was ever opened in WAL mode keeps it,
        // and WAL leaves committed data in a side file that a crash or a
        // careless file-level backup can drop. In-memory databases report
        // `memory` and cannot be changed — they have no journal file at all,
        // which is equally safe.
        let journal_mode = read_back(conn, "journal_mode", "DELETE")?;
        if !journal_mode.eq_ignore_ascii_case("delete")
            && !journal_mode.eq_ignore_ascii_case("memory")
        {
            return Err(format!(
                "Failed to leave WAL mode: journal_mode is {journal_mode:?}, expected \"delete\""
            ));
        }

        // fsync on every commit, so a crash cannot lose an operation that was
        // reported as done. Deliberately *not* `fullfsync`: on Apple platforms
        // that additionally flushes the drive's own write cache, which measured
        // at 16 ms per operation here versus 318 µs without it — 51× on the
        // path every message send and receive takes. What it would buy is
        // narrow: `synchronous = FULL` already fsyncs, so the residual exposure
        // is data still in a volatile drive cache when power is cut, and losing
        // the last operation is recoverable (the MLS reuse guard makes a lost
        // ratchet step a rejected message, not a repeated keystream).
        let _ = conn.execute_batch("PRAGMA synchronous = FULL;");

        // Single writer, part one. A second connection to the same file —
        // another engine instance, isolate or process — runs its own
        // load → operate → save cycle and would silently overwrite this one's
        // group state. Exclusive locking mode keeps SQLite's locks held between
        // transactions, and the write transaction below takes them immediately
        // so a second opener fails here instead of corrupting state later.
        //
        // This alone does not hold across processes for as long as the engine
        // lives: SQLite's locks are POSIX advisory locks, which any unrelated
        // file access in this process silently drops. Part two —
        // `acquire_single_writer_lock`, called from `open` — is what closes
        // that; see its comment for the mechanism.
        let locking_mode = read_back(conn, "locking_mode", "EXCLUSIVE")?;
        if !locking_mode.eq_ignore_ascii_case("exclusive") {
            return Err(format!(
                "Failed to enter exclusive locking mode: locking_mode is {locking_mode:?}"
            ));
        }
        conn.execute_batch("BEGIN EXCLUSIVE; COMMIT;")
            .map_err(|e| match busy_error(&e) {
                Some(message) => message,
                None => format!("Failed to lock the database for exclusive use: {e}"),
            })?;

        Ok(())
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
        Self::apply_updates(&tx, &updates, group_id)?;
        tx.commit()
            .map_err(|e| format!("Failed to commit transaction: {e}"))?;
        Ok(())
    }

    /// Save updates *and* drop every remaining row of `group_id`, in one
    /// transaction — a crash cannot leave a deleted group half-purged.
    pub async fn save_updates_and_purge_group(
        &self,
        updates: StorageUpdates,
        group_id: &[u8],
    ) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| format!("Failed to begin transaction: {e}"))?;
        Self::apply_updates(&tx, &updates, Some(group_id))?;
        tx.execute(
            "DELETE FROM mls_storage WHERE group_id = ?1",
            rusqlite::params![group_id],
        )
        .map_err(|e| format!("Failed to purge group: {e}"))?;
        tx.commit()
            .map_err(|e| format!("Failed to commit transaction: {e}"))?;
        Ok(())
    }

    fn apply_updates(
        tx: &rusqlite::Transaction<'_>,
        updates: &StorageUpdates,
        group_id: Option<&[u8]>,
    ) -> Result<(), String> {
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

        Ok(())
    }

    /// Close the database connection explicitly.
    pub async fn close(self) -> Result<(), String> {
        // Dropping self closes the connection.
        Ok(())
    }
}

/// Build the SQLCipher `PRAGMA key` value for a raw 32-byte key.
///
/// SQLCipher treats a passphrase of exactly `x'<64 hex digits>'` as the raw
/// key and uses those bytes directly; anything else is a passphrase run
/// through 256k PBKDF2-HMAC-SHA512 iterations. rusqlite passes this string as
/// a SQL string literal, which SQLite unescapes back to these exact characters
/// before SQLCipher inspects them.
///
/// The result is a plaintext copy of the key, hence `Zeroizing`. SQLite makes
/// its own copy in the pragma's statement text; `cipher_memory_security` (set
/// before the key in `open`) is what wipes that one when SQLite frees it.
#[cfg(not(target_arch = "wasm32"))]
fn raw_key_pragma(key: &[u8]) -> zeroize::Zeroizing<String> {
    const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut pragma = zeroize::Zeroizing::new(String::with_capacity(key.len() * 2 + 3));
    pragma.push_str("x'");
    for byte in key {
        pragma.push(HEX_DIGITS[(byte >> 4) as usize] as char);
        pragma.push(HEX_DIGITS[(byte & 0x0f) as usize] as char);
    }
    pragma.push('\'');
    pragma
}

/// Apply a pragma and read the value the connection actually ended up with.
#[cfg(not(target_arch = "wasm32"))]
fn read_back(conn: &rusqlite::Connection, name: &str, value: &str) -> Result<String, String> {
    // `name` and `value` are crate-internal literals — never caller input.
    conn.execute_batch(&format!("PRAGMA {name} = {value};"))
        .map_err(|e| match busy_error(&e) {
            Some(message) => message,
            None => format!("Failed to set {name}: {e}"),
        })?;
    conn.query_row(&format!("PRAGMA {name};"), [], |row| row.get(0))
        .map_err(|e| format!("Failed to read {name}: {e}"))
}

/// Recognize "another connection holds the database" and explain it.
#[cfg(not(target_arch = "wasm32"))]
fn busy_error(error: &rusqlite::Error) -> Option<String> {
    let code = match error {
        rusqlite::Error::SqliteFailure(err, _) => err.code,
        _ => return None,
    };
    matches!(
        code,
        rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
    )
    .then(in_use_error)
}

/// The one message for "another engine already has this database".
///
/// Both single-writer mechanisms report it, so which of them refused an open is
/// not something a caller has to distinguish. Tests match on `already open`.
#[cfg(not(target_arch = "wasm32"))]
fn in_use_error() -> String {
    "Database is already open by another connection or process. openmls \
     keeps an exclusive lock so that only one MlsEngine can use a database \
     file at a time — close the other engine first."
        .to_string()
}

/// Restrict a database file to its owner (`0600`).
///
/// Creating it here rather than letting SQLite do it avoids the window in
/// which the file exists with the process umask's default mode (typically
/// world-readable `0644` on desktops). SQLite gives the journal file the same
/// mode as the database, so it is covered too. Best effort: a failure here is
/// not fatal — SQLite reports a real problem with the path in a better way,
/// and the mode is moot inside a mobile app sandbox.
#[cfg(all(unix, not(target_arch = "wasm32")))]
fn restrict_permissions(db_path: &str) {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    if !is_plain_file_path(db_path) {
        return;
    }

    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(db_path)
    {
        Ok(_) => {}
        // Already there — tighten a database written before this change.
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let _ = std::fs::set_permissions(db_path, std::fs::Permissions::from_mode(0o600));
        }
        Err(_) => {}
    }
}

/// No-op: file modes are a Unix concept.
#[cfg(all(not(unix), not(target_arch = "wasm32")))]
fn restrict_permissions(_db_path: &str) {}

/// Whether `db_path` names an ordinary file this code may touch directly.
///
/// `":memory:"` has no file at all, and an empty path asks SQLite for a private
/// temporary database it deletes on close — neither has a file to set a mode on
/// or to place a lock beside, and both are private to their connection, so
/// neither needs one. `"file:…"` is rejected by `open` before it gets here; the
/// arm is kept so these helpers stay correct on their own.
#[cfg(all(unix, not(target_arch = "wasm32")))]
fn is_plain_file_path(db_path: &str) -> bool {
    !(db_path == ":memory:" || db_path.is_empty() || db_path.starts_with("file:"))
}

/// Hold `<db_path>.lock` for as long as this engine owns the database.
///
/// `locking_mode = EXCLUSIVE` plus the opening write transaction is not enough
/// on its own. SQLite's locks are POSIX advisory (`fcntl`) locks, and POSIX
/// releases *every* lock a process holds on an inode as soon as that process
/// closes *any* descriptor for it. SQLite works around this for the descriptors
/// it opened itself (`setPendingFd`), but it cannot know about anyone else's: a
/// single ordinary read of the database file from elsewhere in the same process
/// — a backup copy, an integrity check, a crash reporter collecting the file —
/// drops the exclusive lock while this engine is still live and still writing.
/// Nothing reports it, and another *process* can then open the same database
/// and overwrite this one's group state.
///
/// Measured on macOS against this code: with an engine open, a separate process
/// is refused; after one in-process `std::fs::read` of the database file, that
/// same process takes `BEGIN EXCLUSIVE` on it. A second engine in *this* process
/// stays refused either way, because SQLite tracks its own open inodes before it
/// reaches `fcntl` — which is why no black-box "a second engine is refused" test
/// can see the difference.
///
/// A lock on a separate file cannot be dropped that way: `File::try_lock` is
/// `flock`-based, which ties the lock to this one open file description rather
/// than to the process, and nothing else ever opens this file. The file is
/// deliberately never unlinked — removing it would let the next opener create a
/// fresh inode and lock that instead, which locks nothing at all.
#[cfg(all(unix, not(target_arch = "wasm32")))]
fn acquire_single_writer_lock(db_path: &str) -> Result<Option<std::fs::File>, String> {
    use std::os::unix::fs::OpenOptionsExt;

    // No file to sit beside, and none needed: `":memory:"` and the empty path
    // are private to their own connection, so two of them are two unrelated
    // databases that must not contend for one lock. (`open` has already
    // rejected the one case that would have silently skipped the lock while
    // being shareable — a `"file:…"` URI.)
    if !is_plain_file_path(db_path) {
        return Ok(None);
    }

    let lock_path = format!("{db_path}.lock");
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false) // The inode has to outlive every opener.
        .mode(0o600)
        .open(&lock_path)
        .map_err(|e| format!("Failed to open the lock file {lock_path}: {e}"))?;

    // Wait as long as SQLite would (rusqlite sets a 5-second busy timeout on
    // every connection). That matters on the path this lock exists for: with
    // SQLite's locks already released, this one is the only thing still holding
    // the database, so it owes the caller the same documented wait — and the
    // same refusal — that SQLite would have given.
    //
    // It also covers a much narrower race. Fields drop in declaration order, so
    // a closing engine releases its SQLite locks just before this lock, and an
    // opener that cleared `apply_pragmas` in that window would otherwise fail
    // where it used to succeed. `EncryptedDb::close` takes `self` by value, so
    // the gap is a few instructions wide; this is belt and braces.
    const DEADLINE: std::time::Duration = std::time::Duration::from_secs(5);
    const RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(25);

    // Measured against the clock, not by adding up the nominal delays: `sleep`
    // overshoots, so counting 200 × 25 ms as five seconds waits longer than the
    // five seconds this promises.
    let started = std::time::Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(Some(file)),
            Err(std::fs::TryLockError::WouldBlock) if started.elapsed() < DEADLINE => {
                std::thread::sleep(RETRY_DELAY);
            }
            Err(std::fs::TryLockError::WouldBlock) => return Err(in_use_error()),
            Err(std::fs::TryLockError::Error(e)) => {
                return Err(format!("Failed to lock {lock_path}: {e}"));
            }
        }
    }
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
            let old_version = event.old_version().unwrap_or(0);

            if old_version < 1 {
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

        let js_key = wasm_bindgen::JsValue::from(Uint8Array::from(WASM_META_KEY));
        let js_val = store
            .get(js_key)
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
        self.write_all(updates, Vec::new()).await
    }

    /// Save updates *and* drop every remaining row of the group, in one
    /// transaction — a crash cannot leave a deleted group half-purged.
    ///
    /// As in `delete_group`, "the group's rows" means every non-global entry:
    /// IDB keys carry no group column to filter on.
    pub async fn save_updates_and_purge_group(
        &self,
        updates: StorageUpdates,
        _group_id: &[u8],
    ) -> Result<(), String> {
        // Collected before the write transaction opens: an IDB transaction
        // auto-commits as soon as the event loop goes idle, so no await may
        // happen inside it.
        let purge: Vec<Vec<u8>> = self
            .idb_get_all_keys()
            .await?
            .into_iter()
            .filter(|key| !is_global_key(key))
            .collect();
        self.write_all(updates, purge).await
    }

    async fn write_all(
        &self,
        updates: StorageUpdates,
        purge: Vec<Vec<u8>>,
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

        for key in updates.deletes.iter().chain(purge.iter()) {
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

// ═══════════════════════════════════════════════════════════════
// TESTS (native)
// ═══════════════════════════════════════════════════════════════

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use futures::executor::block_on;

    /// A database path in the temp directory that cleans up after itself.
    struct TempDb {
        path: std::path::PathBuf,
    }

    impl TempDb {
        fn new(name: &str) -> Self {
            static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "openmls_frb_{name}_{}_{unique}.db",
                std::process::id()
            ));
            let _ = std::fs::remove_file(&path);
            Self { path }
        }

        fn as_str(&self) -> &str {
            self.path.to_str().expect("temp path is valid UTF-8")
        }
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
            // Rollback journals are named "<database>-journal". SQLite removes
            // one on commit; this only catches a run that died mid-write.
            let _ = std::fs::remove_file(std::path::PathBuf::from(format!(
                "{}-journal",
                self.path.display()
            )));
            // The sidecar lock file is never unlinked in production — see
            // `acquire_single_writer_lock` — so a test has to clean it up.
            let _ = std::fs::remove_file(std::path::PathBuf::from(format!(
                "{}.lock",
                self.path.display()
            )));
        }
    }

    fn open_db(path: &str) -> Result<EncryptedDb, String> {
        block_on(EncryptedDb::open(path.to_string(), vec![0x5a; 32]))
    }

    fn store(db: &EncryptedDb, key: &[u8], value: &[u8]) {
        let updates = StorageUpdates {
            upserts: vec![(key.to_vec(), value.to_vec())],
            deletes: Vec::new(),
        };
        block_on(db.save_updates(updates, None)).expect("save_updates");
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|window| window == needle)
    }

    /// Take the error of a failed open (`EncryptedDb` has no `Debug`, so
    /// `expect_err` is unavailable).
    fn open_error(result: Result<EncryptedDb, String>, expectation: &str) -> String {
        match result {
            Ok(_) => panic!("{expectation}"),
            Err(error) => error,
        }
    }

    #[test]
    fn raw_key_pragma_uses_sqlcipher_raw_key_form() {
        let pragma = raw_key_pragma(&[0xab; 32]);
        // Exactly "x'" + 64 hex digits + "'" (67 chars). Any other shape and
        // SQLCipher treats the value as a passphrase to run through PBKDF2
        // instead of using the caller's key directly.
        assert_eq!(pragma.len(), 67);
        assert_eq!(pragma.as_str(), format!("x'{}'", "ab".repeat(32)));
    }

    #[test]
    fn storage_updates_wipes_values_and_keeps_keys() {
        let mut updates = StorageUpdates {
            upserts: vec![(b"GroupContext".to_vec(), b"secret".to_vec())],
            deletes: vec![b"Tree".to_vec()],
        };

        updates.zeroize_values();

        assert_eq!(updates.upserts[0].0, b"GroupContext");
        assert!(updates.upserts[0].1.is_empty());
        assert_eq!(updates.deletes[0], b"Tree");
    }

    #[test]
    fn stored_values_are_encrypted_at_rest() {
        let temp = TempDb::new("at_rest");
        let db = open_db(temp.as_str()).expect("open");
        store(&db, b"KeyPackage/at-rest", b"plaintext-canary-value");
        drop(db);

        let bytes = std::fs::read(&temp.path).expect("read database file");
        assert!(
            !bytes.starts_with(b"SQLite format 3\0"),
            "database header is not encrypted"
        );
        assert!(!contains(&bytes, b"plaintext-canary-value"));
        assert!(!contains(&bytes, b"KeyPackage/at-rest"));
    }

    #[test]
    fn wrong_key_fails_closed() {
        let temp = TempDb::new("wrong_key");
        let db = open_db(temp.as_str()).expect("open");
        store(&db, b"KeyPackage/wrong-key", b"value");
        drop(db);

        let error = open_error(
            block_on(EncryptedDb::open(temp.as_str().to_string(), vec![0x11; 32])),
            "a wrong key must not open the database",
        );
        assert!(
            error.contains("Encryption key verification failed"),
            "unexpected error: {error}"
        );

        // The right key still works — the failure above is not a corrupted file.
        let db = open_db(temp.as_str()).expect("reopen with the correct key");
        let entries = block_on(db.load_global()).expect("load_global");
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn purging_a_group_keeps_global_entries() {
        let temp = TempDb::new("purge");
        let db = open_db(temp.as_str()).expect("open");

        // One group-scoped row and one global row.
        let updates = StorageUpdates {
            upserts: vec![
                (b"Tree/group-a".to_vec(), b"group state".to_vec()),
                (b"KeyPackage/global".to_vec(), b"key package".to_vec()),
            ],
            deletes: Vec::new(),
        };
        block_on(db.save_updates(updates, Some(b"group-a"))).expect("save");

        // Deleting the group writes its final state and purges its rows at once.
        let final_state = StorageUpdates {
            upserts: Vec::new(),
            deletes: vec![b"Tree/group-a".to_vec()],
        };
        block_on(db.save_updates_and_purge_group(final_state, b"group-a")).expect("purge");

        let remaining = block_on(db.load_for_group(b"group-a")).expect("load");
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].0, b"KeyPackage/global");
    }

    #[test]
    fn connection_pragmas_are_applied() {
        let temp = TempDb::new("pragmas");
        let db = open_db(temp.as_str()).expect("open");
        let conn = db.conn.lock().unwrap();

        let text = |pragma: &str| -> String {
            conn.query_row(&format!("PRAGMA {pragma};"), [], |row| row.get(0))
                .expect("read pragma")
        };
        let number = |pragma: &str| -> i64 {
            conn.query_row(&format!("PRAGMA {pragma};"), [], |row| row.get(0))
                .expect("read pragma")
        };

        assert_eq!(text("journal_mode"), "delete", "WAL must stay off");
        assert_eq!(text("locking_mode"), "exclusive", "single writer");
        assert_eq!(text("cipher_memory_security"), "1", "wipe SQLCipher buffers");
        assert_eq!(number("synchronous"), 2, "synchronous must be FULL");
        // fullfsync stays off on purpose — see `apply_pragmas`. Asserted so
        // that turning it on becomes a deliberate change with a test to update.
        assert_eq!(number("fullfsync"), 0, "fullfsync costs 16 ms per operation");
    }

    #[test]
    fn a_second_connection_is_refused_until_the_first_closes() {
        let temp = TempDb::new("exclusive");
        let first = open_db(temp.as_str()).expect("first open");

        let error = open_error(
            open_db(temp.as_str()),
            "a second connection must be refused",
        );
        assert!(error.contains("already open"), "unexpected error: {error}");

        // Closing the first connection releases the lock.
        drop(first);
        open_db(temp.as_str()).expect("reopen after the first connection closed");
    }

    /// A keyed connection with no sidecar lock, for testing `apply_pragmas` on
    /// its own. `open` layers the sidecar over this; these tests need the
    /// connection-level mechanism in isolation to attribute a refusal to it.
    fn keyed_connection(path: &str) -> rusqlite::Connection {
        let conn = rusqlite::Connection::open(path).expect("open connection");
        conn.execute_batch("PRAGMA cipher_memory_security = ON;")
            .expect("cipher_memory_security");
        let pragma = raw_key_pragma(&[0x5a; 32]);
        conn.pragma_update(None, "key", pragma.as_str())
            .expect("set key");
        conn
    }

    #[test]
    fn apply_pragmas_takes_the_write_lock_immediately() {
        // Attribution for `BEGIN EXCLUSIVE; COMMIT;`. The sidecar lock refuses a
        // second *engine* even without it, which would leave that statement
        // untested through `open`; `locking_mode = EXCLUSIVE` on its own only
        // keeps a read lock, letting two connections both open and collide on
        // the first write instead. So drive the connection layer directly.
        let temp = TempDb::new("write_lock");
        drop(open_db(temp.as_str()).expect("create the database"));

        let first = keyed_connection(temp.as_str());
        EncryptedDb::apply_pragmas(&first).expect("first connection");

        let second = keyed_connection(temp.as_str());
        let error = EncryptedDb::apply_pragmas(&second)
            .expect_err("a second connection must not get the write lock");
        assert!(error.contains("already open"), "unexpected error: {error}");
    }

    #[cfg(unix)]
    #[test]
    fn the_sidecar_lock_survives_an_in_process_descriptor_close() {
        // The defect this lock exists for: POSIX releases every advisory lock a
        // process holds on an inode when the process closes *any* descriptor for
        // it, so one ordinary read of the database file drops the SQLite locks
        // taken at open. Verified below on the real file, then verified that the
        // sidecar is unaffected — it lives on a different inode that nothing
        // else in the process opens.
        let temp = TempDb::new("sidecar");
        let db = open_db(temp.as_str()).expect("open");
        let lock_path = format!("{}.lock", temp.path.display());

        let sidecar_is_held = || {
            // `File::try_lock` is `flock`-based: the lock belongs to one open
            // file description, not to the process, so an independently opened
            // handle here contends exactly as another process would.
            let probe = std::fs::File::open(&lock_path).expect("open the lock file");
            matches!(probe.try_lock(), Err(std::fs::TryLockError::WouldBlock))
        };

        assert!(sidecar_is_held(), "the engine must hold the sidecar lock");

        // One read of the database file, exactly as a backup or an integrity
        // check would do it. This is what silently drops SQLite's own locks.
        let bytes = std::fs::read(&temp.path).expect("read the database file");
        assert!(!bytes.is_empty());

        assert!(
            sidecar_is_held(),
            "the sidecar lock must outlive an unrelated read of the database"
        );

        // And it is released when the engine goes away, not before.
        drop(db);
        assert!(!sidecar_is_held(), "closing the engine releases the lock");
    }

    #[cfg(unix)]
    #[test]
    fn a_held_sidecar_alone_reports_in_use() {
        // The sidecar carries the refusal on its own, with SQLite's locks free —
        // which is the state the previous test creates. Same message as a
        // SQLite-level refusal, so callers need not tell them apart.
        let temp = TempDb::new("sidecar_only");
        drop(open_db(temp.as_str()).expect("create the database"));

        let lock_path = format!("{}.lock", temp.path.display());
        let holder = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&lock_path)
            .expect("open the lock file");
        holder.try_lock().expect("take the lock");

        let error = open_error(
            open_db(temp.as_str()),
            "an engine must not open a database whose sidecar lock is held",
        );
        assert!(error.contains("already open"), "unexpected error: {error}");

        // Releasing it hands the database over.
        drop(holder);
        open_db(temp.as_str()).expect("reopen once the lock is released");
    }

    #[cfg(unix)]
    #[test]
    fn in_memory_databases_take_no_lock_file() {
        // `":memory:"` is a documented path and every example app uses it. Each
        // one is a private database, so several must be able to run at once —
        // which they could not if they all contended for one lock file. There is
        // no file to put a lock beside in the first place: the name would be
        // taken literally and land in the working directory.
        let cwd = std::env::current_dir().expect("current directory");
        let stray = cwd.join(":memory:.lock");
        // `restrict_permissions` shares the same guard and would likewise create
        // a literal `:memory:` file without it; clean up after both so breaking
        // the guard on purpose (to check this test still fails) leaves no litter.
        let stray_db = cwd.join(":memory:");
        let _ = std::fs::remove_file(&stray);

        // Nothing below may panic before the cleanup, or a failing run leaves a
        // locked file behind: check and collect first, assert last.
        let first = open_db(":memory:").expect("first in-memory engine");
        let created = stray.exists();
        let second = open_db(":memory:");
        let coexist = second.is_ok();
        drop((first, second));
        let _ = std::fs::remove_file(&stray);
        let _ = std::fs::remove_file(&stray_db);

        assert!(!created, "an in-memory database created {}", stray.display());
        assert!(coexist, "two in-memory engines must be able to run at once");
    }

    #[test]
    fn file_uris_are_rejected() {
        // rusqlite enables SQLITE_OPEN_URI by default, so a `file:…` URI does
        // open a real, file-backed database — but the path it resolves to
        // cannot be recovered without parsing the URI's query parameters, so it
        // would get neither owner-only permissions nor a lock file. Refused
        // rather than handed back with both quietly missing.
        let temp = TempDb::new("file_uri");
        let uri = format!("file:{}", temp.path.display());

        let error = open_error(
            block_on(EncryptedDb::open(uri, vec![0x5a; 32])),
            "a file: URI must be refused",
        );
        assert!(error.contains("plain file path"), "unexpected error: {error}");

        // Refused before anything touched the filesystem.
        assert!(
            !temp.path.exists(),
            "a rejected open must not create the database"
        );
        assert!(
            !std::path::Path::new(&format!("{}.lock", temp.path.display())).exists(),
            "a rejected open must not create a lock file"
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_lock_file_is_owner_only_and_survives_reopening() {
        use std::os::unix::fs::PermissionsExt;

        let temp = TempDb::new("lock_mode");
        let lock_path = std::path::PathBuf::from(format!("{}.lock", temp.path.display()));

        // Handing the file from one engine to the next, repeatedly: the lock file
        // is reused rather than recreated, because unlinking it would let the
        // next opener lock a fresh inode that guards nothing.
        for _ in 0..3 {
            let db = open_db(temp.as_str()).expect("open");
            let inode = std::fs::metadata(&lock_path).expect("stat lock file");
            assert_eq!(inode.permissions().mode() & 0o777, 0o600);
            drop(db);
            assert!(lock_path.exists(), "the lock file is never unlinked");
        }
    }

    #[cfg(unix)]
    #[test]
    fn database_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let temp = TempDb::new("permissions");
        let _db = open_db(temp.as_str()).expect("open");

        let mode = std::fs::metadata(&temp.path)
            .expect("stat database file")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "database file mode is {mode:o}");
    }

    #[cfg(unix)]
    #[test]
    fn existing_world_readable_database_is_tightened() {
        use std::os::unix::fs::PermissionsExt;

        let temp = TempDb::new("tighten");
        std::fs::write(&temp.path, b"").expect("create database file");
        std::fs::set_permissions(&temp.path, std::fs::Permissions::from_mode(0o644))
            .expect("relax permissions");

        let _db = open_db(temp.as_str()).expect("open");

        let mode = std::fs::metadata(&temp.path)
            .expect("stat database file")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "database file mode is {mode:o}");
    }
}
