//! WASM proof-of-concept: async I/O → sync HashMap → async I/O.
//!
//! Validates that Rust can do async IndexedDB I/O on WASM without deadlock,
//! called from Dart via FRB. Temporary module — will be removed after PoC.

use std::collections::HashMap;

// ---------------------------------------------------------------------------
// PoC 1: Unencrypted roundtrip (async I/O → sync HashMap → async I/O)
// ---------------------------------------------------------------------------

/// Store a key-value pair, load it into a sync HashMap, then write back.
/// Proves the pattern: async DB write → sync HashMap op → async DB write.
pub async fn poc_store_and_load(key: String, value: Vec<u8>) -> Result<Vec<u8>, String> {
    // 1. ASYNC: write entry to DB
    poc_db_write(&key, &value).await?;

    // 2. SYNC: load into HashMap, transform
    let mut map = HashMap::new();
    let loaded = poc_db_read(&key).await?;
    map.insert(key.clone(), loaded.unwrap_or_default());
    let result = map.get(&key).cloned().unwrap_or_default();

    // 3. ASYNC: write result back under a different key
    poc_db_write(&format!("{key}_result"), &result).await?;

    Ok(result)
}

/// Full roundtrip test: write → sync transform → read back → verify.
pub async fn poc_roundtrip_test() -> Result<String, String> {
    let test_data = vec![1, 2, 3, 4, 5];
    let result = poc_store_and_load("poc_test_key".into(), test_data.clone()).await?;
    if result == test_data {
        Ok("WASM PoC: async I/O \u{2192} sync HashMap \u{2192} async I/O \u{2014} SUCCESS".into())
    } else {
        Err(format!(
            "Data mismatch: expected {:?}, got {:?}",
            test_data, result
        ))
    }
}

// ---------------------------------------------------------------------------
// PoC 2: Encrypted roundtrip (AES-256-GCM + IndexedDB)
// ---------------------------------------------------------------------------

use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::Aead,
};

/// Format: [12-byte nonce || ciphertext]
fn encrypt_value(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    use aes_gcm::aead::OsRng;
    use aes_gcm::AeadCore;

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

fn decrypt_value(key: &[u8; 32], data: &[u8]) -> Result<Vec<u8>, String> {
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

/// Encrypted roundtrip test:
/// 1. Generate AES-256-GCM key
/// 2. Encrypt plaintext → write encrypted blob to DB
/// 3. Read raw bytes from DB (this is what you see in DevTools — gibberish)
/// 4. Decrypt → verify matches original
///
/// Returns a report with the raw encrypted hex (for visual inspection in DevTools).
pub async fn poc_encrypted_roundtrip(encryption_key: Vec<u8>) -> Result<String, String> {
    if encryption_key.len() != 32 {
        return Err(format!(
            "encryption_key must be 32 bytes, got {}",
            encryption_key.len()
        ));
    }
    let key: [u8; 32] = encryption_key.try_into().unwrap();

    let plaintext = b"Hello MLS! This is secret group data that must NOT be visible in IndexedDB.";
    let db_key = "encrypted_poc_test";

    // Encrypt and store
    let encrypted = encrypt_value(&key, plaintext)?;
    poc_db_write(db_key, &encrypted).await?;

    // Read raw from DB (this is what DevTools shows)
    let raw_from_db = poc_db_read(db_key)
        .await?
        .ok_or("key not found after write")?;

    // Decrypt and verify
    let decrypted = decrypt_value(&key, &raw_from_db)?;

    let mut report = String::new();
    report.push_str("=== Encrypted DB PoC ===\n\n");
    report.push_str(&format!(
        "Plaintext ({} bytes):\n  \"{}\"\n\n",
        plaintext.len(),
        std::str::from_utf8(plaintext).unwrap()
    ));
    report.push_str(&format!(
        "Encrypted blob in DB ({} bytes):\n  {}\n\n",
        raw_from_db.len(),
        hex_string(&raw_from_db)
    ));
    report.push_str(&format!(
        "  Nonce (12 bytes): {}\n",
        hex_string(&raw_from_db[..12])
    ));
    report.push_str(&format!(
        "  Ciphertext+tag ({} bytes): {}\n\n",
        raw_from_db.len() - 12,
        hex_string(&raw_from_db[12..])
    ));
    report.push_str(&format!(
        "Decrypted ({} bytes):\n  \"{}\"\n\n",
        decrypted.len(),
        std::str::from_utf8(&decrypted).map_err(|e| format!("utf8 error: {e}"))?
    ));
    report.push_str(&format!(
        "Match: {}\n",
        if decrypted == plaintext {
            "SUCCESS — plaintext recovered correctly"
        } else {
            "FAIL — data mismatch!"
        }
    ));
    report.push_str("\nCheck Chrome DevTools > Application > IndexedDB > poc_db > kv_store\n");
    report.push_str("Key 'encrypted_poc_test' should show only the encrypted blob above.");

    Ok(report)
}

/// Test that decryption with the wrong key fails.
pub async fn poc_wrong_key_test(
    correct_key: Vec<u8>,
    wrong_key: Vec<u8>,
) -> Result<String, String> {
    if correct_key.len() != 32 || wrong_key.len() != 32 {
        return Err("both keys must be 32 bytes".into());
    }
    let correct: [u8; 32] = correct_key.try_into().unwrap();
    let wrong: [u8; 32] = wrong_key.try_into().unwrap();

    let plaintext = b"Secret data for wrong-key test";
    let db_key = "wrong_key_test";

    // Encrypt with correct key
    let encrypted = encrypt_value(&correct, plaintext)?;
    poc_db_write(db_key, &encrypted).await?;

    // Try to decrypt with wrong key
    let raw = poc_db_read(db_key).await?.ok_or("key not found")?;
    match decrypt_value(&wrong, &raw) {
        Err(e) => Ok(format!(
            "Wrong key correctly rejected: {e}\n\
             Data is safe — cannot be decrypted without the correct key."
        )),
        Ok(data) => Err(format!(
            "BUG: wrong key produced output: {:?}",
            &data[..data.len().min(32)]
        )),
    }
}

fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ---------------------------------------------------------------------------
// WASM backend: IndexedDB via `idb` crate
// ---------------------------------------------------------------------------
#[cfg(target_arch = "wasm32")]
async fn poc_open_db() -> Result<idb::Database, String> {
    use idb::{DatabaseEvent, Factory, ObjectStoreParams};

    let factory = Factory::new().map_err(|e| format!("Factory::new failed: {e}"))?;
    let mut open_req = factory
        .open("poc_db", Some(1))
        .map_err(|e| format!("Factory::open failed: {e}"))?;

    open_req.on_upgrade_needed(|event| {
        let db = event.database().unwrap();
        if !db.store_names().contains(&"kv_store".to_string()) {
            db.create_object_store("kv_store", ObjectStoreParams::new())
                .unwrap();
        }
    });

    open_req
        .await
        .map_err(|e| format!("open_request.await failed: {e}"))
}

#[cfg(target_arch = "wasm32")]
async fn poc_db_write(key: &str, value: &[u8]) -> Result<(), String> {
    use idb::TransactionMode;
    use js_sys::Uint8Array;
    use wasm_bindgen::JsValue;

    let db = poc_open_db().await?;
    let txn = db
        .transaction(&["kv_store"], TransactionMode::ReadWrite)
        .map_err(|e| format!("transaction failed: {e}"))?;
    let store = txn
        .object_store("kv_store")
        .map_err(|e| format!("object_store failed: {e}"))?;

    let js_key = JsValue::from_str(key);
    let js_val = Uint8Array::from(value);
    store
        .put(&js_val, Some(&js_key))
        .map_err(|e| format!("put failed: {e}"))?
        .await
        .map_err(|e| format!("put.await failed: {e}"))?;
    txn.commit()
        .map_err(|e| format!("commit failed: {e}"))?
        .await
        .map_err(|e| format!("commit.await failed: {e}"))?;
    db.close();
    Ok(())
}

#[cfg(target_arch = "wasm32")]
async fn poc_db_read(key: &str) -> Result<Option<Vec<u8>>, String> {
    use idb::TransactionMode;
    use js_sys::Uint8Array;
    use wasm_bindgen::JsValue;

    let db = poc_open_db().await?;
    let txn = db
        .transaction(&["kv_store"], TransactionMode::ReadOnly)
        .map_err(|e| format!("transaction failed: {e}"))?;
    let store = txn
        .object_store("kv_store")
        .map_err(|e| format!("object_store failed: {e}"))?;

    let js_key = JsValue::from_str(key);
    let result = store
        .get(js_key)
        .map_err(|e| format!("get failed: {e}"))?
        .await
        .map_err(|e| format!("get.await failed: {e}"))?;

    db.close();

    match result {
        Some(js_val) => {
            let array = Uint8Array::new(&js_val);
            Ok(Some(array.to_vec()))
        }
        None => Ok(None),
    }
}

// ---------------------------------------------------------------------------
// Native backend: in-memory HashMap (no persistence needed for PoC)
// ---------------------------------------------------------------------------
#[cfg(not(target_arch = "wasm32"))]
static POC_STORE: std::sync::LazyLock<std::sync::Mutex<HashMap<String, Vec<u8>>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

#[cfg(not(target_arch = "wasm32"))]
async fn poc_db_write(key: &str, value: &[u8]) -> Result<(), String> {
    POC_STORE
        .lock()
        .unwrap()
        .insert(key.to_string(), value.to_vec());
    Ok(())
}

#[cfg(not(target_arch = "wasm32"))]
async fn poc_db_read(key: &str) -> Result<Option<Vec<u8>>, String> {
    Ok(POC_STORE.lock().unwrap().get(key).cloned())
}
