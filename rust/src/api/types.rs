//! Shared enums and value types for the OpenMLS FRB API.

use openmls::prelude::*;

/// MLS ciphersuite selection.
///
/// The first three variants are the IANA-registered MLS 1.0 ciphersuites
/// (RFC 9420 §17.1) and are the right choice for interoperable deployments.
///
/// # The post-quantum suites are experimental
///
/// Every other variant is a post-quantum or hybrid suite taken from
/// [draft-ietf-mls-pq-ciphersuites][draft] — or, for
/// `mls256XwingChacha20Poly1305Sha256Ed25519`, from an expired individual
/// draft. They share these limitations, and each carries the full warning on
/// its own documentation:
///
/// - **The code points are provisional and not registered with IANA.** They may
///   be renumbered or withdrawn. The numeric value is stated on each variant so
///   that a future renumbering is visible in a diff rather than silent.
/// - **Interoperability is limited** to stacks implementing the same draft
///   revision — in practice, OpenMLS-based ones.
/// - **Groups created on these suites may need migrating** once an official
///   IANA-registered post-quantum suite is standardized.
/// - The underlying ML-KEM / ML-DSA / X-Wing implementations are pre-1.0.
///
/// [draft]: https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites
pub enum MlsCiphersuite {
    /// DH KEM X25519 | AES-GCM 128 | SHA2-256 | Ed25519 (0x0001).
    ///
    /// IANA-registered, RFC 9420. The recommended default.
    Mls128DhkemX25519Aes128gcmSha256Ed25519,
    /// DH KEM X25519 | ChaCha20Poly1305 | SHA2-256 | Ed25519 (0x0003).
    ///
    /// IANA-registered, RFC 9420.
    Mls128DhkemX25519Chacha20poly1305Sha256Ed25519,
    /// DH KEM P-256 | AES-GCM 128 | SHA2-256 | ECDSA P-256 (0x0002).
    ///
    /// IANA-registered, RFC 9420.
    Mls128DhkemP256Aes128gcmSha256P256,
    /// **Experimental** hybrid post-quantum ciphersuite based on the X-Wing
    /// KEM (ML-KEM-768 + X25519, draft-connolly-cfrg-xwing-kem-06).
    ///
    /// Provides protection against harvest-now-decrypt-later attacks within
    /// closed deployments. Important limitations:
    ///
    /// - The ciphersuite value (0x004D) is **not registered with IANA** and
    ///   comes from an expired individual draft. Interoperability is limited
    ///   to OpenMLS-based stacks (and ts-mls).
    /// - When an official IANA-registered post-quantum suite is standardized,
    ///   groups using this suite will need to migrate to it.
    /// - The underlying libcrux KEM implementation is pre-1.0 (its ML-KEM
    ///   source is formally verified, but compiled executables carry no
    ///   side-channel-resistance verification).
    ///
    /// This is the only suite whose HPKE operations are delegated to the
    /// libcrux provider; every other suite runs on RustCrypto.
    Mls256XwingChacha20poly1305Sha256Ed25519,

    // ---------------------------------------------------------------------
    // draft-ietf-mls-pq-ciphersuites. Appended, never reordered: these values
    // cross the FFI boundary by index, so the four above must keep theirs.
    // ---------------------------------------------------------------------
    /// **Experimental** ML-KEM-1024 | AES-GCM 256 | SHA2-384 | ECDSA P-384
    /// (0x0042, provisional TBD8).
    ///
    /// Pure post-quantum KEM with a classical signature — no hybrid KEM, so it
    /// carries no classical fallback if ML-KEM is broken. Provisional code
    /// point; see the type-level documentation.
    Mls192Mlkem1024Aes256gcmSha384P384,
    /// **Experimental** ML-KEM-768 + X25519 | AES-GCM 256 | SHA2-384 | Ed25519
    /// (0x004E, provisional TBD2).
    ///
    /// Hybrid KEM (the same construction as X-Wing) with a classical signature.
    /// Provisional code point; see the type-level documentation.
    Mls128Mlkem768x25519Aes256gcmSha384Ed25519,
    /// **Experimental** ML-KEM-768 + X25519 | AES-GCM 128 | SHA2-256 | Ed25519
    /// (0x004F, provisional TBD1).
    ///
    /// Hybrid KEM (the same construction as X-Wing) with a classical signature.
    /// Provisional code point; see the type-level documentation.
    Mls128Mlkem768x25519Aes128gcmSha256Ed25519,
    /// **Experimental** ML-KEM-768 | AES-GCM 256 | SHA2-384 | ECDSA P-256
    /// (0x0050, provisional TBD7).
    ///
    /// Pure post-quantum KEM with a classical signature — no hybrid KEM, so it
    /// carries no classical fallback if ML-KEM is broken. Provisional code
    /// point; see the type-level documentation.
    Mls128Mlkem768Aes256gcmSha384P256,
    /// **Experimental** ML-KEM-768 | AES-GCM 256 | SHA2-384 | ML-DSA-65
    /// (0x0051, provisional TBD10).
    ///
    /// Post-quantum KEM *and* signature — no classical fallback in either.
    /// Provisional code point; see the type-level documentation.
    Mls192Mlkem768Aes256gcmSha384Mldsa65,
    /// **Experimental** ML-KEM-768 + X25519 | ChaCha20Poly1305 | SHA2-384 |
    /// ML-DSA-44 (0x0052, provisional TBD9).
    ///
    /// Hybrid KEM (the same construction as X-Wing) with a post-quantum
    /// signature. Provisional code point; see the type-level documentation.
    Mls128Mlkem768x25519Chacha20poly1305Sha384Mldsa44,
    /// **Experimental** ML-KEM-1024 | AES-GCM 256 | SHA2-512 | ML-DSA-87
    /// (0x0906, provisional).
    ///
    /// The strongest suite offered: post-quantum KEM *and* signature at the
    /// 256-bit security level — and correspondingly the largest key material
    /// and the slowest. No classical fallback in either primitive. Provisional
    /// code point; see the type-level documentation.
    Mls256Mlkem1024Aes256gcmSha512Mldsa87,
    /// **Experimental** ML-KEM-1024 | AES-GCM 256 | SHA2-384 | ML-DSA-87
    /// (0x0907, provisional TBD11).
    ///
    /// As `mls256Mlkem1024Aes256GcmSha512Mldsa87` but with SHA2-384.
    /// Post-quantum KEM *and* signature; no classical fallback in either.
    /// Provisional code point; see the type-level documentation.
    Mls256Mlkem1024Aes256gcmSha384Mldsa87,
    /// **Experimental** ML-KEM-768 | AES-GCM 256 | SHA2-384 | Ed25519
    /// (0xF042, provisional TBD6).
    ///
    /// Pure post-quantum KEM with a classical signature — no hybrid KEM, so it
    /// carries no classical fallback if ML-KEM is broken. The code point sits
    /// in the private-use range and is carried over from the former
    /// `AIR_128_MLKEM768_AES256GCM_SHA384_Ed25519` suite for backwards
    /// compatibility. Provisional; see the type-level documentation.
    Mls128Mlkem768Aes256gcmSha384Ed25519,
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
    /// Supported ciphersuites, as raw MLS code points.
    ///
    /// An **empty** list is not "advertise nothing" — it means "use OpenMLS's
    /// defaults", which is every ciphersuite `supportedCiphersuites`
    /// returns, ten of them experimental post-quantum suites. To advertise a
    /// narrower set, list the code points explicitly (e.g. `[0x0001, 0x0002,
    /// 0x0003]` for the IANA-registered MLS 1.0 suites only).
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
    /// Lifetime in seconds. None = default (84 days).
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
        MlsCiphersuite::Mls256XwingChacha20poly1305Sha256Ed25519 => {
            Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519
        }
        MlsCiphersuite::Mls192Mlkem1024Aes256gcmSha384P384 => {
            Ciphersuite::MLS_192_MLKEM1024_AES256GCM_SHA384_P384
        }
        MlsCiphersuite::Mls128Mlkem768x25519Aes256gcmSha384Ed25519 => {
            Ciphersuite::MLS_128_MLKEM768X25519_AES256GCM_SHA384_Ed25519
        }
        MlsCiphersuite::Mls128Mlkem768x25519Aes128gcmSha256Ed25519 => {
            Ciphersuite::MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519
        }
        MlsCiphersuite::Mls128Mlkem768Aes256gcmSha384P256 => {
            Ciphersuite::MLS_128_MLKEM768_AES256GCM_SHA384_P256
        }
        MlsCiphersuite::Mls192Mlkem768Aes256gcmSha384Mldsa65 => {
            Ciphersuite::MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65
        }
        MlsCiphersuite::Mls128Mlkem768x25519Chacha20poly1305Sha384Mldsa44 => {
            Ciphersuite::MLS_128_MLKEM768X25519_CHACHA20POLY1305_SHA384_MLDSA44
        }
        MlsCiphersuite::Mls256Mlkem1024Aes256gcmSha512Mldsa87 => {
            Ciphersuite::MLS_256_MLKEM1024_AES256GCM_SHA512_MLDSA87
        }
        MlsCiphersuite::Mls256Mlkem1024Aes256gcmSha384Mldsa87 => {
            Ciphersuite::MLS_256_MLKEM1024_AES256GCM_SHA384_MLDSA87
        }
        MlsCiphersuite::Mls128Mlkem768Aes256gcmSha384Ed25519 => {
            Ciphersuite::MLS_128_MLKEM768_AES256GCM_SHA384_Ed25519
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
        Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519 => {
            Ok(MlsCiphersuite::Mls256XwingChacha20poly1305Sha256Ed25519)
        }
        Ciphersuite::MLS_192_MLKEM1024_AES256GCM_SHA384_P384 => {
            Ok(MlsCiphersuite::Mls192Mlkem1024Aes256gcmSha384P384)
        }
        Ciphersuite::MLS_128_MLKEM768X25519_AES256GCM_SHA384_Ed25519 => {
            Ok(MlsCiphersuite::Mls128Mlkem768x25519Aes256gcmSha384Ed25519)
        }
        Ciphersuite::MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519 => {
            Ok(MlsCiphersuite::Mls128Mlkem768x25519Aes128gcmSha256Ed25519)
        }
        Ciphersuite::MLS_128_MLKEM768_AES256GCM_SHA384_P256 => {
            Ok(MlsCiphersuite::Mls128Mlkem768Aes256gcmSha384P256)
        }
        Ciphersuite::MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65 => {
            Ok(MlsCiphersuite::Mls192Mlkem768Aes256gcmSha384Mldsa65)
        }
        Ciphersuite::MLS_128_MLKEM768X25519_CHACHA20POLY1305_SHA384_MLDSA44 => {
            Ok(MlsCiphersuite::Mls128Mlkem768x25519Chacha20poly1305Sha384Mldsa44)
        }
        Ciphersuite::MLS_256_MLKEM1024_AES256GCM_SHA512_MLDSA87 => {
            Ok(MlsCiphersuite::Mls256Mlkem1024Aes256gcmSha512Mldsa87)
        }
        Ciphersuite::MLS_256_MLKEM1024_AES256GCM_SHA384_MLDSA87 => {
            Ok(MlsCiphersuite::Mls256Mlkem1024Aes256gcmSha384Mldsa87)
        }
        Ciphersuite::MLS_128_MLKEM768_AES256GCM_SHA384_Ed25519 => {
            Ok(MlsCiphersuite::Mls128Mlkem768Aes256gcmSha384Ed25519)
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

/// Returns every ciphersuite this build can execute.
///
/// This is the same set OpenMLS advertises in a leaf node when the caller does
/// not pin `MlsCapabilities.ciphersuites`, and every entry is covered by a
/// full group-lifecycle test. Note that most of them are **experimental**
/// post-quantum suites on provisional code points — see `MlsCiphersuite`.
// The tests are `all_supported_ciphersuites_full_group_lifecycle`
// (rust/src/hybrid_crypto.rs) and the loop over `MlsCiphersuite.values` in
// test/group_lifecycle_test.dart. Kept out of the doc comment: FRB copies that
// into the published Dart API, where a pointer to a private Rust test module is
// noise for consumers.
#[flutter_rust_bridge::frb(sync)]
pub fn supported_ciphersuites() -> Vec<MlsCiphersuite> {
    vec![
        MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519,
        MlsCiphersuite::Mls128DhkemX25519Chacha20poly1305Sha256Ed25519,
        MlsCiphersuite::Mls128DhkemP256Aes128gcmSha256P256,
        MlsCiphersuite::Mls256XwingChacha20poly1305Sha256Ed25519,
        MlsCiphersuite::Mls192Mlkem1024Aes256gcmSha384P384,
        MlsCiphersuite::Mls128Mlkem768x25519Aes256gcmSha384Ed25519,
        MlsCiphersuite::Mls128Mlkem768x25519Aes128gcmSha256Ed25519,
        MlsCiphersuite::Mls128Mlkem768Aes256gcmSha384P256,
        MlsCiphersuite::Mls192Mlkem768Aes256gcmSha384Mldsa65,
        MlsCiphersuite::Mls128Mlkem768x25519Chacha20poly1305Sha384Mldsa44,
        MlsCiphersuite::Mls256Mlkem1024Aes256gcmSha512Mldsa87,
        MlsCiphersuite::Mls256Mlkem1024Aes256gcmSha384Mldsa87,
        MlsCiphersuite::Mls128Mlkem768Aes256gcmSha384Ed25519,
    ]
}
