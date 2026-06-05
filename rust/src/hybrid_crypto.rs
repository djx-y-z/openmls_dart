//! Hybrid OpenMLS crypto provider.
//!
//! RustCrypto remains the default backend for existing MLS 1.0 ciphersuites.
//! The X-Wing post-quantum hybrid KEM is implemented by OpenMLS's libcrux
//! provider, so HPKE operations for that KEM are delegated there.

use openmls::prelude::tls_codec::SecretVLBytes;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    types::{
        AeadType, Ciphersuite, CryptoError, ExporterSecret, HashType, HpkeCiphertext, HpkeConfig,
        HpkeKemType, HpkeKeyPair, KemOutput, SignatureScheme,
    },
};

pub struct HybridCrypto {
    rust: openmls_rust_crypto::RustCrypto,
    libcrux: openmls_libcrux_crypto::CryptoProvider,
}

impl HybridCrypto {
    pub fn new() -> Result<Self, CryptoError> {
        Ok(Self {
            rust: openmls_rust_crypto::RustCrypto::default(),
            libcrux: openmls_libcrux_crypto::CryptoProvider::new()?,
        })
    }
}

fn uses_xwing_kem(config: &HpkeConfig) -> bool {
    matches!(config.0, HpkeKemType::XWingKemDraft6)
}

impl OpenMlsCrypto for HybridCrypto {
    fn supports(&self, ciphersuite: Ciphersuite) -> Result<(), CryptoError> {
        match ciphersuite {
            Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519 => {
                self.libcrux.supports(ciphersuite)
            }
            _ => self.rust.supports(ciphersuite),
        }
    }

    fn supported_ciphersuites(&self) -> Vec<Ciphersuite> {
        let mut ciphersuites = self.rust.supported_ciphersuites();
        ciphersuites.push(Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519);
        ciphersuites
    }

    fn hkdf_extract(
        &self,
        hash_type: HashType,
        salt: &[u8],
        ikm: &[u8],
    ) -> Result<SecretVLBytes, CryptoError> {
        self.rust.hkdf_extract(hash_type, salt, ikm)
    }

    fn hmac(
        &self,
        hash_type: HashType,
        key: &[u8],
        message: &[u8],
    ) -> Result<SecretVLBytes, CryptoError> {
        self.rust.hmac(hash_type, key, message)
    }

    fn hkdf_expand(
        &self,
        hash_type: HashType,
        prk: &[u8],
        info: &[u8],
        okm_len: usize,
    ) -> Result<SecretVLBytes, CryptoError> {
        self.rust.hkdf_expand(hash_type, prk, info, okm_len)
    }

    fn hash(&self, hash_type: HashType, data: &[u8]) -> Result<Vec<u8>, CryptoError> {
        self.rust.hash(hash_type, data)
    }

    fn aead_encrypt(
        &self,
        alg: AeadType,
        key: &[u8],
        data: &[u8],
        nonce: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        self.rust.aead_encrypt(alg, key, data, nonce, aad)
    }

    fn aead_decrypt(
        &self,
        alg: AeadType,
        key: &[u8],
        ct_tag: &[u8],
        nonce: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        self.rust.aead_decrypt(alg, key, ct_tag, nonce, aad)
    }

    fn signature_key_gen(&self, alg: SignatureScheme) -> Result<(Vec<u8>, Vec<u8>), CryptoError> {
        self.rust.signature_key_gen(alg)
    }

    fn verify_signature(
        &self,
        alg: SignatureScheme,
        data: &[u8],
        pk: &[u8],
        signature: &[u8],
    ) -> Result<(), CryptoError> {
        self.rust.verify_signature(alg, data, pk, signature)
    }

    fn sign(&self, alg: SignatureScheme, data: &[u8], key: &[u8]) -> Result<Vec<u8>, CryptoError> {
        self.rust.sign(alg, data, key)
    }

    fn hpke_seal(
        &self,
        config: HpkeConfig,
        pk_r: &[u8],
        info: &[u8],
        aad: &[u8],
        ptxt: &[u8],
    ) -> Result<HpkeCiphertext, CryptoError> {
        if uses_xwing_kem(&config) {
            self.libcrux.hpke_seal(config, pk_r, info, aad, ptxt)
        } else {
            self.rust.hpke_seal(config, pk_r, info, aad, ptxt)
        }
    }

    fn hpke_open(
        &self,
        config: HpkeConfig,
        input: &HpkeCiphertext,
        sk_r: &[u8],
        info: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        if uses_xwing_kem(&config) {
            self.libcrux.hpke_open(config, input, sk_r, info, aad)
        } else {
            self.rust.hpke_open(config, input, sk_r, info, aad)
        }
    }

    fn hpke_setup_sender_and_export(
        &self,
        config: HpkeConfig,
        pk_r: &[u8],
        info: &[u8],
        exporter_context: &[u8],
        exporter_length: usize,
    ) -> Result<(KemOutput, ExporterSecret), CryptoError> {
        if uses_xwing_kem(&config) {
            self.libcrux.hpke_setup_sender_and_export(
                config,
                pk_r,
                info,
                exporter_context,
                exporter_length,
            )
        } else {
            self.rust.hpke_setup_sender_and_export(
                config,
                pk_r,
                info,
                exporter_context,
                exporter_length,
            )
        }
    }

    fn hpke_setup_receiver_and_export(
        &self,
        config: HpkeConfig,
        enc: &[u8],
        sk_r: &[u8],
        info: &[u8],
        exporter_context: &[u8],
        exporter_length: usize,
    ) -> Result<ExporterSecret, CryptoError> {
        if uses_xwing_kem(&config) {
            self.libcrux.hpke_setup_receiver_and_export(
                config,
                enc,
                sk_r,
                info,
                exporter_context,
                exporter_length,
            )
        } else {
            self.rust.hpke_setup_receiver_and_export(
                config,
                enc,
                sk_r,
                info,
                exporter_context,
                exporter_length,
            )
        }
    }

    fn derive_hpke_keypair(
        &self,
        config: HpkeConfig,
        ikm: &[u8],
    ) -> Result<HpkeKeyPair, CryptoError> {
        if uses_xwing_kem(&config) {
            self.libcrux.derive_hpke_keypair(config, ikm)
        } else {
            self.rust.derive_hpke_keypair(config, ikm)
        }
    }
}

impl OpenMlsRand for HybridCrypto {
    type Error = openmls_rust_crypto::RandError;

    fn random_array<const N: usize>(&self) -> Result<[u8; N], Self::Error> {
        self.rust.random_array()
    }

    fn random_vec(&self, len: usize) -> Result<Vec<u8>, Self::Error> {
        self.rust.random_vec(len)
    }
}
