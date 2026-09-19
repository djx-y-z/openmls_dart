//! Engine-based API — uses Rust-owned encrypted DB instead of Dart callbacks.
//!
//! `MlsEngine` wraps an `EncryptedDb` and provides all MLS operations as
//! async methods. Storage is managed entirely in Rust — Dart never sees raw
//! key-value data.
//!
//! Functions are `async` because DB I/O is async (SQLCipher on native,
//! IndexedDB on WASM).

use std::time::Duration;
// `Lifetime::validate_with_time` takes a `SystemTime`, and *which* `SystemTime`
// that is depends on the target: openmls picks `web_time`'s under
// `cfg(target_arch = "wasm32")` and `std`'s everywhere else. The two are
// unrelated types, so the epoch we add to has to be selected the same way.
#[cfg(not(target_arch = "wasm32"))]
use std::time::{SystemTime, UNIX_EPOCH};
#[cfg(target_arch = "wasm32")]
use web_time::{SystemTime, UNIX_EPOCH};

use openmls::prelude::*;
use openmls::prelude::tls_codec::{
    DeserializeBytes as TlsDeserializeBytes, Serialize as TlsSerialize,
};
use openmls::ciphersuite::hash_ref::ProposalRef;
use openmls::schedule::PreSharedKeyId;
use openmls_traits::OpenMlsProvider;
use openmls_traits::storage::StorageProvider;

use super::config::MlsGroupConfig;
use super::keys::signer_from_bytes;
use super::types::{
    ciphersuite_to_native, native_to_ciphersuite, capabilities_to_native, extensions_from_mls,
    FlexibleCommitOptions, KeyPackageOptions, MlsCapabilities, MlsCiphersuite, MlsExtension,
    MlsGroupContextInfo, MlsLeafNodeInfo, MlsMemberInfo, MlsPendingProposalInfo, MlsProposalType,
    MlsWireFormatPolicy, ProcessedMessageType, StagedCommitInfo, WelcomeInspectResult,
};
use crate::snapshot_storage::{SnapshotOpenMlsProvider, SnapshotStorageProvider};

// ═══════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════

/// Build a `CredentialWithKey` either from a TLS-serialized `Credential` (for X.509 or custom
/// credential types) or by creating a `BasicCredential` from the identity bytes.
fn build_credential_with_key(
    credential_identity: &[u8],
    signer_public_key: &[u8],
    credential_bytes: Option<&[u8]>,
) -> Result<CredentialWithKey, String> {
    let credential = match credential_bytes {
        Some(bytes) => Credential::tls_deserialize_exact_bytes(bytes)
            .map_err(|e| format!("Failed to deserialize credential: {e}"))?,
        None => BasicCredential::new(credential_identity.to_vec()).into(),
    };
    Ok(CredentialWithKey {
        credential,
        signature_key: SignaturePublicKey::from(signer_public_key.to_vec()),
    })
}

/// Load an MlsGroup from the provider's storage.
fn load_group<P: OpenMlsProvider>(group_id: &[u8], provider: &P) -> Result<MlsGroup, String> {
    let gid = GroupId::from_slice(group_id);
    MlsGroup::load(provider.storage(), &gid)
        .map_err(|e| format!("Failed to load group: {}", e))?
        .ok_or_else(|| "No group found in storage".to_string())
}

// ═══════════════════════════════════════════════════════════════
// RESULT TYPES
// ═══════════════════════════════════════════════════════════════

pub struct CreateGroupResult {
    pub group_id: Vec<u8>,
}

pub struct JoinGroupResult {
    pub group_id: Vec<u8>,
}

pub struct ExternalJoinResult {
    pub group_id: Vec<u8>,
    pub commit: Vec<u8>,
    pub group_info: Option<Vec<u8>>,
}

pub struct AddMembersResult {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
    pub group_info: Option<Vec<u8>>,
}

pub struct CommitResult {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub group_info: Option<Vec<u8>>,
}

pub struct ProposalResult {
    pub proposal_message: Vec<u8>,
}

pub struct CreateMessageResult {
    pub ciphertext: Vec<u8>,
}

pub struct ProcessedMessageResult {
    pub message_type: ProcessedMessageType,
    pub sender_index: Option<u32>,
    pub epoch: u64,
    pub application_message: Option<Vec<u8>>,
    pub has_staged_commit: bool,
    pub has_proposal: bool,
    pub proposal_type: Option<MlsProposalType>,
}

pub struct ProcessedMessageInspectResult {
    pub message_type: ProcessedMessageType,
    pub sender_index: Option<u32>,
    pub epoch: u64,
    pub application_message: Option<Vec<u8>>,
    pub staged_commit_info: Option<StagedCommitInfo>,
    pub proposal_type: Option<MlsProposalType>,
}

pub struct KeyPackageResult {
    pub key_package_bytes: Vec<u8>,
}

pub struct LeaveGroupResult {
    pub message: Vec<u8>,
}

pub struct GroupConfigurationResult {
    pub ciphersuite: MlsCiphersuite,
    pub wire_format_policy: MlsWireFormatPolicy,
    pub padding_size: u32,
    pub sender_ratchet_max_out_of_order: u32,
    pub sender_ratchet_max_forward_distance: u32,
}

// ═══════════════════════════════════════════════════════════════
// PAST EPOCH SECRETS
// ═══════════════════════════════════════════════════════════════

/// How many past epochs' message secrets a group keeps, as
/// `pastEpochDeletionPolicy` reports it.
///
/// An application message is encrypted under the epoch its sender was in. Once
/// a commit advances the group, a message that was already in flight can only
/// be read from the secrets of the epoch it was sent in — so a group that
/// keeps none of them discards such a message. Keeping a few is what lets a
/// delivery service reorder or delay messages across a commit.
///
/// ⚠ **Keeping any is a forward-secrecy trade-off, not a tuning knob.** The
/// secrets of a past epoch decrypt every message of that epoch, including ones
/// an attacker recorded earlier, for as long as they remain stored. OpenMLS
/// asks for the number to be as low as the delivery service allows; the
/// default keeps none.
pub struct PastEpochDeletionPolicyResult {
    /// True when the group keeps every past epoch's secrets — the state
    /// `setPastEpochDeletionPolicyKeepAll` puts it in. `maxEpochs` says
    /// nothing then.
    pub keep_all: bool,
    /// How many past epochs' secrets are kept, when `keepAll` is false. Zero
    /// — the default for a new group — keeps none.
    pub max_epochs: u32,
}

/// Reads OpenMLS's policy into the pair Dart sees.
///
/// Everything this cannot report as a number is reported as keep-all, which
/// keeps the surface total in both directions: the number that comes out is
/// always one `max_epochs_to_native` would take back in.
///
/// Two quite different inputs land in that arm.
///
/// ⚠ The first is not an edge case on every target. OpenMLS serializes
/// `KeepAll` as `usize::MAX` and deserializes only `u64::MAX` back into it, so
/// where `usize` is 32 bits — the Web, 32-bit Android — a stored `KeepAll`
/// comes back as `MaxEpochs(usize::MAX)` instead. Mapping it here is what makes
/// the Dart surface answer the same way on every platform.
///
/// The second is a number too large to be one of ours: everything this crate
/// writes came through `max_epochs_to_native` and so fits a `u32` with room to
/// spare, and a store written by another OpenMLS application could hold more.
/// Keep-all is the honest summary of such a value — it is more epochs than
/// anything will ever hold — and it beats reporting a number the setter would
/// refuse.
fn native_to_past_epoch_policy(policy: &PastEpochDeletionPolicy) -> PastEpochDeletionPolicyResult {
    let keep_all = PastEpochDeletionPolicyResult { keep_all: true, max_epochs: 0 };
    match policy {
        PastEpochDeletionPolicy::KeepAll => keep_all,
        PastEpochDeletionPolicy::MaxEpochs(n) => match u32::try_from(*n) {
            Ok(max_epochs) if max_epochs < u32::MAX => PastEpochDeletionPolicyResult {
                keep_all: false,
                max_epochs,
            },
            _ => keep_all,
        },
    }
}

fn max_epochs_to_native(max_epochs: u32) -> Result<PastEpochDeletionPolicy, String> {
    if max_epochs == u32::MAX {
        return Err(format!(
            "maxEpochs must be below {}: that value is what OpenMLS stores to mean \
             keep-all on a 32-bit target, so the two settings would be one stored \
             value there and two everywhere else. Use \
             setPastEpochDeletionPolicyKeepAll instead.",
            u32::MAX
        ));
    }
    Ok(PastEpochDeletionPolicy::MaxEpochs(max_epochs as usize))
}

/// Applies the optional "and keep at most this many" modifier.
///
/// Only the three selective deletions take it. `PastEpochDeletion::delete_all`
/// carries no time config, and OpenMLS applies the modifier only to requests
/// that have one — so `delete_all().max_past_epochs(n)` deletes everything and
/// ignores `n`. `deleteAllPastEpochSecrets` therefore does not offer it.
fn with_cap(deletion: PastEpochDeletion, max_past_epochs: Option<u32>) -> PastEpochDeletion {
    match max_past_epochs {
        Some(n) => deletion.max_past_epochs(n as usize),
        None => deletion,
    }
}

// ═══════════════════════════════════════════════════════════════
// MLS ENGINE
// ═══════════════════════════════════════════════════════════════

pub struct MlsEngine {
    db: parking_lot::RwLock<Option<std::sync::Arc<crate::encrypted_db::EncryptedDb>>>,
    /// Serializes the load → operate → save sequence of every operation.
    ///
    /// Each method loads a snapshot of the stored group state, lets OpenMLS
    /// mutate it in memory, then writes back the diff. Two calls that overlap
    /// would load the same base snapshot and the later write-back would drop
    /// the other one's changes — a merged commit, an advanced ratchet or a
    /// stored proposal would silently disappear and desynchronize the group.
    ///
    /// This is an async mutex on purpose: the guarded span contains `.await`
    /// points, and a blocking mutex would deadlock the single-threaded WASM
    /// event loop (where the same interleaving happens without threads).
    op_lock: futures::lock::Mutex<()>,
}

/// Exclusive session over one engine's storage.
///
/// Owns the snapshot provider *and* the engine-wide operation lock, so a
/// provider cannot exist without the lock being held. The guard lives until
/// the session is consumed by [`MlsEngine::commit`] (or dropped by a method
/// that only reads), which keeps the whole load → operate → save span
/// serialized.
struct OpSession<'a> {
    locks: OpLocks<'a>,
    provider: SnapshotOpenMlsProvider,
}

/// Everything an [`OpSession`] holds besides its snapshot.
///
/// Kept as one value so a method that has to move the provider out of the
/// session can bind the locks in the same `let` and keep them alive across the
/// write-back. Destructuring with `..` instead would drop them right there,
/// releasing the lock while the save is still running — which is the exact
/// interleaving this guards against.
struct OpLocks<'a> {
    /// Serializes operations on THIS engine — see [`MlsEngine::op_lock`].
    _guard: futures::lock::MutexGuard<'a, ()>,
    /// Serializes operations across browsing contexts of one origin, which the
    /// mutex above cannot see: another tab is another WASM instance with
    /// another engine, addressing the same IndexedDB database. Native needs no
    /// counterpart — its sidecar lock file refuses the second opener outright.
    #[cfg(target_arch = "wasm32")]
    _web_lock: crate::web_lock::WebLockGuard,
}

/// Delegates to the wrapped snapshot provider so `OpSession` can be handed to
/// OpenMLS directly — call sites never see the guard.
impl OpenMlsProvider for OpSession<'_> {
    type CryptoProvider = <SnapshotOpenMlsProvider as OpenMlsProvider>::CryptoProvider;
    type RandProvider = <SnapshotOpenMlsProvider as OpenMlsProvider>::RandProvider;
    type StorageProvider = <SnapshotOpenMlsProvider as OpenMlsProvider>::StorageProvider;

    fn storage(&self) -> &Self::StorageProvider {
        self.provider.storage()
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        self.provider.crypto()
    }

    fn rand(&self) -> &Self::RandProvider {
        self.provider.rand()
    }
}

impl MlsEngine {
    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /// Create a new MlsEngine backed by an encrypted database.
    ///
    /// # Arguments
    ///
    /// * `dbPath` — Database location.
    ///   - **Native**: file path for SQLCipher (e.g. `"path/to/mls.db"`).
    ///     Use `":memory:"` for an ephemeral in-memory database (destroyed on drop,
    ///     useful for tests). A `"file:…"` URI is rejected: the path it resolves
    ///     to cannot be recovered without parsing the URI, so such a database
    ///     would get neither owner-only permissions nor the lock file below.
    ///   - **WASM**: IndexedDB database name (e.g. `"mls_account_123"`).
    ///     `":memory:"` generates a unique random name per instance to match the
    ///     native ephemeral behavior.
    ///   - Tip: include an account identifier in the path to isolate data per user
    ///     (e.g. `"mls_{account_id}.db"` on native, `"mls_{account_id}"` on web).
    ///
    /// * `encryptionKey` — 32-byte AES-256 key that protects data at rest.
    ///   The caller is responsible for generating, storing, and providing this key.
    ///   Recommended pattern: generate a random key on first launch and persist it
    ///   in platform secure storage (e.g. Keychain on iOS/macOS, Android Keystore,
    ///   or `flutter_secure_storage`).
    ///
    /// # One engine per database file
    ///
    /// On native the database is locked exclusively. A second engine on the same
    /// file — another instance, isolate or process — fails with "Database is
    /// already open by another connection or process" rather than silently
    /// overwriting this one's group state. `MlsEngine.close` releases the
    /// lock; an overlapping opener waits out a five-second timeout first, so
    /// handing the file over during teardown still works.
    ///
    /// On Unix this is held partly by a lock file next to the database, named
    /// `<db_path>.lock`, which the engine creates and never deletes. An empty
    /// file beside the database is expected; deleting it while an engine is
    /// running removes the protection.
    ///
    /// On the Web the shape is different, because the unit is a browser tab and
    /// not a process: tabs are opened and closed by the person using the
    /// application, so a second one is not refused. Every operation takes an
    /// exclusive Web Lock named after the IndexedDB database instead, which
    /// serializes the load → operate → save cycles of every tab and worker on
    /// the origin. One that cannot get in within five seconds fails with
    /// "Database is busy" rather than waiting behind a wedged tab forever.
    ///
    /// That guarantee needs a secure context, which is where `navigator.locks`
    /// exists at all: `https`, or `http` on `localhost`. Served over plain
    /// `http` from any other host the API is absent, and operations run exactly
    /// as they did before it was used — without the cross-tab guarantee, never
    /// with an error.
    ///
    /// Calls on one engine are safe to make concurrently: each runs its
    /// load → operate → save cycle under an engine-wide lock.
    pub async fn create(db_path: String, encryption_key: Vec<u8>) -> Result<MlsEngine, String> {
        let db = crate::encrypted_db::EncryptedDb::open(db_path, encryption_key).await?;
        Ok(MlsEngine {
            db: parking_lot::RwLock::new(Some(std::sync::Arc::new(db))),
            op_lock: futures::lock::Mutex::new(()),
        })
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    fn db(&self) -> Result<std::sync::Arc<crate::encrypted_db::EncryptedDb>, String> {
        self.db.read().as_ref().cloned().ok_or_else(|| "MlsEngine is closed".to_string())
    }

    /// Take every lock an operation needs, in one order everywhere.
    ///
    /// Engine-wide mutex first, cross-context lock second. The order is what
    /// keeps it deadlock-free: taking them the other way round in one of the
    /// two callers would be enough for two operations to hold one each.
    #[cfg(not(target_arch = "wasm32"))]
    async fn acquire_locks(&self) -> Result<OpLocks<'_>, String> {
        Ok(OpLocks { _guard: self.op_lock.lock().await })
    }

    /// See the native twin above. The Web build adds the cross-tab lock, whose
    /// wait can time out — which is why this returns a `Result` on both
    /// targets rather than only here.
    #[cfg(target_arch = "wasm32")]
    async fn acquire_locks(&self) -> Result<OpLocks<'_>, String> {
        let guard = self.op_lock.lock().await;
        let name = self.db()?.lock_name();
        let web_lock =
            crate::web_lock::acquire(&name, crate::web_lock::WEB_LOCK_TIMEOUT_MS).await?;
        Ok(OpLocks { _guard: guard, _web_lock: web_lock })
    }

    /// Take the operation locks and load a group's snapshot under them.
    async fn load_for_group(&self, group_id: &[u8]) -> Result<OpSession<'_>, String> {
        let locks = self.acquire_locks().await?;
        let entries = self.db()?.load_for_group(group_id).await?;
        Ok(OpSession {
            locks,
            provider: SnapshotOpenMlsProvider::new(SnapshotStorageProvider::from_entries(entries)),
        })
    }

    /// Take the operation locks and load the global (group-independent)
    /// snapshot under them.
    async fn load_global(&self) -> Result<OpSession<'_>, String> {
        let locks = self.acquire_locks().await?;
        let entries = self.db()?.load_global().await?;
        Ok(OpSession {
            locks,
            provider: SnapshotOpenMlsProvider::new(SnapshotStorageProvider::from_entries(entries)),
        })
    }

    /// Diff a session's snapshot, write it back, and release the operation
    /// lock.
    async fn commit(&self, session: OpSession<'_>, group_id: Option<&[u8]>) -> Result<(), String> {
        // Binding the locks keeps them alive until this function returns, so
        // the write-back still happens under them.
        let OpSession { locks: _locks, provider } = session;
        let updates = provider.into_storage().into_updates();
        if updates.upserts.is_empty() && updates.deletes.is_empty() {
            return Ok(());
        }
        self.db()?.save_updates(updates, group_id).await
    }

    // ═══════════════════════════════════════════════════════════
    // KEY PACKAGES
    // ═══════════════════════════════════════════════════════════

    /// Builds a key package with OpenMLS's defaults for everything except the
    /// ciphersuite and the credential.
    ///
    /// Those defaults include the advertised capabilities, and the ciphersuite
    /// list inside them is every suite `supportedCiphersuites` returns — ten of
    /// them experimental post-quantum suites on provisional code points. A peer
    /// reading this key package may therefore pick one of those for a group.
    ///
    /// To advertise a narrower set, or to change the lifetime, mark the package
    /// last-resort, or attach extensions, use `createKeyPackageWithOptions`
    /// instead: `KeyPackageOptions.capabilities` is where the ciphersuite list
    /// goes.
    pub async fn create_key_package(
        &self,
        ciphersuite: MlsCiphersuite,
        signer_bytes: Vec<u8>,
        credential_identity: Vec<u8>,
        signer_public_key: Vec<u8>,
        credential_bytes: Option<Vec<u8>>,
    ) -> Result<KeyPackageResult, String> {
        let cs = ciphersuite_to_native(&ciphersuite);
        let signer = signer_from_bytes(signer_bytes)?;
        let credential_with_key = build_credential_with_key(
            &credential_identity, &signer_public_key, credential_bytes.as_deref(),
        )?;

        let provider = self.load_global().await?;

        let key_package_bundle = KeyPackage::builder()
            .build(cs, &provider, &signer, credential_with_key)
            .map_err(|e| format!("Failed to create key package: {}", e))?;

        let kp_bytes = key_package_bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize key package: {}", e))?;

        self.commit(provider, None).await?;

        Ok(KeyPackageResult {
            key_package_bytes: kp_bytes,
        })
    }

    /// Builds a key package, overriding the defaults `createKeyPackage` leaves
    /// alone.
    ///
    /// Every field of `KeyPackageOptions` is optional and an unset one keeps
    /// OpenMLS's default. `capabilities` is the one with a wire consequence:
    /// setting `MlsCapabilities.ciphersuites` to an explicit list of raw code
    /// points is the only way to stop a key package advertising every suite
    /// this provider supports, experimental ones included.
    pub async fn create_key_package_with_options(
        &self,
        ciphersuite: MlsCiphersuite,
        signer_bytes: Vec<u8>,
        credential_identity: Vec<u8>,
        signer_public_key: Vec<u8>,
        options: KeyPackageOptions,
        credential_bytes: Option<Vec<u8>>,
    ) -> Result<KeyPackageResult, String> {
        let cs = ciphersuite_to_native(&ciphersuite);
        let signer = signer_from_bytes(signer_bytes)?;
        let credential_with_key = build_credential_with_key(
            &credential_identity, &signer_public_key, credential_bytes.as_deref(),
        )?;

        let provider = self.load_global().await?;
        let mut builder = KeyPackage::builder();

        if let Some(lifetime_secs) = options.lifetime_seconds {
            builder = builder.key_package_lifetime(Lifetime::new(lifetime_secs));
        }
        if options.last_resort {
            builder = builder.mark_as_last_resort();
        }
        if let Some(ref caps) = options.capabilities {
            builder = builder.leaf_node_capabilities(capabilities_to_native(caps)?);
        }
        if let Some(ref leaf_exts) = options.leaf_node_extensions {
            let extensions = Extensions::from_vec(extensions_from_mls(leaf_exts))
                .map_err(|e| format!("Failed to create leaf node extensions: {}", e))?;
            builder = builder.leaf_node_extensions(extensions);
        }
        if let Some(ref kp_exts) = options.key_package_extensions {
            let extensions = Extensions::from_vec(extensions_from_mls(kp_exts))
                .map_err(|e| format!("Failed to create key package extensions: {}", e))?;
            builder = builder.key_package_extensions(extensions);
        }

        let key_package_bundle = builder
            .build(cs, &provider, &signer, credential_with_key)
            .map_err(|e| format!("Failed to create key package: {}", e))?;

        let kp_bytes = key_package_bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize key package: {}", e))?;

        self.commit(provider, None).await?;

        Ok(KeyPackageResult {
            key_package_bytes: kp_bytes,
        })
    }

    // ═══════════════════════════════════════════════════════════
    // GROUP CREATION
    // ═══════════════════════════════════════════════════════════

    pub async fn create_group(
        &self,
        config: MlsGroupConfig,
        signer_bytes: Vec<u8>,
        credential_identity: Vec<u8>,
        signer_public_key: Vec<u8>,
        group_id: Option<Vec<u8>>,
        credential_bytes: Option<Vec<u8>>,
    ) -> Result<CreateGroupResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let credential_with_key = build_credential_with_key(
            &credential_identity, &signer_public_key, credential_bytes.as_deref(),
        )?;

        let provider = self.load_global().await?;
        let create_config = config.to_create_config();

        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store signer: {}", e))?;

        let mls_group = if let Some(gid) = group_id {
            MlsGroup::new_with_group_id(
                &provider,
                &signer,
                &create_config,
                GroupId::from_slice(&gid),
                credential_with_key,
            )
        } else {
            MlsGroup::new(&provider, &signer, &create_config, credential_with_key)
        };

        let mls_group = mls_group.map_err(|e| format!("Failed to create group: {}", e))?;
        let gid = mls_group.group_id().as_slice().to_vec();

        self.commit(provider, Some(&gid)).await?;

        Ok(CreateGroupResult { group_id: gid })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create_group_with_builder(
        &self,
        config: MlsGroupConfig,
        signer_bytes: Vec<u8>,
        credential_identity: Vec<u8>,
        signer_public_key: Vec<u8>,
        group_id: Option<Vec<u8>>,
        lifetime_seconds: Option<u64>,
        group_context_extensions: Option<Vec<MlsExtension>>,
        leaf_node_extensions: Option<Vec<MlsExtension>>,
        capabilities: Option<MlsCapabilities>,
        credential_bytes: Option<Vec<u8>>,
    ) -> Result<CreateGroupResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let credential_with_key = build_credential_with_key(
            &credential_identity, &signer_public_key, credential_bytes.as_deref(),
        )?;

        let provider = self.load_global().await?;

        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store signer: {}", e))?;

        let cs = super::types::ciphersuite_to_native(&config.ciphersuite);
        let wf = super::types::wire_format_to_native(&config.wire_format_policy);

        let mut builder = MlsGroup::builder()
            .ciphersuite(cs)
            .with_wire_format_policy(wf)
            .use_ratchet_tree_extension(config.use_ratchet_tree_extension)
            .max_past_epochs(config.max_past_epochs as usize)
            .padding_size(config.padding_size as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                config.sender_ratchet_max_out_of_order,
                config.sender_ratchet_max_forward_distance,
            ));

        if let Some(gid) = group_id {
            builder = builder.with_group_id(GroupId::from_slice(&gid));
        }
        if let Some(lifetime_secs) = lifetime_seconds {
            builder = builder.lifetime(Lifetime::new(lifetime_secs));
        }
        if let Some(ref gc_exts) = group_context_extensions {
            let extensions = Extensions::from_vec(extensions_from_mls(gc_exts))
                .map_err(|e| format!("Failed to create group context extensions: {}", e))?;
            builder = builder.with_group_context_extensions(extensions);
        }
        if let Some(ref leaf_exts) = leaf_node_extensions {
            let extensions = Extensions::from_vec(extensions_from_mls(leaf_exts))
                .map_err(|e| format!("Failed to create leaf node extensions: {}", e))?;
            builder = builder
                .with_leaf_node_extensions(extensions)
                .map_err(|e| format!("Failed to set leaf node extensions: {}", e))?;
        }
        if let Some(ref caps) = capabilities {
            builder = builder.with_capabilities(capabilities_to_native(caps)?);
        }

        let mls_group = builder
            .build(&provider, &signer, credential_with_key)
            .map_err(|e| format!("Failed to create group: {}", e))?;

        let gid = mls_group.group_id().as_slice().to_vec();

        self.commit(provider, Some(&gid)).await?;

        Ok(CreateGroupResult { group_id: gid })
    }

    // ═══════════════════════════════════════════════════════════
    // JOINING A GROUP
    // ═══════════════════════════════════════════════════════════

    pub async fn join_group_from_welcome(
        &self,
        config: MlsGroupConfig,
        welcome_bytes: Vec<u8>,
        ratchet_tree_bytes: Option<Vec<u8>>,
        signer_bytes: Vec<u8>,
    ) -> Result<JoinGroupResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_global().await?;

        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store signer: {}", e))?;

        let welcome_msg = MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes)
            .map_err(|e| format!("Failed to deserialize welcome: {}", e))?;
        let welcome = match welcome_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Message is not a Welcome".to_string()),
        };

        let join_config = config.to_join_config();
        let ratchet_tree: Option<RatchetTreeIn> = ratchet_tree_bytes
            .map(|rt_bytes| {
                RatchetTreeIn::tls_deserialize_exact_bytes(&rt_bytes)
                    .map_err(|e| format!("Failed to deserialize ratchet tree: {}", e))
            })
            .transpose()?;

        let staged = StagedWelcome::new_from_welcome(&provider, &join_config, welcome, ratchet_tree)
            .map_err(|e| format!("Failed to process welcome: {}", e))?;
        let mls_group = staged
            .into_group(&provider)
            .map_err(|e| format!("Failed to join group from welcome: {}", e))?;

        let gid = mls_group.group_id().as_slice().to_vec();

        self.commit(provider, Some(&gid)).await?;

        Ok(JoinGroupResult { group_id: gid })
    }

    pub async fn join_group_from_welcome_with_options(
        &self,
        config: MlsGroupConfig,
        welcome_bytes: Vec<u8>,
        ratchet_tree_bytes: Option<Vec<u8>>,
        signer_bytes: Vec<u8>,
        skip_lifetime_validation: bool,
    ) -> Result<JoinGroupResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_global().await?;

        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store signer: {}", e))?;

        let welcome_msg = MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes)
            .map_err(|e| format!("Failed to deserialize welcome: {}", e))?;
        let welcome = match welcome_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Message is not a Welcome".to_string()),
        };

        let join_config = config.to_join_config();
        let mut join_builder = StagedWelcome::build_from_welcome(&provider, &join_config, welcome)
            .map_err(|e| format!("Failed to process welcome: {}", e))?;

        if let Some(rt_bytes) = ratchet_tree_bytes {
            let ratchet_tree = RatchetTreeIn::tls_deserialize_exact_bytes(&rt_bytes)
                .map_err(|e| format!("Failed to deserialize ratchet tree: {}", e))?;
            join_builder = join_builder.with_ratchet_tree(ratchet_tree);
        }
        if skip_lifetime_validation {
            join_builder = join_builder.skip_lifetime_validation();
        }

        let staged = join_builder
            .build()
            .map_err(|e| format!("Failed to build staged welcome: {}", e))?;
        let mls_group = staged
            .into_group(&provider)
            .map_err(|e| format!("Failed to join group from welcome: {}", e))?;

        let gid = mls_group.group_id().as_slice().to_vec();

        self.commit(provider, Some(&gid)).await?;

        Ok(JoinGroupResult { group_id: gid })
    }

    pub async fn inspect_welcome(
        &self,
        config: MlsGroupConfig,
        welcome_bytes: Vec<u8>,
    ) -> Result<WelcomeInspectResult, String> {
        let provider = self.load_global().await?;

        let welcome_msg = MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes)
            .map_err(|e| format!("Failed to deserialize welcome: {}", e))?;
        let welcome = match welcome_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Message is not a Welcome".to_string()),
        };

        let join_config = config.to_join_config();
        let processed = ProcessedWelcome::new_from_welcome(&provider, &join_config, welcome)
            .map_err(|e| format!("Failed to process welcome: {}", e))?;

        let vgi = processed.unverified_group_info();
        Ok(WelcomeInspectResult {
            group_id: vgi.group_id().as_slice().to_vec(),
            ciphersuite: native_to_ciphersuite(vgi.ciphersuite())?,
            psk_count: processed.psks().len() as u32,
            epoch: vgi.epoch().as_u64(),
        })
    }

    /// Derives a secret from the epoch a Welcome invites this client into,
    /// **without joining the group**.
    ///
    /// This is `exportSecret` one step earlier: same derivation, same
    /// `label`/`context`/`keyLength` meaning, but reachable while the
    /// invitation is still only an invitation. It is what lets a client agree
    /// a key with the inviter — or prove to a third party that it can read the
    /// epoch — before it decides whether to accept.
    ///
    /// Like `inspectWelcome`, this writes nothing, and that is load-bearing
    /// rather than incidental. Processing a Welcome consumes the key package
    /// it was addressed to: OpenMLS deletes it from storage unless it is
    /// marked last-resort. Here that delete lands in this call's snapshot and
    /// is discarded with it, because neither this function nor `inspectWelcome`
    /// commits — so a later `joinGroupFromWelcome` on the same Welcome still
    /// finds its key package. Committing from either would silently burn the
    /// invitation.
    ///
    /// The secret comes from the unverified group info in the Welcome. The
    /// confirmation tag is only checked when the Welcome is staged into a
    /// group, which happens in `joinGroupFromWelcome` and not here.
    ///
    /// It sees exactly the storage the real join sees:
    /// `joinGroupFromWelcome` loads the same global scope, and pre-shared keys
    /// live in it (they are stored ungrouped, like key packages and signature
    /// keys). So a Welcome that carries PSKs resolves them here or fails here
    /// for the same reason it would there — this function is never the narrower
    /// of the two.
    pub async fn export_welcome_secret(
        &self,
        config: MlsGroupConfig,
        welcome_bytes: Vec<u8>,
        label: String,
        context: Vec<u8>,
        key_length: u32,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_global().await?;

        let welcome_msg = MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes)
            .map_err(|e| format!("Failed to deserialize welcome: {}", e))?;
        let welcome = match welcome_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Message is not a Welcome".to_string()),
        };

        let join_config = config.to_join_config();
        let processed = ProcessedWelcome::new_from_welcome(&provider, &join_config, welcome)
            .map_err(|e| format!("Failed to process welcome: {}", e))?;

        processed
            .export_secret(provider.crypto(), &label, &context, key_length as usize)
            .map_err(|e| format!("Failed to export secret from welcome: {}", e))
    }

    #[allow(deprecated)]
    #[allow(clippy::too_many_arguments)]
    pub async fn join_group_external_commit(
        &self,
        config: MlsGroupConfig,
        group_info_bytes: Vec<u8>,
        ratchet_tree_bytes: Option<Vec<u8>>,
        signer_bytes: Vec<u8>,
        credential_identity: Vec<u8>,
        signer_public_key: Vec<u8>,
        credential_bytes: Option<Vec<u8>>,
    ) -> Result<ExternalJoinResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let credential_with_key = build_credential_with_key(
            &credential_identity, &signer_public_key, credential_bytes.as_deref(),
        )?;

        let provider = self.load_global().await?;
        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store signer: {}", e))?;

        let gi_msg = MlsMessageIn::tls_deserialize_exact_bytes(&group_info_bytes)
            .map_err(|e| format!("Failed to deserialize group info: {}", e))?;
        let verifiable_group_info = match gi_msg.extract() {
            MlsMessageBodyIn::GroupInfo(gi) => gi,
            _ => return Err("Not a GroupInfo message".to_string()),
        };
        let join_config = config.to_join_config();

        let ratchet_tree: Option<RatchetTreeIn> = ratchet_tree_bytes
            .map(|rt_bytes| {
                RatchetTreeIn::tls_deserialize_exact_bytes(&rt_bytes)
                    .map_err(|e| format!("Failed to deserialize ratchet tree: {}", e))
            })
            .transpose()?;

        let (mls_group, commit_out, group_info_opt) = MlsGroup::join_by_external_commit(
            &provider, &signer, ratchet_tree, verifiable_group_info, &join_config, None, None, &[], credential_with_key,
        )
        .map_err(|e| format!("Failed to join group via external commit: {}", e))?;

        let gid = mls_group.group_id().as_slice().to_vec();
        let commit_bytes = commit_out
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let gi_bytes = group_info_opt
            .map(|gi| gi.tls_serialize_detached())
            .transpose()
            .map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&gid)).await?;

        Ok(ExternalJoinResult {
            group_id: gid,
            commit: commit_bytes,
            group_info: gi_bytes,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn join_group_external_commit_v2(
        &self,
        config: MlsGroupConfig,
        group_info_bytes: Vec<u8>,
        ratchet_tree_bytes: Option<Vec<u8>>,
        signer_bytes: Vec<u8>,
        credential_identity: Vec<u8>,
        signer_public_key: Vec<u8>,
        aad: Option<Vec<u8>>,
        skip_lifetime_validation: bool,
        credential_bytes: Option<Vec<u8>>,
    ) -> Result<ExternalJoinResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let credential_with_key = build_credential_with_key(
            &credential_identity, &signer_public_key, credential_bytes.as_deref(),
        )?;

        let provider = self.load_global().await?;
        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store signer: {}", e))?;

        let gi_msg = MlsMessageIn::tls_deserialize_exact_bytes(&group_info_bytes)
            .map_err(|e| format!("Failed to deserialize group info: {}", e))?;
        let verifiable_group_info = match gi_msg.extract() {
            MlsMessageBodyIn::GroupInfo(gi) => gi,
            _ => return Err("Not a GroupInfo message".to_string()),
        };
        let join_config = config.to_join_config();

        let mut ext_builder = MlsGroup::external_commit_builder().with_config(join_config);
        if let Some(rt_bytes) = ratchet_tree_bytes {
            let ratchet_tree = RatchetTreeIn::tls_deserialize_exact_bytes(&rt_bytes)
                .map_err(|e| format!("Failed to deserialize ratchet tree: {}", e))?;
            ext_builder = ext_builder.with_ratchet_tree(ratchet_tree);
        }
        if let Some(aad_bytes) = aad {
            ext_builder = ext_builder.with_aad(aad_bytes);
        }
        if skip_lifetime_validation {
            ext_builder = ext_builder.skip_lifetime_validation();
        }

        let commit_builder = ext_builder
            .build_group(&provider, verifiable_group_info, credential_with_key)
            .map_err(|e| format!("Failed to build external commit group: {}", e))?;
        let commit_builder = commit_builder
            .load_psks(provider.storage())
            .map_err(|e| format!("Failed to load PSKs: {}", e))?;
        let commit_builder = commit_builder
            .build(provider.rand(), provider.crypto(), &signer, |_| true)
            .map_err(|e| format!("Failed to build external commit: {}", e))?;
        let (mls_group, bundle) = commit_builder
            .finalize(&provider)
            .map_err(|e| format!("Failed to finalize external commit: {}", e))?;

        let gid = mls_group.group_id().as_slice().to_vec();
        let (commit_out, _welcome_opt, gi_opt) = bundle.into_messages();
        let commit_bytes = commit_out
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let gi_bytes = gi_opt
            .map(|gi| gi.tls_serialize_detached())
            .transpose()
            .map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&gid)).await?;

        Ok(ExternalJoinResult {
            group_id: gid,
            commit: commit_bytes,
            group_info: gi_bytes,
        })
    }

    // ═══════════════════════════════════════════════════════════
    // STATE QUERIES (read-only)
    // ═══════════════════════════════════════════════════════════

    pub async fn group_id(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group.group_id().as_slice().to_vec())
    }

    pub async fn group_epoch(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<u64, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group.epoch().as_u64())
    }

    pub async fn group_is_active(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<bool, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group.is_active())
    }

    pub async fn group_members(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<MlsMemberInfo>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let mut members = Vec::new();
        for member in group.members() {
            let cred_bytes = member.credential
                .tls_serialize_detached()
                .map_err(|e| format!("Failed to serialize member credential: {}", e))?;
            members.push(MlsMemberInfo {
                index: member.index.u32(),
                credential: cred_bytes,
                signature_key: member.signature_key.clone(),
            });
        }
        Ok(members)
    }

    pub async fn group_ciphersuite(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<MlsCiphersuite, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        native_to_ciphersuite(group.ciphersuite())
    }

    pub async fn group_own_index(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<u32, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group.own_leaf_index().u32())
    }

    pub async fn group_credential(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let credential = group.credential().map_err(|e| format!("Failed to get credential: {}", e))?;
        credential
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize credential: {}", e))
    }

    pub async fn group_extensions(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        group
            .extensions()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize extensions: {}", e))
    }

    pub async fn group_pending_proposals(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<MlsPendingProposalInfo>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let mut proposals = Vec::new();
        for qp in group.pending_proposals() {
            let proposal_type = match qp.proposal() {
                Proposal::Add(_) => MlsProposalType::Add,
                Proposal::Remove(_) => MlsProposalType::Remove,
                Proposal::Update(_) => MlsProposalType::Update,
                Proposal::PreSharedKey(_) => MlsProposalType::PreSharedKey,
                Proposal::ReInit(_) => MlsProposalType::Reinit,
                Proposal::ExternalInit(_) => MlsProposalType::ExternalInit,
                Proposal::GroupContextExtensions(_) => MlsProposalType::GroupContextExtensions,
                _ => MlsProposalType::Custom,
            };
            let sender_index = match qp.sender() {
                Sender::Member(idx) => Some(idx.u32()),
                _ => None,
            };
            proposals.push(MlsPendingProposalInfo { proposal_type, sender_index });
        }
        Ok(proposals)
    }

    pub async fn group_has_pending_proposals(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<bool, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group.has_pending_proposals())
    }

    pub async fn group_member_at(
        &self,
        group_id_bytes: Vec<u8>,
        leaf_index: u32,
    ) -> Result<Option<MlsMemberInfo>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        match group.member_at(LeafNodeIndex::new(leaf_index)) {
            Some(member) => {
                let cred_bytes = member.credential
                    .tls_serialize_detached()
                    .map_err(|e| format!("Failed to serialize member credential: {}", e))?;
                Ok(Some(MlsMemberInfo {
                    index: member.index.u32(),
                    credential: cred_bytes,
                    signature_key: member.signature_key.clone(),
                }))
            }
            None => Ok(None),
        }
    }

    pub async fn group_member_leaf_index(
        &self,
        group_id_bytes: Vec<u8>,
        credential_bytes: Vec<u8>,
    ) -> Result<Option<u32>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let credential = Credential::tls_deserialize_exact_bytes(&credential_bytes)
            .map_err(|e| format!("Failed to deserialize credential: {}", e))?;
        Ok(group.member_leaf_index(&credential).map(|idx| idx.u32()))
    }

    // ═══════════════════════════════════════════════════════════
    // EXPORT OPERATIONS (read-only)
    // ═══════════════════════════════════════════════════════════

    pub async fn export_ratchet_tree(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        group
            .export_ratchet_tree()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize ratchet tree: {}", e))
    }

    pub async fn export_group_info(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let group_info = group
            .export_group_info(provider.crypto(), &signer, true)
            .map_err(|e| format!("Failed to export group info: {}", e))?;
        group_info
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize group info: {}", e))
    }

    pub async fn export_secret(
        &self,
        group_id_bytes: Vec<u8>,
        label: String,
        context: Vec<u8>,
        key_length: u32,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        group
            .export_secret(provider.crypto(), &label, &context, key_length as usize)
            .map_err(|e| format!("Failed to export secret: {}", e))
    }

    pub async fn export_group_context(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<MlsGroupContextInfo, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let cs = native_to_ciphersuite(group.ciphersuite())?;
        let ctx = group.public_group().group_context();
        let ext_bytes = ctx
            .extensions()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize extensions: {}", e))?;
        Ok(MlsGroupContextInfo {
            group_id: group.group_id().as_slice().to_vec(),
            epoch: group.epoch().as_u64(),
            ciphersuite: cs,
            tree_hash: ctx.tree_hash().to_vec(),
            confirmed_transcript_hash: ctx.confirmed_transcript_hash().to_vec(),
            extensions: ext_bytes,
        })
    }

    pub async fn group_confirmation_tag(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        group
            .confirmation_tag()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize confirmation tag: {}", e))
    }

    pub async fn group_own_leaf_node(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<MlsLeafNodeInfo, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let leaf = group
            .own_leaf_node()
            .ok_or_else(|| "No own leaf node (group not active?)".to_string())?;

        let cred_bytes = leaf.credential()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize credential: {}", e))?;

        let caps = leaf.capabilities();
        let capabilities = MlsCapabilities {
            versions: caps.versions().iter().map(|v| match v {
                ProtocolVersion::Mls10 => 1u16,
                ProtocolVersion::Other(n) => *n,
            }).collect(),
            ciphersuites: caps.ciphersuites().iter().map(|c| c.value()).collect(),
            extensions: caps.extensions().iter().map(|e| u16::from(*e)).collect(),
            proposals: caps.proposals().iter().map(|p| u16::from(*p)).collect(),
            credentials: caps.credentials().iter().map(|c| u16::from(*c)).collect(),
        };

        let mut extensions = Vec::new();
        for ext in leaf.extensions().iter() {
            if let Extension::Unknown(ext_type, data) = ext {
                extensions.push(MlsExtension {
                    extension_type: *ext_type,
                    data: data.0.clone(),
                });
            }
        }

        let encryption_key_bytes = leaf
            .encryption_key()
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize encryption key: {}", e))?;

        Ok(MlsLeafNodeInfo {
            credential: cred_bytes,
            signature_key: leaf.signature_key().as_slice().to_vec(),
            encryption_key: encryption_key_bytes,
            capabilities,
            extensions,
        })
    }

    pub async fn get_past_resumption_psk(
        &self,
        group_id_bytes: Vec<u8>,
        epoch: u64,
    ) -> Result<Option<Vec<u8>>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group
            .get_past_resumption_psk(GroupEpoch::from(epoch))
            .map(|psk| psk.as_slice().to_vec()))
    }

    // ═══════════════════════════════════════════════════════════
    // MEMBER MANAGEMENT (mutating)
    // ═══════════════════════════════════════════════════════════

    pub async fn add_members(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        key_packages_bytes: Vec<Vec<u8>>,
    ) -> Result<AddMembersResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let mut key_packages = Vec::with_capacity(key_packages_bytes.len());
        for kp_bytes in key_packages_bytes {
            let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(&kp_bytes)
                .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
            let kp = kp_in
                .validate(provider.crypto(), ProtocolVersion::Mls10)
                .map_err(|e| format!("Failed to validate key package: {}", e))?;
            key_packages.push(kp);
        }

        let (commit_out, welcome_out, group_info_opt) = group
            .add_members(&provider, &signer, &key_packages)
            .map_err(|e| format!("Failed to add members: {}", e))?;

        group
            .merge_pending_commit(&provider)
            .map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes = welcome_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(AddMembersResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn add_members_without_update(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        key_packages_bytes: Vec<Vec<u8>>,
    ) -> Result<AddMembersResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let mut key_packages = Vec::with_capacity(key_packages_bytes.len());
        for kp_bytes in key_packages_bytes {
            let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(&kp_bytes)
                .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
            let kp = kp_in.validate(provider.crypto(), ProtocolVersion::Mls10)
                .map_err(|e| format!("Failed to validate key package: {}", e))?;
            key_packages.push(kp);
        }

        let (commit_out, welcome_out, group_info_opt) = group
            .add_members_without_update(&provider, &signer, &key_packages)
            .map_err(|e| format!("Failed to add members without update: {}", e))?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes = welcome_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(AddMembersResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn remove_members(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        member_indices: Vec<u32>,
    ) -> Result<CommitResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let indices: Vec<LeafNodeIndex> = member_indices.iter().map(|&i| LeafNodeIndex::new(i)).collect();
        let (commit_out, welcome_opt, group_info_opt) = group
            .remove_members(&provider, &signer, &indices)
            .map_err(|e| format!("Failed to remove members: {}", e))?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: MlsMessageOut| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CommitResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn self_update(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
    ) -> Result<CommitResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let bundle = group
            .self_update(&provider, &signer, LeafNodeParameters::default())
            .map_err(|e| format!("Failed to self-update: {}", e))?;
        let (commit_out, welcome_opt, group_info_opt) = bundle.into_contents();
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: Welcome| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CommitResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn self_update_with_new_signer(
        &self,
        group_id_bytes: Vec<u8>,
        old_signer_bytes: Vec<u8>,
        new_signer_bytes: Vec<u8>,
        new_credential_identity: Vec<u8>,
        new_signer_public_key: Vec<u8>,
        new_credential_bytes: Option<Vec<u8>>,
    ) -> Result<CommitResult, String> {
        let old_signer = signer_from_bytes(old_signer_bytes)?;
        let new_signer = signer_from_bytes(new_signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        new_signer.store(provider.storage()).map_err(|e| format!("Failed to store new signer: {}", e))?;

        let credential_with_key = build_credential_with_key(
            &new_credential_identity, &new_signer_public_key, new_credential_bytes.as_deref(),
        )?;
        let new_signer_bundle = NewSignerBundle { signer: &new_signer, credential_with_key };

        let bundle = group
            .self_update_with_new_signer(&provider, &old_signer, new_signer_bundle, LeafNodeParameters::default())
            .map_err(|e| format!("Failed to self-update with new signer: {}", e))?;
        let (commit_out, welcome_opt, group_info_opt) = bundle.into_contents();
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: Welcome| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CommitResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn swap_members(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        remove_indices: Vec<u32>,
        add_key_packages_bytes: Vec<Vec<u8>>,
    ) -> Result<AddMembersResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let indices: Vec<LeafNodeIndex> = remove_indices.iter().map(|&i| LeafNodeIndex::new(i)).collect();
        let mut key_packages = Vec::with_capacity(add_key_packages_bytes.len());
        for kp_bytes in add_key_packages_bytes {
            let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(&kp_bytes)
                .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
            let kp = kp_in.validate(provider.crypto(), ProtocolVersion::Mls10)
                .map_err(|e| format!("Failed to validate key package: {}", e))?;
            key_packages.push(kp);
        }

        let result = group.swap_members(&provider, &signer, &indices, &key_packages)
            .map_err(|e| format!("Failed to swap members: {}", e))?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = result.commit.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes = result.welcome.tls_serialize_detached().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = result.group_info.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(AddMembersResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn leave_group(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
    ) -> Result<LeaveGroupResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let msg = group.leave_group(&provider, &signer).map_err(|e| format!("Failed to leave group: {}", e))?;
        let msg_bytes = msg.tls_serialize_detached().map_err(|e| format!("Failed to serialize leave message: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(LeaveGroupResult { message: msg_bytes })
    }

    pub async fn leave_group_via_self_remove(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
    ) -> Result<LeaveGroupResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let msg = group.leave_group_via_self_remove(&provider, &signer).map_err(|e| format!("Failed to leave group via self-remove: {}", e))?;
        let msg_bytes = msg.tls_serialize_detached().map_err(|e| format!("Failed to serialize leave message: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(LeaveGroupResult { message: msg_bytes })
    }

    // ═══════════════════════════════════════════════════════════
    // PROPOSALS (mutating)
    // ═══════════════════════════════════════════════════════════

    pub async fn propose_add(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        key_package_bytes: Vec<u8>,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(&key_package_bytes)
            .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
        let kp = kp_in.validate(provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|e| format!("Failed to validate key package: {}", e))?;

        let (proposal_out, _) = group.propose_add_member(&provider, &signer, &kp)
            .map_err(|e| format!("Failed to propose add: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    pub async fn propose_remove(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        member_index: u32,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let (proposal_out, _) = group.propose_remove_member(&provider, &signer, LeafNodeIndex::new(member_index))
            .map_err(|e| format!("Failed to propose remove: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    pub async fn propose_self_update(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        leaf_node_capabilities: Option<MlsCapabilities>,
        leaf_node_extensions: Option<Vec<MlsExtension>>,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let mut ln_builder = LeafNodeParameters::builder();
        if let Some(ref caps) = leaf_node_capabilities {
            ln_builder = ln_builder.with_capabilities(capabilities_to_native(caps)?);
        }
        if let Some(ref exts) = leaf_node_extensions {
            let extensions = Extensions::from_vec(extensions_from_mls(exts))
                .map_err(|e| format!("Failed to create leaf node extensions: {}", e))?;
            ln_builder = ln_builder.with_extensions(extensions);
        }
        let leaf_node_params = ln_builder.build();

        let (proposal_out, _) = group.propose_self_update(&provider, &signer, leaf_node_params)
            .map_err(|e| format!("Failed to propose self-update: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    /// Proposes a self-update that also rotates this member's signature key.
    ///
    /// The proposal form of `selfUpdateWithNewSigner`: the same key rotation,
    /// queued as a proposal instead of committed, so it can be carried by
    /// somebody else's commit.
    ///
    /// Two signers are needed because the message and its payload are
    /// authenticated against different keys. The envelope is signed with
    /// `oldSignerBytes`, since this member's leaf in the group tree still
    /// carries the old signature key at the time the proposal is sent; the new
    /// leaf inside the proposal is self-signed by `newSignerBytes` so that it
    /// verifies against the `signatureKey` it announces. Both must therefore be
    /// real key pairs with private keys.
    ///
    /// Upstream requires that a credential set in the leaf-node parameters
    /// equal the new signer's credential. This wrapper cannot violate that: it
    /// builds leaf-node parameters from `leafNodeCapabilities` and
    /// `leafNodeExtensions` only and never sets a credential there, so the
    /// credential built from `newCredentialIdentity` /
    /// `newSignerPublicKey` / `newCredentialBytes` is always the one that gets
    /// folded in.
    ///
    /// The new signer is stored before the proposal is created, matching
    /// `selfUpdateWithNewSigner`, so the key is available to sign with once the
    /// proposal is committed. Fails if a commit is already pending.
    ///
    /// Availability rests on this crate not enabling openmls's
    /// `virtual-clients-draft` feature. Upstream gates this function on
    /// `not(virtual-clients-draft)`, its own `test-utils`, or `test` — and that
    /// `test-utils` was deliberately dropped from the shipped binary in 3.0.0,
    /// so `not(virtual-clients-draft)` is the only arm holding it open here.
    #[allow(clippy::too_many_arguments)]
    pub async fn propose_self_update_with_new_signer(
        &self,
        group_id_bytes: Vec<u8>,
        old_signer_bytes: Vec<u8>,
        new_signer_bytes: Vec<u8>,
        new_credential_identity: Vec<u8>,
        new_signer_public_key: Vec<u8>,
        new_credential_bytes: Option<Vec<u8>>,
        leaf_node_capabilities: Option<MlsCapabilities>,
        leaf_node_extensions: Option<Vec<MlsExtension>>,
    ) -> Result<ProposalResult, String> {
        let old_signer = signer_from_bytes(old_signer_bytes)?;
        let new_signer = signer_from_bytes(new_signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        new_signer.store(provider.storage()).map_err(|e| format!("Failed to store new signer: {}", e))?;

        let credential_with_key = build_credential_with_key(
            &new_credential_identity, &new_signer_public_key, new_credential_bytes.as_deref(),
        )?;
        let new_signer_bundle = NewSignerBundle { signer: &new_signer, credential_with_key };

        let mut ln_builder = LeafNodeParameters::builder();
        if let Some(ref caps) = leaf_node_capabilities {
            ln_builder = ln_builder.with_capabilities(capabilities_to_native(caps)?);
        }
        if let Some(ref exts) = leaf_node_extensions {
            let extensions = Extensions::from_vec(extensions_from_mls(exts))
                .map_err(|e| format!("Failed to create leaf node extensions: {}", e))?;
            ln_builder = ln_builder.with_extensions(extensions);
        }
        let leaf_node_params = ln_builder.build();

        let (proposal_out, _) = group
            .propose_self_update_with_new_signer(&provider, &old_signer, new_signer_bundle, leaf_node_params)
            .map_err(|e| format!("Failed to propose self-update with new signer: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    pub async fn propose_external_psk(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        psk_id: Vec<u8>,
        psk_nonce: Vec<u8>,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let psk = PreSharedKeyId::external(psk_id, psk_nonce);
        let (proposal_out, _) = group.propose_pre_shared_key(&provider, &signer, psk)
            .map_err(|e| format!("Failed to propose external PSK: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    pub async fn propose_group_context_extensions(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        extensions: Vec<MlsExtension>,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let ext_vec: Vec<Extension> = extensions.iter().map(|ext| Extension::Unknown(ext.extension_type, UnknownExtension(ext.data.clone()))).collect();
        let gc_extensions = Extensions::from_vec(ext_vec).map_err(|e| format!("Failed to create extensions: {}", e))?;

        let (proposal_out, _) = group.propose_group_context_extensions(&provider, gc_extensions, &signer)
            .map_err(|e| format!("Failed to propose group context extensions: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    pub async fn propose_custom_proposal(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        proposal_type: u16,
        payload: Vec<u8>,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let custom = CustomProposal::new(proposal_type, payload);
        let (proposal_out, _) = group.propose_custom_proposal_by_reference(&provider, &signer, custom)
            .map_err(|e| format!("Failed to propose custom proposal: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    pub async fn propose_remove_member_by_credential(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        credential_bytes: Vec<u8>,
    ) -> Result<ProposalResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let credential = Credential::tls_deserialize_exact_bytes(&credential_bytes)
            .map_err(|e| format!("Failed to deserialize credential: {}", e))?;
        let (proposal_out, _) = group.propose_remove_member_by_credential(&provider, &signer, &credential)
            .map_err(|e| format!("Failed to propose remove by credential: {}", e))?;
        let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProposalResult { proposal_message: msg_bytes })
    }

    // ═══════════════════════════════════════════════════════════
    // COMMIT / MERGE OPERATIONS (mutating)
    // ═══════════════════════════════════════════════════════════

    pub async fn commit_to_pending_proposals(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
    ) -> Result<CommitResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let (commit_out, welcome_opt, group_info_opt) = group
            .commit_to_pending_proposals(&provider, &signer)
            .map_err(|e| format!("Failed to commit to pending proposals: {}", e))?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: MlsMessageOut| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CommitResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn merge_pending_commit(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    pub async fn clear_pending_commit(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        group.clear_pending_commit(provider.storage()).map_err(|e| format!("Failed to clear pending commit: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    pub async fn clear_pending_proposals(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        group.clear_pending_proposals(provider.storage()).map_err(|e| format!("Failed to clear pending proposals: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    /// Replace the group's runtime configuration.
    ///
    /// Every field of `MlsGroupConfig` is written, including the ones this
    /// call was not made for — the struct carries no "leave as is".
    ///
    /// ⚠ **This resets the past epoch deletion policy.** `maxPastEpochs` is
    /// the same setting as `setPastEpochDeletionPolicyMaxEpochs`, so passing a
    /// config here writes that number as the policy — silently undoing a
    /// `setPastEpochDeletionPolicyKeepAll` made earlier, along with the past
    /// epoch secrets the lower number no longer admits. When both are used,
    /// set the policy after the configuration, not before.
    pub async fn set_configuration(
        &self,
        group_id_bytes: Vec<u8>,
        config: MlsGroupConfig,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        let join_config = config.to_join_config();
        group.set_configuration(provider.storage(), &join_config).map_err(|e| format!("Failed to set configuration: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    pub async fn update_group_context_extensions(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        extensions: Vec<MlsExtension>,
    ) -> Result<CommitResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let ext_vec: Vec<Extension> = extensions.iter().map(|ext| Extension::Unknown(ext.extension_type, UnknownExtension(ext.data.clone()))).collect();
        let gc_extensions = Extensions::from_vec(ext_vec).map_err(|e| format!("Failed to create extensions: {}", e))?;

        let (commit_out, welcome_opt, group_info_opt) = group
            .update_group_context_extensions(&provider, gc_extensions, &signer)
            .map_err(|e| format!("Failed to update group context extensions: {}", e))?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: MlsMessageOut| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CommitResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    pub async fn flexible_commit(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        options: FlexibleCommitOptions,
    ) -> Result<CommitResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        if let Some(aad_bytes) = options.aad {
            group.set_aad(aad_bytes);
        }

        let mut commit_builder = group.commit_builder()
            .consume_proposal_store(options.consume_pending_proposals)
            .force_self_update(options.force_self_update);

        if !options.add_key_packages.is_empty() {
            let mut key_packages = Vec::with_capacity(options.add_key_packages.len());
            for kp_bytes in &options.add_key_packages {
                let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(kp_bytes)
                    .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
                let kp = kp_in.validate(provider.crypto(), ProtocolVersion::Mls10)
                    .map_err(|e| format!("Failed to validate key package: {}", e))?;
                key_packages.push(kp);
            }
            commit_builder = commit_builder.propose_adds(key_packages);
        }

        if !options.remove_indices.is_empty() {
            commit_builder = commit_builder.propose_removals(options.remove_indices.iter().map(|&i| LeafNodeIndex::new(i)));
        }

        if let Some(ref gc_exts) = options.group_context_extensions {
            let ext_vec = extensions_from_mls(gc_exts);
            let extensions = Extensions::from_vec(ext_vec).map_err(|e| format!("Failed to create group context extensions: {}", e))?;
            commit_builder = commit_builder.propose_group_context_extensions(extensions).map_err(|e| format!("Failed to propose group context extensions: {}", e))?;
        }

        let commit_builder = commit_builder.load_psks(provider.storage()).map_err(|e| format!("Failed to load PSKs: {}", e))?;
        let commit_builder = commit_builder.create_group_info(options.create_group_info).use_ratchet_tree_extension(options.use_ratchet_tree_extension);
        let commit_builder = commit_builder.build(provider.rand(), provider.crypto(), &signer, |_| true).map_err(|e| format!("Failed to build commit: {}", e))?;
        let bundle = commit_builder.stage_commit(&provider).map_err(|e| format!("Failed to stage commit: {}", e))?;
        group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

        let (commit_out, welcome_opt, gi_opt) = bundle.into_messages();
        let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
        let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
        let gi_bytes = gi_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CommitResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
    }

    // ═══════════════════════════════════════════════════════════
    // MESSAGES (mutating)
    // ═══════════════════════════════════════════════════════════

    pub async fn create_message(
        &self,
        group_id_bytes: Vec<u8>,
        signer_bytes: Vec<u8>,
        message: Vec<u8>,
        aad: Option<Vec<u8>>,
    ) -> Result<CreateMessageResult, String> {
        let signer = signer_from_bytes(signer_bytes)?;
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        if let Some(aad_bytes) = aad {
            group.set_aad(aad_bytes);
        }

        let msg_out = group.create_message(&provider, &signer, &message)
            .map_err(|e| format!("Failed to create message: {}", e))?;
        let ciphertext = msg_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize message: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(CreateMessageResult { ciphertext })
    }

    pub async fn process_message(
        &self,
        group_id_bytes: Vec<u8>,
        message_bytes: Vec<u8>,
    ) -> Result<ProcessedMessageResult, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let msg_in = MlsMessageIn::tls_deserialize_exact_bytes(&message_bytes)
            .map_err(|e| format!("Failed to deserialize message: {}", e))?;
        let protocol_msg = msg_in.try_into_protocol_message()
            .map_err(|e| format!("Not a protocol message: {}", e))?;

        let processed = group.process_message(&provider, protocol_msg)
            .map_err(|e| format!("Failed to process message: {}", e))?;

        let sender_index = match processed.sender() {
            Sender::Member(idx) => Some(idx.u32()),
            _ => None,
        };
        let epoch = group.epoch().as_u64();

        let (message_type, application_message, has_staged_commit, has_proposal, proposal_type) =
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    (ProcessedMessageType::Application, Some(app_msg.into_bytes()), false, false, None)
                }
                ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                    group.merge_staged_commit(&provider, *staged_commit)
                        .map_err(|e| format!("Failed to merge staged commit: {}", e))?;
                    (ProcessedMessageType::StagedCommit, None, true, false, None)
                }
                ProcessedMessageContent::ProposalMessage(queued_proposal) => {
                    let prop_type = match queued_proposal.proposal() {
                        Proposal::Add(_) => MlsProposalType::Add,
                        Proposal::Remove(_) => MlsProposalType::Remove,
                        Proposal::Update(_) => MlsProposalType::Update,
                        Proposal::PreSharedKey(_) => MlsProposalType::PreSharedKey,
                        Proposal::ReInit(_) => MlsProposalType::Reinit,
                        Proposal::ExternalInit(_) => MlsProposalType::ExternalInit,
                        Proposal::GroupContextExtensions(_) => MlsProposalType::GroupContextExtensions,
                        _ => MlsProposalType::Custom,
                    };
                    group.store_pending_proposal(provider.storage(), *queued_proposal)
                        .map_err(|e| format!("Failed to store pending proposal: {}", e))?;
                    (ProcessedMessageType::Proposal, None, false, true, Some(prop_type))
                }
                // openmls 0.9.0 splits two cases out of what used to be errors.
                // Neither is reachable through this engine, but naming them
                // beats reporting them as an unknown content type.
                //
                // `OwnPendingCommit` is returned only when an incoming commit
                // matches a *pending* one. Every commit-producing entry point
                // here merges before it returns, so no pending commit ever
                // survives to storage and an own commit fanned back by the
                // delivery service takes the `OwnCommitMismatch` path instead —
                // the same rejection 0.8.1 gave as `StageCommitError::OwnCommit`.
                ProcessedMessageContent::OwnPendingCommit => {
                    return Err(
                        "Own commit fanned back by the delivery service matched a pending \
                         commit; this engine merges commits when it creates them, so there \
                         is nothing left to merge"
                            .to_string(),
                    );
                }
                // `OwnPrivateMessage` replaces 0.8.1's
                // `ValidationError::CannotDecryptOwnMessage`, which that version
                // raised from `process_message` itself. Same input, same
                // outcome, different path: the own sender ratchet is
                // encryption-only, so the content cannot be read back.
                ProcessedMessageContent::OwnPrivateMessage => {
                    return Err(
                        "Cannot decrypt own message: the sender ratchet is encryption-only, \
                         so a PrivateMessage this client authored cannot be read back"
                            .to_string(),
                    );
                }
                _ => return Err("Unknown processed message content type".to_string()),
            };

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProcessedMessageResult {
            message_type, sender_index, epoch, application_message, has_staged_commit, has_proposal, proposal_type,
        })
    }

    pub async fn process_message_with_inspect(
        &self,
        group_id_bytes: Vec<u8>,
        message_bytes: Vec<u8>,
    ) -> Result<ProcessedMessageInspectResult, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;

        let msg_in = MlsMessageIn::tls_deserialize_exact_bytes(&message_bytes)
            .map_err(|e| format!("Failed to deserialize message: {}", e))?;
        let protocol_msg = msg_in.try_into_protocol_message()
            .map_err(|e| format!("Not a protocol message: {}", e))?;

        let processed = group.process_message(&provider, protocol_msg)
            .map_err(|e| format!("Failed to process message: {}", e))?;

        let sender_index = match processed.sender() {
            Sender::Member(idx) => Some(idx.u32()),
            _ => None,
        };
        let epoch = group.epoch().as_u64();

        let (message_type, application_message, staged_commit_info, proposal_type) =
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    (ProcessedMessageType::Application, Some(app_msg.into_bytes()), None, None)
                }
                ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                    let mut add_credentials = Vec::new();
                    for add in staged_commit.add_proposals() {
                        let kp = add.add_proposal().key_package();
                        let cred_bytes = kp.leaf_node().credential()
                            .tls_serialize_detached()
                            .map_err(|e| format!("Failed to serialize add credential: {}", e))?;
                        add_credentials.push(cred_bytes);
                    }
                    let remove_indices: Vec<u32> = staged_commit.remove_proposals().map(|r| r.remove_proposal().removed().u32()).collect();
                    let has_update = staged_commit.update_proposals().next().is_some();
                    let self_removed = staged_commit.self_removed();
                    let psk_count = staged_commit.psk_proposals().count() as u32;
                    let info = StagedCommitInfo { add_credentials, remove_indices, has_update, self_removed, psk_count };

                    group.merge_staged_commit(&provider, *staged_commit)
                        .map_err(|e| format!("Failed to merge staged commit: {}", e))?;
                    (ProcessedMessageType::StagedCommit, None, Some(info), None)
                }
                ProcessedMessageContent::ProposalMessage(queued_proposal) => {
                    let prop_type = match queued_proposal.proposal() {
                        Proposal::Add(_) => MlsProposalType::Add,
                        Proposal::Remove(_) => MlsProposalType::Remove,
                        Proposal::Update(_) => MlsProposalType::Update,
                        Proposal::PreSharedKey(_) => MlsProposalType::PreSharedKey,
                        Proposal::ReInit(_) => MlsProposalType::Reinit,
                        Proposal::ExternalInit(_) => MlsProposalType::ExternalInit,
                        Proposal::GroupContextExtensions(_) => MlsProposalType::GroupContextExtensions,
                        _ => MlsProposalType::Custom,
                    };
                    group.store_pending_proposal(provider.storage(), *queued_proposal)
                        .map_err(|e| format!("Failed to store pending proposal: {}", e))?;
                    (ProcessedMessageType::Proposal, None, None, Some(prop_type))
                }
                // openmls 0.9.0 splits two cases out of what used to be errors.
                // Neither is reachable through this engine, but naming them
                // beats reporting them as an unknown content type.
                //
                // `OwnPendingCommit` is returned only when an incoming commit
                // matches a *pending* one. Every commit-producing entry point
                // here merges before it returns, so no pending commit ever
                // survives to storage and an own commit fanned back by the
                // delivery service takes the `OwnCommitMismatch` path instead —
                // the same rejection 0.8.1 gave as `StageCommitError::OwnCommit`.
                ProcessedMessageContent::OwnPendingCommit => {
                    return Err(
                        "Own commit fanned back by the delivery service matched a pending \
                         commit; this engine merges commits when it creates them, so there \
                         is nothing left to merge"
                            .to_string(),
                    );
                }
                // `OwnPrivateMessage` replaces 0.8.1's
                // `ValidationError::CannotDecryptOwnMessage`, which that version
                // raised from `process_message` itself. Same input, same
                // outcome, different path: the own sender ratchet is
                // encryption-only, so the content cannot be read back.
                ProcessedMessageContent::OwnPrivateMessage => {
                    return Err(
                        "Cannot decrypt own message: the sender ratchet is encryption-only, \
                         so a PrivateMessage this client authored cannot be read back"
                            .to_string(),
                    );
                }
                _ => return Err("Unknown processed message content type".to_string()),
            };

        self.commit(provider, Some(&group_id_bytes)).await?;

        Ok(ProcessedMessageInspectResult {
            message_type, sender_index, epoch, application_message, staged_commit_info, proposal_type,
        })
    }

    // ═══════════════════════════════════════════════════════════
    // STORAGE CLEANUP (mutating)
    // ═══════════════════════════════════════════════════════════

    pub async fn delete_group(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let session = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &session)?;
        group.delete(session.storage()).map_err(|e| format!("Failed to delete group: {}", e))?;

        // One transaction for the final state and the purge of whatever rows
        // OpenMLS left behind, so a crash cannot half-delete the group.
        let OpSession { locks: _locks, provider } = session;
        let updates = provider.into_storage().into_updates();
        self.db()?
            .save_updates_and_purge_group(updates, &group_id_bytes)
            .await
    }

    pub async fn delete_key_package(
        &self,
        key_package_ref_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let provider = self.load_global().await?;
        let hash_ref = openmls::ciphersuite::hash_ref::KeyPackageRef::tls_deserialize_exact_bytes(&key_package_ref_bytes)
            .map_err(|e| format!("Failed to deserialize key package ref: {}", e))?;
        provider.storage().delete_key_package(&hash_ref)
            .map_err(|e| format!("Failed to delete key package: {}", e))?;

        self.commit(provider, None).await
    }

    // ═══════════════════════════════════════════════════════════
    // ADDITIONAL STATE QUERIES / MUTATING
    // ═══════════════════════════════════════════════════════════

    pub async fn remove_pending_proposal(
        &self,
        group_id_bytes: Vec<u8>,
        proposal_ref_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        let proposal_ref = ProposalRef::tls_deserialize_exact_bytes(&proposal_ref_bytes)
            .map_err(|e| format!("Failed to deserialize proposal ref: {}", e))?;
        group.remove_pending_proposal(provider.storage(), &proposal_ref)
            .map_err(|e| format!("Failed to remove pending proposal: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    pub async fn group_epoch_authenticator(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(group.epoch_authenticator().as_slice().to_vec())
    }

    pub async fn group_configuration(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<GroupConfigurationResult, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        let join_config = group.configuration();
        let cs = native_to_ciphersuite(group.ciphersuite())?;
        let wf = if join_config.wire_format_policy() == PURE_PLAINTEXT_WIRE_FORMAT_POLICY {
            super::types::MlsWireFormatPolicy::Plaintext
        } else {
            super::types::MlsWireFormatPolicy::Ciphertext
        };
        let sr_config = join_config.sender_ratchet_configuration();
        Ok(GroupConfigurationResult {
            ciphersuite: cs,
            wire_format_policy: wf,
            padding_size: join_config.padding_size() as u32,
            sender_ratchet_max_out_of_order: sr_config.out_of_order_tolerance(),
            sender_ratchet_max_forward_distance: sr_config.maximum_forward_distance(),
        })
    }

    // ═══════════════════════════════════════════════════════════
    // PAST EPOCH SECRETS
    // ═══════════════════════════════════════════════════════════

    /// Read how many past epochs' message secrets this group keeps.
    ///
    /// A group that was never told otherwise reports the `maxPastEpochs` its
    /// `MlsGroupConfig` carried when it was created or joined — the two are
    /// the same setting.
    pub async fn past_epoch_deletion_policy(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<PastEpochDeletionPolicyResult, String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let group = load_group(&group_id_bytes, &provider)?;
        Ok(native_to_past_epoch_policy(group.past_epoch_deletion_policy()))
    }

    /// Keep the message secrets of at most `maxEpochs` past epochs, deleting
    /// the oldest as newer ones arrive.
    ///
    /// Takes effect at once: a number below what the group already holds
    /// deletes the surplus inside this call rather than at the next commit.
    ///
    /// ⚠ Above 0 this keeps material that decrypts past traffic — see
    /// `PastEpochDeletionPolicyResult` for the trade-off. Zero, the default
    /// for a new group, keeps none.
    ///
    /// ⚠ **`setConfiguration` resets this**, because `MlsGroupConfig` carries
    /// the same setting as `maxPastEpochs`. When both are used, set the policy
    /// after the configuration, not before.
    ///
    /// Errors when `maxEpochs` is 4294967295. That one value is refused rather
    /// than stored because it is what OpenMLS writes to mean keep-all where
    /// `usize` is 32 bits — the Web and 32-bit Android — so accepting it would
    /// make two settings one stored value there and two everywhere else. Use
    /// `setPastEpochDeletionPolicyKeepAll` if that is what you mean.
    pub async fn set_past_epoch_deletion_policy_max_epochs(
        &self,
        group_id_bytes: Vec<u8>,
        max_epochs: u32,
    ) -> Result<(), String> {
        // Validated before the snapshot is loaded, so a rejected value costs no
        // database work and holds no lock.
        let policy = max_epochs_to_native(max_epochs)?;
        self.apply_past_epoch_policy(group_id_bytes, policy).await
    }

    /// Keep every past epoch's message secrets, deleting none automatically.
    ///
    /// ⚠ **Deletion becomes the application's job.** Nothing in this package
    /// removes past epoch secrets while this is set, so the group's stored
    /// state grows with every commit for as long as the group lives, and every
    /// epoch it ever had stays decryptable by anyone who obtains that store.
    /// Pair it with one of the `deletePastEpochSecrets…` methods on a schedule
    /// of your own — a retention window with
    /// `deletePastEpochSecretsOlderThan`, say — or this is a leak rather than
    /// a feature.
    ///
    /// It does not bring back what an earlier policy already discarded, and
    /// like the one above it is reset by `setConfiguration`.
    pub async fn set_past_epoch_deletion_policy_keep_all(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<(), String> {
        self.apply_past_epoch_policy(group_id_bytes, PastEpochDeletionPolicy::KeepAll)
            .await
    }

    /// Delete the message secrets of every past epoch, keeping the policy as
    /// it is.
    ///
    /// The group's current epoch is untouched: messages of the current epoch
    /// keep decrypting. Everything older stops, irreversibly.
    ///
    /// ⚠ It clears what has accumulated; it does not stop accumulation. Under
    /// `setPastEpochDeletionPolicyKeepAll` the next commit starts recording
    /// past epochs again, so this is a sweep to be repeated rather than a
    /// switch. To stop it, set a `maxEpochs` policy.
    pub async fn delete_all_past_epoch_secrets(
        &self,
        group_id_bytes: Vec<u8>,
    ) -> Result<(), String> {
        self.apply_past_epoch_deletion(group_id_bytes, PastEpochDeletion::delete_all())
            .await
    }

    /// Delete the message secrets of past epochs recorded more than `seconds`
    /// ago, keeping the policy as it is.
    ///
    /// Age is measured from when the secrets were stored, by this device's
    /// clock, not from anything in the protocol. `maxPastEpochs` additionally
    /// caps what survives at that many of the newest past epochs; omit it to
    /// apply no cap.
    ///
    /// ⚠ **Entries that carry no timestamp are skipped in silence** — the
    /// store cannot tell how old an undated one is. Such entries exist only
    /// where an application ran a version of this package built on OpenMLS
    /// 0.8.1 or earlier *and* had `maxPastEpochs` above zero, since the
    /// default records no past epochs at all; in a group that outlived that
    /// upgrade they sit alongside dated ones and a retention window built only
    /// out of this method keeps them forever.
    /// `deletePastEpochSecretsWithoutTimestamps` is the step that clears them.
    pub async fn delete_past_epoch_secrets_older_than(
        &self,
        group_id_bytes: Vec<u8>,
        seconds: u64,
        max_past_epochs: Option<u32>,
    ) -> Result<(), String> {
        self.apply_past_epoch_deletion(
            group_id_bytes,
            with_cap(
                PastEpochDeletion::older_than_duration(Duration::from_secs(seconds)),
                max_past_epochs,
            ),
        )
        .await
    }

    /// Delete the message secrets of past epochs recorded before
    /// `unixSeconds`, counted from the Unix epoch, keeping the policy as it is.
    ///
    /// `maxPastEpochs` additionally caps what survives at that many of the
    /// newest past epochs; omit it to apply no cap. Undated entries are
    /// skipped here too — see `deletePastEpochSecretsOlderThan`.
    ///
    /// ⚠ Seconds, not milliseconds. Dart offers `millisecondsSinceEpoch`
    /// first, and a present-day millisecond count is about a thousand times
    /// too large: that lands past the year 9999 and is refused here, rather
    /// than quietly deleting every past epoch the group has.
    pub async fn delete_past_epoch_secrets_before(
        &self,
        group_id_bytes: Vec<u8>,
        unix_seconds: u64,
        max_past_epochs: Option<u32>,
    ) -> Result<(), String> {
        // Validated before the snapshot is loaded — see above.
        let cutoff = unix_seconds_to_system_time(unix_seconds)?;
        self.apply_past_epoch_deletion(
            group_id_bytes,
            with_cap(PastEpochDeletion::before_timestamp(cutoff), max_past_epochs),
        )
        .await
    }

    /// Delete the message secrets of past epochs that carry no timestamp,
    /// keeping the policy as it is.
    ///
    /// This is a migration step, not an exotic option. Secrets recorded by a
    /// version of this package built on OpenMLS 0.8.1 or earlier have no
    /// timestamp, so neither `deletePastEpochSecretsOlderThan` nor
    /// `deletePastEpochSecretsBefore` will ever remove them; a deployment that
    /// keeps past epochs and has upgraded across that boundary should run this
    /// once. Where `maxPastEpochs` was left at its default of zero, no past
    /// epochs were recorded at all and there is nothing here to clear.
    ///
    /// `maxPastEpochs` additionally caps what survives at that many of the
    /// newest past epochs; omit it to apply no cap.
    pub async fn delete_past_epoch_secrets_without_timestamps(
        &self,
        group_id_bytes: Vec<u8>,
        max_past_epochs: Option<u32>,
    ) -> Result<(), String> {
        self.apply_past_epoch_deletion(
            group_id_bytes,
            with_cap(
                PastEpochDeletion::delete_all_without_timestamps(),
                max_past_epochs,
            ),
        )
        .await
    }

    /// Shared tail of the two policy setters: one load → operate → save cycle.
    async fn apply_past_epoch_policy(
        &self,
        group_id_bytes: Vec<u8>,
        policy: PastEpochDeletionPolicy,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        group
            .set_past_epoch_deletion_policy(&provider, policy)
            .map_err(|e| format!("Failed to set past epoch deletion policy: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    /// Shared tail of the four deletions: one load → operate → save cycle.
    async fn apply_past_epoch_deletion(
        &self,
        group_id_bytes: Vec<u8>,
        deletion: PastEpochDeletion,
    ) -> Result<(), String> {
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        group
            .delete_past_epoch_secrets(&provider, deletion)
            .map_err(|e| format!("Failed to delete past epoch secrets: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await
    }

    // ═══════════════════════════════════════════════════════════
    // LIFECYCLE
    // ═══════════════════════════════════════════════════════════

    /// Return the database schema version.
    ///
    /// After a successful `create()`, this is always `LATEST_SCHEMA_VERSION`.
    /// Useful for diagnostics and debugging migration issues.
    #[flutter_rust_bridge::frb(sync)]
    pub fn schema_version(&self) -> u32 {
        crate::encrypted_db::LATEST_SCHEMA_VERSION
    }

    /// Close the engine, wiping the encryption key from memory and closing the
    /// database connection. After calling this, all operations will fail with
    /// "MlsEngine is closed". Idempotent — calling close on an already-closed
    /// engine is a no-op.
    pub async fn close(&self) -> Result<(), String> {
        // Wait for any in-flight operation to finish its load → operate → save
        // sequence before tearing the connection down.
        let _op = self.op_lock.lock().await;
        let arc = { self.db.write().take() };
        match arc {
            Some(arc) => match std::sync::Arc::try_unwrap(arc) {
                Ok(db) => db.close().await,
                Err(_) => Ok(()), // In-flight operations hold the last ref; cleanup on drop
            },
            None => Ok(()), // Already closed — idempotent
        }
    }

    /// Check whether this engine has been closed.
    #[flutter_rust_bridge::frb(sync)]
    pub fn is_closed(&self) -> bool {
        self.db.read().is_none()
    }
}

// ═══════════════════════════════════════════════════════════════
// MESSAGE UTILITIES (standalone, no storage needed)
// ═══════════════════════════════════════════════════════════════

/// Extract the group ID from an MLS protocol message.
///
/// Useful for routing incoming messages to the right group before calling
/// `processMessage`. Returns an error if the message is not a protocol
/// message (i.e. it's a Welcome, GroupInfo, or KeyPackage).
#[flutter_rust_bridge::frb(sync)]
pub fn mls_message_extract_group_id(message_bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    let msg_in = MlsMessageIn::tls_deserialize_exact_bytes(&message_bytes)
        .map_err(|e| format!("Failed to deserialize message: {}", e))?;
    let protocol_msg = msg_in
        .try_into_protocol_message()
        .map_err(|e| format!("Not a protocol message: {}", e))?;
    Ok(protocol_msg.group_id().as_slice().to_vec())
}

/// Extract the epoch from an MLS protocol message.
///
/// Returns an error if the message is not a protocol message.
#[flutter_rust_bridge::frb(sync)]
pub fn mls_message_extract_epoch(message_bytes: Vec<u8>) -> Result<u64, String> {
    let msg_in = MlsMessageIn::tls_deserialize_exact_bytes(&message_bytes)
        .map_err(|e| format!("Failed to deserialize message: {}", e))?;
    let protocol_msg = msg_in
        .try_into_protocol_message()
        .map_err(|e| format!("Not a protocol message: {}", e))?;
    Ok(protocol_msg.epoch().as_u64())
}

/// Get the content type of an MLS protocol message as a string.
///
/// Returns one of: "application", "proposal", "commit".
/// Returns an error if the message is not a protocol message.
#[flutter_rust_bridge::frb(sync)]
pub fn mls_message_content_type(message_bytes: Vec<u8>) -> Result<String, String> {
    let msg_in = MlsMessageIn::tls_deserialize_exact_bytes(&message_bytes)
        .map_err(|e| format!("Failed to deserialize message: {}", e))?;
    let protocol_msg = msg_in
        .try_into_protocol_message()
        .map_err(|e| format!("Not a protocol message: {}", e))?;
    let ct = match protocol_msg.content_type() {
        ContentType::Application => "application",
        ContentType::Proposal => "proposal",
        ContentType::Commit => "commit",
    };
    Ok(ct.to_string())
}


// ═══════════════════════════════════════════════════════════════
// KEY PACKAGE UTILITIES (standalone, no storage needed)
// ═══════════════════════════════════════════════════════════════

/// The window during which a key package may be used, as seconds since the
/// Unix epoch.
pub struct KeyPackageLifetime {
    /// Start of the window. A client must not use the key package before this
    /// instant; an instant equal to it is already inside the window.
    pub not_before: u64,
    /// End of the window. A client must not use the key package at or after
    /// this instant.
    pub not_after: u64,
}

/// Whether a validity window admits some instant, and OpenMLS's reason when it
/// does not.
pub struct LifetimeVerdict {
    /// True when the instant falls inside the window.
    pub valid: bool,
    /// Why not, when `valid` is false. Null when it is true.
    pub reason: Option<String>,
}

/// Reads the validity window out of a key package.
///
/// Pair this with `checkLifetimeAt` to judge a key package by a clock other
/// than the device's — a timestamp from a server, say — before offering it to
/// `addMembers`.
///
/// ⚠ **The device's own clock still gates this call.** Getting at the window
/// means validating the key package, and OpenMLS's validation checks
/// signatures, protocol version, extensions *and* the lifetime, that last one
/// against `SystemTime::now()` on this device. There is no way to ask it to
/// skip that from outside the crate. So a key package this device believes is
/// expired, or not yet valid, fails here and never yields its bounds: the pair
/// of functions can apply an authority stricter than the local clock, not
/// rescue a package the local clock has already rejected.
#[flutter_rust_bridge::frb(sync)]
pub fn key_package_lifetime(key_package_bytes: Vec<u8>) -> Result<KeyPackageLifetime, String> {
    let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(&key_package_bytes)
        .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
    let crypto = crate::hybrid_crypto::HybridCrypto::new();
    let kp = kp_in
        .validate(&crypto, ProtocolVersion::Mls10)
        .map_err(|e| format!("Failed to validate key package: {}", e))?;
    let lifetime = kp.life_time();
    Ok(KeyPackageLifetime {
        not_before: lifetime.not_before(),
        not_after: lifetime.not_after(),
    })
}

/// The largest instant `checkLifetimeAt` accepts: 9999-12-31T23:59:59Z.
///
/// A cap is needed because the platforms disagree about what a `SystemTime`
/// can hold, and without one the same call would answer differently depending
/// on where it ran. `web_time::SystemTime` on wasm32 is a bare `Duration`
/// since the epoch — its `checked_add` is `Duration::checked_add` — so it
/// accepts every `u64` of seconds; native `std::time::SystemTime` does not,
/// and `u64::MAX` is an error there. Measured on both: the same argument was
/// a verdict on one target and an error on the other.
///
/// The cap sits where no calendar can mean a larger value rather than at any
/// platform's limit, which is what keeps it correct without a survey of the
/// platforms: rejecting past the end of year 9999 costs no caller anything,
/// and below it every target this crate builds for answers a given argument
/// the same way.
const MAX_UNIX_SECONDS: u64 = 253_402_300_799;

/// Turns a count of seconds since the Unix epoch into an instant, refusing
/// anything no calendar can mean.
///
/// Shared by every function here that takes a wall-clock instant from Dart, so
/// that they agree on the bound and on what happens past it — `checkLifetimeAt`
/// and `deletePastEpochSecrets` would otherwise each pick their own.
fn unix_seconds_to_system_time(unix_seconds: u64) -> Result<SystemTime, String> {
    if unix_seconds > MAX_UNIX_SECONDS {
        return Err(format!(
            "Not a representable instant: {} seconds after the Unix epoch is past \
             9999-12-31T23:59:59Z",
            unix_seconds
        ));
    }
    // Nothing under the cap overflows on any target this crate is built for,
    // so this arm is unreachable today. It stays because `checked_add` returns
    // an `Option` either way, and because a narrower platform added later
    // should produce an error here rather than depend on the survey above
    // still being complete.
    UNIX_EPOCH
        .checked_add(Duration::from_secs(unix_seconds))
        .ok_or_else(|| {
            format!(
                "Not a representable instant: {} seconds after the Unix epoch",
                unix_seconds
            )
        })
}

/// Checks a validity window against a supplied instant instead of this
/// device's clock.
///
/// Takes the two bounds rather than key package bytes, so that this half of
/// the check has no dependency on the local clock at all: `keyPackageLifetime`
/// is the only way to read bounds *out of* a key package and it does consult
/// the local clock, but a caller that already holds bounds — from its own
/// directory, from an earlier reading, from a server that publishes them — can
/// apply this on its own.
///
/// The comparison is OpenMLS's (`Lifetime::validate_with_time`), not a
/// re-implementation, so the boundaries match what a peer will decide about
/// the same package: `notAfter` is exclusive — an instant equal to it counts
/// as expired — while `notBefore` is inclusive.
///
/// Returns an error only when `nowUnixSeconds` names no instant a calendar
/// could mean — anything past 9999-12-31T23:59:59Z. An instant outside the
/// window is a verdict, not an error, and below that cap every platform this
/// package ships for answers a given argument the same way.
///
/// That cap also catches the likeliest way to call this wrongly. Dart has no
/// `secondsSinceEpoch`, so a caller reaching for `DateTime` meets
/// `millisecondsSinceEpoch` first, and a present-day millisecond count is
/// roughly a thousand times too large — comfortably past the cap, so it fails
/// loudly here instead of returning a confident verdict about a date tens of
/// thousands of years out.
#[flutter_rust_bridge::frb(sync)]
pub fn check_lifetime_at(
    not_before: u64,
    not_after: u64,
    now_unix_seconds: u64,
) -> Result<LifetimeVerdict, String> {
    let now = unix_seconds_to_system_time(now_unix_seconds)?;
    Ok(
        match Lifetime::init(not_before, not_after).validate_with_time(now) {
            Ok(()) => LifetimeVerdict { valid: true, reason: None },
            Err(e) => LifetimeVerdict { valid: false, reason: Some(e.to_string()) },
        },
    )
}

// ═══════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════

/// Past epoch policy conversions, run on the host *and* in the browser.
///
/// The two are not the same measurement: `usize` is 64 bits on the host and 32
/// on wasm32, and OpenMLS's encoding of the keep-all policy is written in
/// terms of `usize::MAX`. Everything here that mentions a pointer width is
/// therefore a different assertion on each target, and the browser run is the
/// only one that sees the branch the Web actually takes.
#[cfg(test)]
mod past_epoch_policy_tests {
    use super::*;

    #[cfg(target_arch = "wasm32")]
    use wasm_bindgen_test::{wasm_bindgen_test, wasm_bindgen_test_configure};

    #[cfg(target_arch = "wasm32")]
    wasm_bindgen_test_configure!(run_in_browser);

    #[cfg_attr(not(target_arch = "wasm32"), test)]
    #[cfg_attr(target_arch = "wasm32", wasm_bindgen_test)]
    fn keep_all_is_reported_however_openmls_stored_it() {
        assert!(native_to_past_epoch_policy(&PastEpochDeletionPolicy::KeepAll).keep_all);

        // The shape a 32-bit target reads back — see the test below. On the
        // host this arm is unreachable through storage, which is exactly why
        // it is asserted directly rather than left to the round trip.
        assert!(
            native_to_past_epoch_policy(&PastEpochDeletionPolicy::MaxEpochs(usize::MAX)).keep_all,
            "MaxEpochs(usize::MAX) is OpenMLS's own encoding of keep-all"
        );
    }

    #[cfg_attr(not(target_arch = "wasm32"), test)]
    #[cfg_attr(target_arch = "wasm32", wasm_bindgen_test)]
    fn the_storage_codec_preserves_keep_all_only_where_usize_is_64_bits() {
        // serde_json is the codec `SnapshotStorageProvider` writes values with,
        // so this is the round trip a stored join config really takes.
        let json = serde_json::to_string(&PastEpochDeletionPolicy::KeepAll).unwrap();
        let back: PastEpochDeletionPolicy = serde_json::from_str(&json).unwrap();

        // OpenMLS serializes KeepAll as `usize::MAX` and deserializes only
        // `u64::MAX` back into it, so the value survives on a 64-bit target and
        // lands on MaxEpochs everywhere else.
        #[cfg(target_pointer_width = "64")]
        assert_eq!(back, PastEpochDeletionPolicy::KeepAll);
        #[cfg(target_pointer_width = "32")]
        assert_eq!(back, PastEpochDeletionPolicy::MaxEpochs(usize::MAX));

        // Either way this is what Dart is told, which is the point of the
        // normalization: the surface does not change shape with the target.
        assert!(native_to_past_epoch_policy(&back).keep_all);
    }

    #[cfg_attr(not(target_arch = "wasm32"), test)]
    #[cfg_attr(target_arch = "wasm32", wasm_bindgen_test)]
    fn every_number_reported_is_one_the_setter_would_take_back() {
        // A store written by another OpenMLS application can hold a number
        // larger than anything this crate writes. Reporting it verbatim would
        // hand Dart a value its own setter refuses, so it reads as keep-all.
        assert!(native_to_past_epoch_policy(&PastEpochDeletionPolicy::MaxEpochs(
            u32::MAX as usize
        ))
        .keep_all);

        let ordinary =
            native_to_past_epoch_policy(&PastEpochDeletionPolicy::MaxEpochs(u32::MAX as usize - 1));
        assert!(!ordinary.keep_all);
        assert_eq!(ordinary.max_epochs, u32::MAX - 1);
        assert!(max_epochs_to_native(ordinary.max_epochs).is_ok());
    }

    #[cfg_attr(not(target_arch = "wasm32"), test)]
    #[cfg_attr(target_arch = "wasm32", wasm_bindgen_test)]
    fn the_one_ambiguous_number_is_refused() {
        // u32::MAX is `usize::MAX` where usize is 32 bits, so storing it would
        // be storing keep-all under another name on those targets only.
        assert!(max_epochs_to_native(u32::MAX).is_err());
        assert!(max_epochs_to_native(u32::MAX - 1).is_ok());
        assert!(max_epochs_to_native(0).is_ok());
    }
}

/// The policy against the real Web storage path.
///
/// The Dart suite covers this on native SQLCipher, where `usize` is 64 bits
/// and the keep-all encoding round-trips by itself. Only here does the
/// normalization above carry the result, and only execution can show it: a
/// wasm32 body is a different implementation of the same function.
#[cfg(all(test, target_arch = "wasm32"))]
mod past_epoch_web_tests {
    use super::*;
    use wasm_bindgen_test::{wasm_bindgen_test, wasm_bindgen_test_configure};

    wasm_bindgen_test_configure!(run_in_browser);

    #[wasm_bindgen_test]
    async fn keep_all_round_trips_through_indexeddb() {
        let name = format!("openmls_frb_policy_test_{}", js_sys::Date::now() as u64);
        let engine = MlsEngine::create(name, vec![7u8; 32])
            .await
            .expect("engine opens");

        let keys = crate::api::keys::MlsSignatureKeyPair::generate(
            MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519,
        )
        .expect("signature key pair");
        let signer = crate::api::keys::serialize_signer(
            MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519,
            keys.private_key(),
            keys.public_key(),
        )
        .expect("serialized signer");

        let group = engine
            .create_group(
                MlsGroupConfig::default_config(
                    MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519,
                ),
                signer,
                b"alice".to_vec(),
                keys.public_key(),
                None,
                None,
            )
            .await
            .expect("group is created");

        // A fresh group keeps nothing, as on native.
        let before = engine
            .past_epoch_deletion_policy(group.group_id.clone())
            .await
            .expect("policy reads back");
        assert!(!before.keep_all);
        assert_eq!(before.max_epochs, 0);

        engine
            .set_past_epoch_deletion_policy_keep_all(group.group_id.clone())
            .await
            .expect("policy is set");

        // Read back from IndexedDB, not from memory: every call reloads the
        // group. Without the normalization this is `MaxEpochs(4294967295)`.
        let after = engine
            .past_epoch_deletion_policy(group.group_id)
            .await
            .expect("policy reads back");
        assert!(
            after.keep_all,
            "keep-all must survive the Web storage round trip"
        );
    }
}
