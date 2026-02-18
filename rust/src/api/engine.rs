//! Engine-based API — uses Rust-owned encrypted DB instead of Dart callbacks.
//!
//! `MlsEngine` wraps an `EncryptedDb` and provides all MLS operations as
//! async methods. Storage is managed entirely in Rust — Dart never sees raw
//! key-value data.
//!
//! Functions are `async` because DB I/O is async (SQLCipher on native,
//! IndexedDB on WASM).

use openmls::prelude::*;
use openmls::prelude::tls_codec::{DeserializeBytes as TlsDeserializeBytes, Serialize as TlsSerialize};
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
fn load_group(group_id: &[u8], provider: &SnapshotOpenMlsProvider) -> Result<MlsGroup, String> {
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
// MLS ENGINE
// ═══════════════════════════════════════════════════════════════

pub struct MlsEngine {
    db: parking_lot::RwLock<Option<std::sync::Arc<crate::encrypted_db::EncryptedDb>>>,
}

impl MlsEngine {
    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /// Create a new MlsEngine backed by an encrypted database.
    ///
    /// # Arguments
    ///
    /// * `db_path` — Database location.
    ///   - **Native**: file path for SQLCipher (e.g. `"path/to/mls.db"`).
    ///     Use `":memory:"` for an ephemeral in-memory database (destroyed on drop,
    ///     useful for tests).
    ///   - **WASM**: IndexedDB database name (e.g. `"mls_account_123"`).
    ///     `":memory:"` generates a unique random name per instance to match the
    ///     native ephemeral behavior.
    ///   - Tip: include an account identifier in the path to isolate data per user
    ///     (e.g. `"mls_{account_id}.db"` on native, `"mls_{account_id}"` on web).
    ///
    /// * `encryption_key` — 32-byte AES-256 key that protects data at rest.
    ///   The caller is responsible for generating, storing, and providing this key.
    ///   Recommended pattern: generate a random key on first launch and persist it
    ///   in platform secure storage (e.g. Keychain on iOS/macOS, Android Keystore,
    ///   or `flutter_secure_storage`).
    pub async fn create(db_path: String, encryption_key: Vec<u8>) -> Result<MlsEngine, String> {
        let db = crate::encrypted_db::EncryptedDb::open(db_path, encryption_key).await?;
        Ok(MlsEngine { db: parking_lot::RwLock::new(Some(std::sync::Arc::new(db))) })
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    fn db(&self) -> Result<std::sync::Arc<crate::encrypted_db::EncryptedDb>, String> {
        self.db.read().as_ref().cloned().ok_or_else(|| "MlsEngine is closed".to_string())
    }

    async fn load_for_group(&self, group_id: &[u8]) -> Result<SnapshotOpenMlsProvider, String> {
        let entries = self.db()?.load_for_group(group_id).await?;
        Ok(SnapshotOpenMlsProvider::new(SnapshotStorageProvider::from_entries(entries)))
    }

    async fn load_global(&self) -> Result<SnapshotOpenMlsProvider, String> {
        let entries = self.db()?.load_global().await?;
        Ok(SnapshotOpenMlsProvider::new(SnapshotStorageProvider::from_entries(entries)))
    }

    async fn commit(&self, provider: SnapshotOpenMlsProvider, group_id: Option<&[u8]>) -> Result<(), String> {
        let updates = provider.into_storage().into_updates();
        if updates.upserts.is_empty() && updates.deletes.is_empty() {
            return Ok(());
        }
        self.db()?.save_updates(updates, group_id).await
    }

    // ═══════════════════════════════════════════════════════════
    // KEY PACKAGES
    // ═══════════════════════════════════════════════════════════

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

    #[allow(deprecated)]
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
        let ctx = group.export_group_context();
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
        let (proposal_out, _) = group.propose_external_psk(&provider, &signer, psk)
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
        let provider = self.load_for_group(&group_id_bytes).await?;
        let mut group = load_group(&group_id_bytes, &provider)?;
        group.delete(provider.storage()).map_err(|e| format!("Failed to delete group: {}", e))?;

        self.commit(provider, Some(&group_id_bytes)).await?;
        self.db()?.delete_group(&group_id_bytes).await
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
/// `process_message`. Returns an error if the message is not a protocol
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
