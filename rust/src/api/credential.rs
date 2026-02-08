//! Credential management for OpenMLS.
//!
//! Wraps `BasicCredential`, X.509, and `Credential` types.

use openmls::prelude::*;
use openmls::prelude::tls_codec::{
    DeserializeBytes as TlsDeserializeBytes, Serialize as TlsSerialize,
};

/// An opaque wrapper around an OpenMLS Credential.
pub struct MlsCredential {
    inner: Credential,
}

impl MlsCredential {
    pub(crate) fn from_native(c: Credential) -> Self {
        Self { inner: c }
    }

    pub(crate) fn native(&self) -> &Credential {
        &self.inner
    }

    /// Create a BasicCredential from identity bytes (e.g. user ID, email).
    #[flutter_rust_bridge::frb(sync)]
    pub fn basic(identity: Vec<u8>) -> Result<MlsCredential, String> {
        let basic = BasicCredential::new(identity);
        Ok(MlsCredential {
            inner: basic.into(),
        })
    }

    /// Create an X.509 credential from a certificate chain.
    ///
    /// Each entry in `certificate_chain` is a DER-encoded X.509 certificate.
    /// The first certificate should be the end-entity (leaf) certificate,
    /// followed by intermediate certificates in order toward the root.
    #[flutter_rust_bridge::frb(sync)]
    pub fn x509(certificate_chain: Vec<Vec<u8>>) -> Result<MlsCredential, String> {
        // MLS wire format for X.509: Certificate chain<V>
        // Certificate = opaque cert_data<V> (TLS VLBytes)
        // The chain content is concatenated TLS-serialized Certificates.
        let mut chain_content = Vec::new();
        for cert_der in certificate_chain {
            tls_codec::VLBytes::new(cert_der)
                .tls_serialize(&mut chain_content)
                .map_err(|e| format!("Failed to serialize certificate: {}", e))?;
        }
        Ok(MlsCredential {
            inner: Credential::new(CredentialType::X509, chain_content),
        })
    }

    /// Returns the identity bytes from a BasicCredential.
    ///
    /// Returns an error if this is not a BasicCredential.
    #[flutter_rust_bridge::frb(sync)]
    pub fn identity(&self) -> Result<Vec<u8>, String> {
        let basic = BasicCredential::try_from(self.inner.clone())
            .map_err(|e| format!("Failed to extract identity: {}", e))?;
        Ok(basic.identity().to_vec())
    }

    /// Returns the certificate chain from an X.509 credential.
    ///
    /// Each entry is a DER-encoded X.509 certificate.
    /// Returns an error if this is not an X.509 credential.
    #[flutter_rust_bridge::frb(sync)]
    pub fn certificates(&self) -> Result<Vec<Vec<u8>>, String> {
        if self.inner.credential_type() != CredentialType::X509 {
            return Err("Not an X.509 credential".to_string());
        }
        let content = self.inner.serialized_content();
        let mut certs = Vec::new();
        let mut remaining = content;
        while !remaining.is_empty() {
            let (cert_bytes, rest) = tls_codec::VLBytes::tls_deserialize_bytes(remaining)
                .map_err(|e| format!("Failed to deserialize certificate: {}", e))?;
            certs.push(cert_bytes.as_slice().to_vec());
            remaining = rest;
        }
        Ok(certs)
    }

    /// Returns the raw serialized content of this credential.
    ///
    /// For BasicCredential, this is the identity bytes.
    /// For X.509, this is the TLS-serialized certificate chain.
    #[flutter_rust_bridge::frb(sync)]
    pub fn serialized_content(&self) -> Vec<u8> {
        self.inner.serialized_content().to_vec()
    }

    /// Returns the credential type value (1 = Basic, 2 = X509).
    #[flutter_rust_bridge::frb(sync)]
    pub fn credential_type(&self) -> u16 {
        match self.inner.credential_type() {
            CredentialType::Basic => 1,
            CredentialType::X509 => 2,
            _ => 0,
        }
    }

    /// TLS-serialize this credential for wire transmission.
    #[flutter_rust_bridge::frb(sync)]
    pub fn serialize(&self) -> Result<Vec<u8>, String> {
        self.inner
            .tls_serialize_detached()
            .map_err(|e| format!("Failed to serialize credential: {}", e))
    }

    /// TLS-deserialize a credential from bytes.
    #[flutter_rust_bridge::frb(sync)]
    pub fn deserialize(bytes: Vec<u8>) -> Result<MlsCredential, String> {
        use tls_codec::Deserialize as TlsDeserialize;
        let credential = Credential::tls_deserialize_exact(bytes)
            .map_err(|e| format!("Failed to deserialize credential: {}", e))?;
        Ok(MlsCredential { inner: credential })
    }
}
