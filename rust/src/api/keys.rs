//! Signature key pair management for OpenMLS.
//!
//! Wraps `SignatureKeyPair` from `openmls_basic_credential`.
//! Security-critical — follows zeroization patterns.

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use zeroize::Zeroize;

use super::types::{ciphersuite_to_native, MlsCiphersuite};

/// An opaque wrapper around an OpenMLS SignatureKeyPair.
pub struct MlsSignatureKeyPair {
    inner: SignatureKeyPair,
}

impl MlsSignatureKeyPair {
    pub(crate) fn from_native(kp: SignatureKeyPair) -> Self {
        Self { inner: kp }
    }

    pub(crate) fn native(&self) -> &SignatureKeyPair {
        &self.inner
    }

    /// Generate a new signature key pair for the given ciphersuite's signature scheme.
    #[flutter_rust_bridge::frb(sync)]
    pub fn generate(ciphersuite: MlsCiphersuite) -> Result<MlsSignatureKeyPair, String> {
        let cs = ciphersuite_to_native(&ciphersuite);
        let kp = SignatureKeyPair::new(cs.signature_algorithm())
            .map_err(|e| format!("Failed to generate signature key pair: {}", e))?;
        Ok(MlsSignatureKeyPair { inner: kp })
    }

    /// Reconstruct a key pair from raw private and public key bytes.
    ///
    /// # Security
    /// `private_key` is moved (not copied) into the key pair.
    #[flutter_rust_bridge::frb(sync)]
    pub fn from_raw(
        ciphersuite: MlsCiphersuite,
        private_key: Vec<u8>,
        public_key: Vec<u8>,
    ) -> Result<MlsSignatureKeyPair, String> {
        let cs = ciphersuite_to_native(&ciphersuite);
        let kp = SignatureKeyPair::from_raw(cs.signature_algorithm(), private_key, public_key);
        Ok(MlsSignatureKeyPair { inner: kp })
    }

    /// Returns the public key bytes.
    #[flutter_rust_bridge::frb(sync)]
    pub fn public_key(&self) -> Vec<u8> {
        self.inner.public().to_vec()
    }

    /// Returns the private key bytes.
    ///
    /// # Security
    /// The returned bytes contain private key material. The caller is responsible
    /// for securely zeroing these bytes when done.
    #[flutter_rust_bridge::frb(sync)]
    pub fn private_key(&self) -> Vec<u8> {
        self.inner.private().to_vec()
    }

    /// Returns the signature scheme as a u16.
    #[flutter_rust_bridge::frb(sync)]
    pub fn signature_scheme(&self) -> u16 {
        self.inner.signature_scheme() as u16
    }

    /// Serialize the key pair to bytes for storage.
    ///
    /// The returned bytes contain the **public key and signature scheme only** —
    /// no private key material. To reconstruct a full key pair with private key,
    /// use `from_raw()` with the original private key bytes.
    #[flutter_rust_bridge::frb(sync)]
    pub fn serialize(&self) -> Result<Vec<u8>, String> {
        // SignatureKeyPair doesn't expose private key bytes directly.
        // We serialize by storing public key + scheme, and the private key
        // is stored/loaded through the provider storage mechanism.
        // For standalone serialization, we use from_raw reconstruction approach:
        // The caller must use from_raw() with the original private key to reconstruct.
        //
        // Alternative: serialize the public key and scheme so it can be identified.
        serde_json::to_vec(&SerializableKeyPair {
            public: self.inner.public().to_vec(),
            scheme: self.inner.signature_scheme() as u16,
        })
        .map_err(|e| format!("Failed to serialize key pair: {}", e))
    }

    /// Deserialize a key pair from bytes (public key + scheme only).
    ///
    /// Note: This only restores the public key and scheme. To reconstruct
    /// a full key pair with private key, use `from_raw()`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn deserialize_public(bytes: Vec<u8>) -> Result<MlsSignatureKeyPair, String> {
        let skp: SerializableKeyPair =
            serde_json::from_slice(&bytes).map_err(|e| format!("Failed to deserialize key pair: {}", e))?;
        let scheme = SignatureScheme::try_from(skp.scheme)
            .map_err(|_| format!("Invalid signature scheme: {}", skp.scheme))?;
        // Reconstruct with empty private key — only use for public key operations
        let kp = SignatureKeyPair::from_raw(scheme, Vec::new(), skp.public);
        Ok(MlsSignatureKeyPair { inner: kp })
    }
}

/// Helper for serde serialization of key pair fields.
#[derive(serde::Serialize, serde::Deserialize)]
struct SerializableKeyPair {
    public: Vec<u8>,
    scheme: u16,
}

/// Serializable signer data (private + public + scheme).
#[derive(serde::Serialize, serde::Deserialize, zeroize::Zeroize, zeroize::ZeroizeOnDrop)]
pub(crate) struct SerializableSigner {
    pub private: Vec<u8>,
    pub public: Vec<u8>,
    pub scheme: u16,
}

/// Serialize a `SignatureKeyPair` to JSON bytes including private key.
///
/// # Security
/// The returned bytes contain private key material.
#[flutter_rust_bridge::frb(sync)]
pub fn serialize_signer(
    ciphersuite: MlsCiphersuite,
    private_key: Vec<u8>,
    public_key: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let cs = ciphersuite_to_native(&ciphersuite);
    let signer = SerializableSigner {
        private: private_key,
        public: public_key,
        scheme: cs.signature_algorithm() as u16,
    };
    let result = serde_json::to_vec(&signer)
        .map_err(|e| format!("Failed to serialize signer: {}", e));
    drop(signer);
    result
}

/// Reconstruct a `SignatureKeyPair` from raw signer bytes (JSON-serialized).
/// Zeroizes the input bytes regardless of success or failure.
pub(crate) fn signer_from_bytes(mut signer_bytes: Vec<u8>) -> Result<SignatureKeyPair, String> {
    let result = serde_json::from_slice::<SerializableSigner>(&signer_bytes)
        .map_err(|e| format!("Failed to deserialize signer: {}", e));
    signer_bytes.zeroize(); // Always zeroize, even on error
    let mut skp = result?;
    let scheme = SignatureScheme::try_from(skp.scheme)
        .map_err(|_| format!("Invalid signature scheme: {}", skp.scheme))?;
    Ok(SignatureKeyPair::from_raw(
        scheme,
        std::mem::take(&mut skp.private),
        std::mem::take(&mut skp.public),
    ))
}
