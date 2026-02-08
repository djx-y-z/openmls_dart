//! Shared enums and value types for the OpenMLS FRB API.

use openmls::prelude::*;

/// MLS ciphersuite selection.
pub enum MlsCiphersuite {
    Mls128DhkemX25519Aes128gcmSha256Ed25519,
    Mls128DhkemX25519Chacha20poly1305Sha256Ed25519,
    Mls128DhkemP256Aes128gcmSha256P256,
}

/// Wire format policy for MLS messages.
pub enum MlsWireFormatPolicy {
    Plaintext,
    Ciphertext,
}

/// Type of a processed incoming message.
pub enum ProcessedMessageType {
    Application,
    Proposal,
    StagedCommit,
}

/// MLS proposal types.
pub enum MlsProposalType {
    Add,
    Remove,
    Update,
    PreSharedKey,
    Reinit,
    ExternalInit,
    GroupContextExtensions,
    Custom,
}

/// Information about a group member.
pub struct MlsMemberInfo {
    pub index: u32,
    /// TLS-serialized Credential. Deserialize with `MlsCredential.deserialize()`.
    pub credential: Vec<u8>,
    pub signature_key: Vec<u8>,
}

/// An MLS extension (type + data).
pub struct MlsExtension {
    pub extension_type: u16,
    pub data: Vec<u8>,
}

/// Information about a pending proposal in the group.
pub struct MlsPendingProposalInfo {
    /// The type of proposal.
    pub proposal_type: MlsProposalType,
    /// Sender's leaf index (if sender is a group member).
    pub sender_index: Option<u32>,
}

/// Capabilities advertised by a leaf node.
///
/// All fields are lists of u16 values representing the supported types.
/// Empty lists mean "use defaults".
pub struct MlsCapabilities {
    /// Supported protocol versions (1 = MLS 1.0).
    pub versions: Vec<u16>,
    /// Supported ciphersuites.
    pub ciphersuites: Vec<u16>,
    /// Supported extension types.
    pub extensions: Vec<u16>,
    /// Supported proposal types.
    pub proposals: Vec<u16>,
    /// Supported credential types.
    pub credentials: Vec<u16>,
}

/// Options for creating a key package with the builder API.
pub struct KeyPackageOptions {
    /// Lifetime in seconds. None = default (90 days).
    pub lifetime_seconds: Option<u64>,
    /// Mark as last-resort key package.
    pub last_resort: bool,
    /// Custom capabilities. None = defaults.
    pub capabilities: Option<MlsCapabilities>,
    /// Extensions on the leaf node.
    pub leaf_node_extensions: Option<Vec<MlsExtension>>,
    /// Extensions on the key package itself.
    pub key_package_extensions: Option<Vec<MlsExtension>>,
}

/// Information extracted from a Welcome message before joining.
pub struct WelcomeInspectResult {
    /// The group ID the Welcome is for.
    pub group_id: Vec<u8>,
    /// The ciphersuite used by the group.
    pub ciphersuite: MlsCiphersuite,
    /// Number of PSKs required to join.
    pub psk_count: u32,
    /// The group epoch at time of Welcome.
    pub epoch: u64,
}

/// Full information about the own leaf node.
pub struct MlsLeafNodeInfo {
    /// TLS-serialized Credential. Deserialize with `MlsCredential.deserialize()`.
    pub credential: Vec<u8>,
    pub signature_key: Vec<u8>,
    pub encryption_key: Vec<u8>,
    pub capabilities: MlsCapabilities,
    pub extensions: Vec<MlsExtension>,
}

/// Full group context information.
pub struct MlsGroupContextInfo {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub ciphersuite: MlsCiphersuite,
    pub tree_hash: Vec<u8>,
    pub confirmed_transcript_hash: Vec<u8>,
    pub extensions: Vec<u8>,
}

/// Information about a staged commit before merging.
pub struct StagedCommitInfo {
    /// TLS-serialized Credentials of members being added.
    pub add_credentials: Vec<Vec<u8>>,
    /// Leaf indices of members being removed.
    pub remove_indices: Vec<u32>,
    /// Whether a self-update is included.
    pub has_update: bool,
    /// Whether the local member was removed.
    pub self_removed: bool,
    /// Number of PSK proposals.
    pub psk_count: u32,
}

/// Options for the flexible commit builder.
pub struct FlexibleCommitOptions {
    /// TLS-serialized KeyPackages to add.
    pub add_key_packages: Vec<Vec<u8>>,
    /// Leaf indices to remove.
    pub remove_indices: Vec<u32>,
    /// Force a self-update even if no other proposals.
    pub force_self_update: bool,
    /// Whether to consume pending proposals from the store (default: true).
    pub consume_pending_proposals: bool,
    /// Group context extensions to propose.
    pub group_context_extensions: Option<Vec<MlsExtension>>,
    /// Additional authenticated data.
    pub aad: Option<Vec<u8>>,
    /// Whether to create a GroupInfo message (default: true).
    pub create_group_info: bool,
    /// Whether to include the ratchet tree extension in GroupInfo.
    pub use_ratchet_tree_extension: bool,
}

// ═══════════════════════════════════════════════════════════════
// Conversion helpers
// ═══════════════════════════════════════════════════════════════

pub(crate) fn ciphersuite_to_native(cs: &MlsCiphersuite) -> Ciphersuite {
    match cs {
        MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519 => {
            Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519
        }
        MlsCiphersuite::Mls128DhkemX25519Chacha20poly1305Sha256Ed25519 => {
            Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519
        }
        MlsCiphersuite::Mls128DhkemP256Aes128gcmSha256P256 => {
            Ciphersuite::MLS_128_DHKEMP256_AES128GCM_SHA256_P256
        }
    }
}

pub(crate) fn native_to_ciphersuite(cs: Ciphersuite) -> Result<MlsCiphersuite, String> {
    match cs {
        Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519 => {
            Ok(MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519)
        }
        Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519 => {
            Ok(MlsCiphersuite::Mls128DhkemX25519Chacha20poly1305Sha256Ed25519)
        }
        Ciphersuite::MLS_128_DHKEMP256_AES128GCM_SHA256_P256 => {
            Ok(MlsCiphersuite::Mls128DhkemP256Aes128gcmSha256P256)
        }
        _ => Err(format!("Unsupported ciphersuite: {:?}", cs)),
    }
}

pub(crate) fn wire_format_to_native(wf: &MlsWireFormatPolicy) -> WireFormatPolicy {
    match wf {
        MlsWireFormatPolicy::Plaintext => PURE_PLAINTEXT_WIRE_FORMAT_POLICY,
        MlsWireFormatPolicy::Ciphertext => PURE_CIPHERTEXT_WIRE_FORMAT_POLICY,
    }
}

pub(crate) fn capabilities_to_native(caps: &MlsCapabilities) -> Result<Capabilities, String> {
    let versions: Option<Vec<ProtocolVersion>> = if caps.versions.is_empty() {
        None
    } else {
        Some(caps.versions.iter().map(|&v| ProtocolVersion::from(v)).collect())
    };
    let ciphersuites: Option<Vec<Ciphersuite>> = if caps.ciphersuites.is_empty() {
        None
    } else {
        let cs: Result<Vec<_>, _> = caps.ciphersuites
            .iter()
            .map(|&c| Ciphersuite::try_from(c).map_err(|e| format!("Invalid ciphersuite {}: {}", c, e)))
            .collect();
        Some(cs?)
    };
    let extensions: Option<Vec<ExtensionType>> = if caps.extensions.is_empty() {
        None
    } else {
        Some(caps.extensions.iter().map(|&e| ExtensionType::from(e)).collect())
    };
    let proposals: Option<Vec<ProposalType>> = if caps.proposals.is_empty() {
        None
    } else {
        Some(caps.proposals.iter().map(|&p| ProposalType::from(p)).collect())
    };
    let credentials: Option<Vec<CredentialType>> = if caps.credentials.is_empty() {
        None
    } else {
        Some(caps.credentials.iter().map(|&c| CredentialType::from(c)).collect())
    };

    Ok(Capabilities::new(
        versions.as_deref(),
        ciphersuites.as_deref(),
        extensions.as_deref(),
        proposals.as_deref(),
        credentials.as_deref(),
    ))
}

pub(crate) fn extensions_from_mls(exts: &[MlsExtension]) -> Vec<Extension> {
    exts.iter()
        .map(|ext| Extension::Unknown(ext.extension_type, UnknownExtension(ext.data.clone())))
        .collect()
}

/// Returns the list of supported ciphersuites.
#[flutter_rust_bridge::frb(sync)]
pub fn supported_ciphersuites() -> Vec<MlsCiphersuite> {
    vec![
        MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519,
        MlsCiphersuite::Mls128DhkemX25519Chacha20poly1305Sha256Ed25519,
        MlsCiphersuite::Mls128DhkemP256Aes128gcmSha256P256,
    ]
}
