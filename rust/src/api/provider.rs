//! Provider-based API — uses Dart storage callbacks instead of blob-based state.
//!
//! Each function accepts 3 callbacks (read, write, delete) that Dart implements
//! using any backend (SQLite, Hive, etc.). The provider persists state via these
//! callbacks, so return types omit `group_state`.
//!
//! Functions are `async` because DartFn callbacks return `DartFnFuture`.

use flutter_rust_bridge::DartFnFuture;
use openmls::prelude::*;
use openmls::prelude::tls_codec::{DeserializeBytes as TlsDeserializeBytes, Serialize as TlsSerialize};
use openmls::schedule::PreSharedKeyId;
use openmls_traits::OpenMlsProvider;

use super::config::MlsGroupConfig;
use super::keys::signer_from_bytes;
use super::types::{
    ciphersuite_to_native, native_to_ciphersuite, capabilities_to_native, extensions_from_mls,
    FlexibleCommitOptions, KeyPackageOptions, MlsCapabilities, MlsCiphersuite, MlsExtension,
    MlsGroupContextInfo, MlsLeafNodeInfo, MlsMemberInfo, MlsPendingProposalInfo, MlsProposalType,
    ProcessedMessageType, StagedCommitInfo, WelcomeInspectResult,
};
use crate::dart_storage::{DartOpenMlsProvider, DartStorageProvider};

// ═══════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════

/// Create a `DartOpenMlsProvider` from the 3 Dart callbacks.
fn make_provider(
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> DartOpenMlsProvider {
    DartOpenMlsProvider::new(DartStorageProvider::new(storage_read, storage_write, storage_delete))
}

/// Load an MlsGroup from the provider's storage.
fn load_group(group_id: &[u8], provider: &DartOpenMlsProvider) -> Result<MlsGroup, String> {
    let gid = GroupId::from_slice(group_id);
    MlsGroup::load(provider.storage(), &gid)
        .map_err(|e| format!("Failed to load group: {}", e))?
        .ok_or_else(|| "No group found in storage".to_string())
}

// ═══════════════════════════════════════════════════════════════
// RESULT TYPES (no group_state — provider persists via callbacks)
// ═══════════════════════════════════════════════════════════════

pub struct CreateGroupProviderResult {
    pub group_id: Vec<u8>,
}

pub struct JoinGroupProviderResult {
    pub group_id: Vec<u8>,
}

pub struct ExternalJoinProviderResult {
    pub group_id: Vec<u8>,
    pub commit: Vec<u8>,
    pub group_info: Option<Vec<u8>>,
}

pub struct AddMembersProviderResult {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
    pub group_info: Option<Vec<u8>>,
}

pub struct CommitProviderResult {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub group_info: Option<Vec<u8>>,
}

pub struct ProposalProviderResult {
    pub proposal_message: Vec<u8>,
}

pub struct CreateMessageProviderResult {
    pub ciphertext: Vec<u8>,
}

pub struct ProcessedMessageProviderResult {
    pub message_type: ProcessedMessageType,
    pub sender_index: Option<u32>,
    pub epoch: u64,
    pub application_message: Option<Vec<u8>>,
    pub has_staged_commit: bool,
    pub has_proposal: bool,
    pub proposal_type: Option<MlsProposalType>,
}

pub struct ProcessedMessageInspectProviderResult {
    pub message_type: ProcessedMessageType,
    pub sender_index: Option<u32>,
    pub epoch: u64,
    pub application_message: Option<Vec<u8>>,
    pub staged_commit_info: Option<StagedCommitInfo>,
    pub proposal_type: Option<MlsProposalType>,
}

pub struct KeyPackageProviderResult {
    pub key_package_bytes: Vec<u8>,
}

pub struct LeaveGroupProviderResult {
    pub message: Vec<u8>,
}

// ═══════════════════════════════════════════════════════════════
// KEY PACKAGES
// ═══════════════════════════════════════════════════════════════

pub async fn create_key_package(
    ciphersuite: MlsCiphersuite,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<KeyPackageProviderResult, String> {
    let cs = ciphersuite_to_native(&ciphersuite);
    let signer = signer_from_bytes(signer_bytes)?;
    let credential = BasicCredential::new(credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(signer_public_key),
    };

    let provider = make_provider(storage_read, storage_write, storage_delete);

    let key_package_bundle = KeyPackage::builder()
        .build(cs, &provider, &signer, credential_with_key)
        .map_err(|e| format!("Failed to create key package: {}", e))?;

    let kp_bytes = key_package_bundle
        .key_package()
        .tls_serialize_detached()
        .map_err(|e| format!("Failed to serialize key package: {}", e))?;

    Ok(KeyPackageProviderResult {
        key_package_bytes: kp_bytes,
    })
}

pub async fn create_key_package_with_options(
    ciphersuite: MlsCiphersuite,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    options: KeyPackageOptions,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<KeyPackageProviderResult, String> {
    let cs = ciphersuite_to_native(&ciphersuite);
    let signer = signer_from_bytes(signer_bytes)?;
    let credential = BasicCredential::new(credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(signer_public_key),
    };

    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(KeyPackageProviderResult {
        key_package_bytes: kp_bytes,
    })
}

// ═══════════════════════════════════════════════════════════════
// GROUP CREATION
// ═══════════════════════════════════════════════════════════════

pub async fn create_group(
    config: MlsGroupConfig,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    group_id: Option<Vec<u8>>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CreateGroupProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let credential = BasicCredential::new(credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(signer_public_key),
    };

    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(CreateGroupProviderResult { group_id: gid })
}

pub async fn create_group_with_builder(
    config: MlsGroupConfig,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    group_id: Option<Vec<u8>>,
    lifetime_seconds: Option<u64>,
    group_context_extensions: Option<Vec<MlsExtension>>,
    leaf_node_extensions: Option<Vec<MlsExtension>>,
    capabilities: Option<MlsCapabilities>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CreateGroupProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let credential = BasicCredential::new(credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(signer_public_key),
    };

    let provider = make_provider(storage_read, storage_write, storage_delete);

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

    Ok(CreateGroupProviderResult { group_id: gid })
}

// ═══════════════════════════════════════════════════════════════
// JOINING A GROUP
// ═══════════════════════════════════════════════════════════════

pub async fn join_group_from_welcome(
    config: MlsGroupConfig,
    welcome_bytes: Vec<u8>,
    ratchet_tree_bytes: Option<Vec<u8>>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<JoinGroupProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);

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
    Ok(JoinGroupProviderResult { group_id: gid })
}

pub async fn join_group_from_welcome_with_options(
    config: MlsGroupConfig,
    welcome_bytes: Vec<u8>,
    ratchet_tree_bytes: Option<Vec<u8>>,
    signer_bytes: Vec<u8>,
    skip_lifetime_validation: bool,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<JoinGroupProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);

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
    Ok(JoinGroupProviderResult { group_id: gid })
}

pub async fn inspect_welcome(
    config: MlsGroupConfig,
    welcome_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<WelcomeInspectResult, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);

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
    config: MlsGroupConfig,
    group_info_bytes: Vec<u8>,
    ratchet_tree_bytes: Option<Vec<u8>>,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ExternalJoinProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let credential = BasicCredential::new(credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(signer_public_key),
    };

    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(ExternalJoinProviderResult {
        group_id: gid,
        commit: commit_bytes,
        group_info: gi_bytes,
    })
}

pub async fn join_group_external_commit_v2(
    config: MlsGroupConfig,
    group_info_bytes: Vec<u8>,
    ratchet_tree_bytes: Option<Vec<u8>>,
    signer_bytes: Vec<u8>,
    credential_identity: Vec<u8>,
    signer_public_key: Vec<u8>,
    aad: Option<Vec<u8>>,
    skip_lifetime_validation: bool,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ExternalJoinProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let credential = BasicCredential::new(credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(signer_public_key),
    };

    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(ExternalJoinProviderResult {
        group_id: gid,
        commit: commit_bytes,
        group_info: gi_bytes,
    })
}

// ═══════════════════════════════════════════════════════════════
// STATE QUERIES
// ═══════════════════════════════════════════════════════════════

pub async fn group_id(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    Ok(group.group_id().as_slice().to_vec())
}

pub async fn group_epoch(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<u64, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    Ok(group.epoch().as_u64())
}

pub async fn group_is_active(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<bool, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    Ok(group.is_active())
}

pub async fn group_members(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<MlsMemberInfo>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<MlsCiphersuite, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    native_to_ciphersuite(group.ciphersuite())
}

pub async fn group_own_index(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<u32, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    Ok(group.own_leaf_index().u32())
}

pub async fn group_credential(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    let credential = group.credential().map_err(|e| format!("Failed to get credential: {}", e))?;
    credential
        .tls_serialize_detached()
        .map_err(|e| format!("Failed to serialize credential: {}", e))
}

pub async fn group_extensions(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    group
        .extensions()
        .tls_serialize_detached()
        .map_err(|e| format!("Failed to serialize extensions: {}", e))
}

pub async fn group_pending_proposals(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<MlsPendingProposalInfo>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<bool, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    Ok(group.has_pending_proposals())
}

pub async fn group_member_at(
    group_id_bytes: Vec<u8>,
    leaf_index: u32,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Option<MlsMemberInfo>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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
    group_id_bytes: Vec<u8>,
    credential_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Option<u32>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    let credential = Credential::tls_deserialize_exact_bytes(&credential_bytes)
        .map_err(|e| format!("Failed to deserialize credential: {}", e))?;
    Ok(group.member_leaf_index(&credential).map(|idx| idx.u32()))
}

// ═══════════════════════════════════════════════════════════════
// EXPORT OPERATIONS
// ═══════════════════════════════════════════════════════════════

pub async fn export_ratchet_tree(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    group
        .export_ratchet_tree()
        .tls_serialize_detached()
        .map_err(|e| format!("Failed to serialize ratchet tree: {}", e))
}

pub async fn export_group_info(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    let group_info = group
        .export_group_info(provider.crypto(), &signer, true)
        .map_err(|e| format!("Failed to export group info: {}", e))?;
    group_info
        .tls_serialize_detached()
        .map_err(|e| format!("Failed to serialize group info: {}", e))
}

pub async fn export_secret(
    group_id_bytes: Vec<u8>,
    label: String,
    context: Vec<u8>,
    key_length: u32,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    group
        .export_secret(provider.crypto(), &label, &context, key_length as usize)
        .map_err(|e| format!("Failed to export secret: {}", e))
}

pub async fn export_group_context(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<MlsGroupContextInfo, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Vec<u8>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    group
        .confirmation_tag()
        .tls_serialize_detached()
        .map_err(|e| format!("Failed to serialize confirmation tag: {}", e))
}

pub async fn group_own_leaf_node(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<MlsLeafNodeInfo, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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
    group_id_bytes: Vec<u8>,
    epoch: u64,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<Option<Vec<u8>>, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let group = load_group(&group_id_bytes, &provider)?;
    Ok(group
        .get_past_resumption_psk(GroupEpoch::from(epoch))
        .map(|psk| psk.as_slice().to_vec()))
}

// ═══════════════════════════════════════════════════════════════
// MEMBER MANAGEMENT
// ═══════════════════════════════════════════════════════════════

pub async fn add_members(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    key_packages_bytes: Vec<Vec<u8>>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<AddMembersProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(AddMembersProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn add_members_without_update(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    key_packages_bytes: Vec<Vec<u8>>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<AddMembersProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(AddMembersProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn remove_members(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    member_indices: Vec<u32>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CommitProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let indices: Vec<LeafNodeIndex> = member_indices.iter().map(|&i| LeafNodeIndex::new(i)).collect();
    let (commit_out, welcome_opt, group_info_opt) = group
        .remove_members(&provider, &signer, &indices)
        .map_err(|e| format!("Failed to remove members: {}", e))?;
    group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

    let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
    let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: MlsMessageOut| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
    let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

    Ok(CommitProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn self_update(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CommitProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let bundle = group
        .self_update(&provider, &signer, LeafNodeParameters::default())
        .map_err(|e| format!("Failed to self-update: {}", e))?;
    let (commit_out, welcome_opt, group_info_opt) = bundle.into_contents();
    group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

    let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
    let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: Welcome| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
    let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

    Ok(CommitProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn self_update_with_new_signer(
    group_id_bytes: Vec<u8>,
    old_signer_bytes: Vec<u8>,
    new_signer_bytes: Vec<u8>,
    new_credential_identity: Vec<u8>,
    new_signer_public_key: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CommitProviderResult, String> {
    let old_signer = signer_from_bytes(old_signer_bytes)?;
    let new_signer = signer_from_bytes(new_signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    new_signer.store(provider.storage()).map_err(|e| format!("Failed to store new signer: {}", e))?;

    let credential = BasicCredential::new(new_credential_identity);
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: SignaturePublicKey::from(new_signer_public_key),
    };
    let new_signer_bundle = NewSignerBundle { signer: &new_signer, credential_with_key };

    let bundle = group
        .self_update_with_new_signer(&provider, &old_signer, new_signer_bundle, LeafNodeParameters::default())
        .map_err(|e| format!("Failed to self-update with new signer: {}", e))?;
    let (commit_out, welcome_opt, group_info_opt) = bundle.into_contents();
    group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

    let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
    let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: Welcome| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
    let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

    Ok(CommitProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn swap_members(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    remove_indices: Vec<u32>,
    add_key_packages_bytes: Vec<Vec<u8>>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<AddMembersProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(AddMembersProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn leave_group(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<LeaveGroupProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let msg = group.leave_group(&provider, &signer).map_err(|e| format!("Failed to leave group: {}", e))?;
    let msg_bytes = msg.tls_serialize_detached().map_err(|e| format!("Failed to serialize leave message: {}", e))?;

    Ok(LeaveGroupProviderResult { message: msg_bytes })
}

pub async fn leave_group_via_self_remove(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<LeaveGroupProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let msg = group.leave_group_via_self_remove(&provider, &signer).map_err(|e| format!("Failed to leave group via self-remove: {}", e))?;
    let msg_bytes = msg.tls_serialize_detached().map_err(|e| format!("Failed to serialize leave message: {}", e))?;

    Ok(LeaveGroupProviderResult { message: msg_bytes })
}

// ═══════════════════════════════════════════════════════════════
// PROPOSALS
// ═══════════════════════════════════════════════════════════════

pub async fn propose_add(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    key_package_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let kp_in = KeyPackageIn::tls_deserialize_exact_bytes(&key_package_bytes)
        .map_err(|e| format!("Failed to deserialize key package: {}", e))?;
    let kp = kp_in.validate(provider.crypto(), ProtocolVersion::Mls10)
        .map_err(|e| format!("Failed to validate key package: {}", e))?;

    let (proposal_out, _) = group.propose_add_member(&provider, &signer, &kp)
        .map_err(|e| format!("Failed to propose add: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

pub async fn propose_remove(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    member_index: u32,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let (proposal_out, _) = group.propose_remove_member(&provider, &signer, LeafNodeIndex::new(member_index))
        .map_err(|e| format!("Failed to propose remove: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

pub async fn propose_self_update(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let (proposal_out, _) = group.propose_self_update(&provider, &signer, LeafNodeParameters::default())
        .map_err(|e| format!("Failed to propose self-update: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

pub async fn propose_external_psk(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    psk_id: Vec<u8>,
    psk_nonce: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let psk = PreSharedKeyId::external(psk_id, psk_nonce);
    let (proposal_out, _) = group.propose_external_psk(&provider, &signer, psk)
        .map_err(|e| format!("Failed to propose external PSK: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

pub async fn propose_group_context_extensions(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    extensions: Vec<MlsExtension>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let ext_vec: Vec<Extension> = extensions.iter().map(|ext| Extension::Unknown(ext.extension_type, UnknownExtension(ext.data.clone()))).collect();
    let gc_extensions = Extensions::from_vec(ext_vec).map_err(|e| format!("Failed to create extensions: {}", e))?;

    let (proposal_out, _) = group.propose_group_context_extensions(&provider, gc_extensions, &signer)
        .map_err(|e| format!("Failed to propose group context extensions: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

pub async fn propose_custom_proposal(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    proposal_type: u16,
    payload: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let custom = CustomProposal::new(proposal_type, payload);
    let (proposal_out, _) = group.propose_custom_proposal_by_reference(&provider, &signer, custom)
        .map_err(|e| format!("Failed to propose custom proposal: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

pub async fn propose_remove_member_by_credential(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    credential_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProposalProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let credential = Credential::tls_deserialize_exact_bytes(&credential_bytes)
        .map_err(|e| format!("Failed to deserialize credential: {}", e))?;
    let (proposal_out, _) = group.propose_remove_member_by_credential(&provider, &signer, &credential)
        .map_err(|e| format!("Failed to propose remove by credential: {}", e))?;
    let msg_bytes = proposal_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize proposal: {}", e))?;

    Ok(ProposalProviderResult { proposal_message: msg_bytes })
}

// ═══════════════════════════════════════════════════════════════
// COMMIT / MERGE OPERATIONS
// ═══════════════════════════════════════════════════════════════

pub async fn commit_to_pending_proposals(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CommitProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    let (commit_out, welcome_opt, group_info_opt) = group
        .commit_to_pending_proposals(&provider, &signer)
        .map_err(|e| format!("Failed to commit to pending proposals: {}", e))?;
    group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))?;

    let commit_bytes = commit_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize commit: {}", e))?;
    let welcome_bytes: Option<Vec<u8>> = welcome_opt.map(|w: MlsMessageOut| w.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize welcome: {}", e))?;
    let gi_bytes = group_info_opt.map(|gi| gi.tls_serialize_detached()).transpose().map_err(|e| format!("Failed to serialize group info: {}", e))?;

    Ok(CommitProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn merge_pending_commit(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;
    group.merge_pending_commit(&provider).map_err(|e| format!("Failed to merge pending commit: {}", e))
}

pub async fn clear_pending_commit(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;
    group.clear_pending_commit(provider.storage()).map_err(|e| format!("Failed to clear pending commit: {}", e))
}

pub async fn clear_pending_proposals(
    group_id_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;
    group.clear_pending_proposals(provider.storage()).map_err(|e| format!("Failed to clear pending proposals: {}", e))
}

pub async fn set_configuration(
    group_id_bytes: Vec<u8>,
    config: MlsGroupConfig,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;
    let join_config = config.to_join_config();
    group.set_configuration(provider.storage(), &join_config).map_err(|e| format!("Failed to set configuration: {}", e))
}

pub async fn update_group_context_extensions(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    extensions: Vec<MlsExtension>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CommitProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(CommitProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

pub async fn flexible_commit(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    options: FlexibleCommitOptions,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CommitProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(CommitProviderResult { commit: commit_bytes, welcome: welcome_bytes, group_info: gi_bytes })
}

// ═══════════════════════════════════════════════════════════════
// MESSAGES
// ═══════════════════════════════════════════════════════════════

pub async fn create_message(
    group_id_bytes: Vec<u8>,
    signer_bytes: Vec<u8>,
    message: Vec<u8>,
    aad: Option<Vec<u8>>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<CreateMessageProviderResult, String> {
    let signer = signer_from_bytes(signer_bytes)?;
    let provider = make_provider(storage_read, storage_write, storage_delete);
    let mut group = load_group(&group_id_bytes, &provider)?;

    if let Some(aad_bytes) = aad {
        group.set_aad(aad_bytes);
    }

    let msg_out = group.create_message(&provider, &signer, &message)
        .map_err(|e| format!("Failed to create message: {}", e))?;
    let ciphertext = msg_out.tls_serialize_detached().map_err(|e| format!("Failed to serialize message: {}", e))?;

    Ok(CreateMessageProviderResult { ciphertext })
}

pub async fn process_message(
    group_id_bytes: Vec<u8>,
    message_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProcessedMessageProviderResult, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(ProcessedMessageProviderResult {
        message_type, sender_index, epoch, application_message, has_staged_commit, has_proposal, proposal_type,
    })
}

pub async fn process_message_with_inspect(
    group_id_bytes: Vec<u8>,
    message_bytes: Vec<u8>,
    storage_read: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    storage_write: impl Fn(Vec<u8>, Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
    storage_delete: impl Fn(Vec<u8>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<ProcessedMessageInspectProviderResult, String> {
    let provider = make_provider(storage_read, storage_write, storage_delete);
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

    Ok(ProcessedMessageInspectProviderResult {
        message_type, sender_index, epoch, application_message, staged_commit_info, proposal_type,
    })
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
