//! Hybrid OpenMLS crypto provider.
//!
//! RustCrypto is the backend for every ciphersuite this provider supports but
//! one. The exception is the experimental
//! `MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` suite (0x004D), which
//! `RustCrypto::supports()` rejects; OpenMLS's libcrux provider implements it,
//! so HPKE operations for that **one suite** — identified by its full
//! `HpkeConfig` triple, not by its KEM — are delegated there. Everything else,
//! including the nine ML-KEM suites (three of which share X-Wing's KEM), runs
//! on RustCrypto. See [`routes_to_libcrux`] for why the KEM alone is not a
//! usable discriminator.
//!
//! The libcrux provider is initialized **lazily** on the first X-Wing
//! operation: classical ciphersuites never depend on libcrux initialization
//! succeeding, and pay no init cost. An init failure (only possible cause:
//! insufficient OS randomness) surfaces as a `CryptoError` on the X-Wing
//! operation itself — fail-closed, never a weak key.

use std::sync::OnceLock;

use openmls::prelude::tls_codec::SecretVLBytes;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    types::{
        AeadType, Ciphersuite, CryptoError, ExporterSecret, HashType, HpkeCiphertext, HpkeConfig,
        HpkeKeyPair, KemOutput, SignatureScheme,
    },
};

pub struct HybridCrypto {
    rust: openmls_rust_crypto::RustCrypto,
    /// Lazily-initialized libcrux provider. `Err` is cached per instance, but
    /// providers are recreated per engine operation, so the next operation
    /// retries initialization.
    libcrux: OnceLock<Result<openmls_libcrux_crypto::CryptoProvider, CryptoError>>,
}

// HybridCrypto crosses FRB's async task boundary inside SnapshotOpenMlsProvider,
// which requires Send + Sync. Fail at compile time (with a clear location)
// rather than deep inside FRB-generated code.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<HybridCrypto>();
};

impl HybridCrypto {
    pub fn new() -> Self {
        Self { rust: openmls_rust_crypto::RustCrypto::default(), libcrux: OnceLock::new() }
    }

    /// Returns the libcrux provider, initializing it on first use.
    fn libcrux(&self) -> Result<&openmls_libcrux_crypto::CryptoProvider, CryptoError> {
        self.libcrux
            .get_or_init(openmls_libcrux_crypto::CryptoProvider::new)
            .as_ref()
            .map_err(|e| *e)
    }
}

impl Default for HybridCrypto {
    fn default() -> Self {
        Self::new()
    }
}

/// The one ciphersuite this provider delegates to libcrux.
const LIBCRUX_CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519;

/// Single routing predicate for the whole provider: an operation belongs to
/// libcrux iff its HPKE configuration is *exactly* that of
/// [`LIBCRUX_CIPHERSUITE`]. `supports()` derives the config from the
/// ciphersuite via `hpke_config()`, so both dispatch paths can never diverge.
///
/// **Match the whole triple, never the KEM alone.** `hpke_seal`, `hpke_open`,
/// `derive_hpke_keypair` and the two `hpke_setup_*` methods receive only an
/// `HpkeConfig` — the ciphersuite is not recoverable at the call site, so the
/// triple is the entire identifying information available. And the KEM alone
/// no longer identifies a suite: openmls 0.9.0 gave `XWingKemDraft6` to four
/// ciphersuites (X-Wing plus three `MLKEM768X25519` variants — X-Wing *is*
/// ML-KEM-768 + X25519), where 0.8.1 had given it to one. A `matches!` on the
/// KEM therefore started routing three suites into libcrux silently.
/// `libcrux_routing_is_limited_to_xwing` pins this.
fn routes_to_libcrux(config: &HpkeConfig) -> bool {
    let HpkeConfig(kem, kdf, aead) = LIBCRUX_CIPHERSUITE.hpke_config();
    config.0 == kem && config.1 == kdf && config.2 == aead
}

impl OpenMlsCrypto for HybridCrypto {
    fn supports(&self, ciphersuite: Ciphersuite) -> Result<(), CryptoError> {
        if routes_to_libcrux(&ciphersuite.hpke_config()) {
            self.libcrux()?.supports(ciphersuite)
        } else {
            self.rust.supports(ciphersuite)
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
        if routes_to_libcrux(&config) {
            self.libcrux()?.hpke_seal(config, pk_r, info, aad, ptxt)
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
        if routes_to_libcrux(&config) {
            self.libcrux()?.hpke_open(config, input, sk_r, info, aad)
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
        if routes_to_libcrux(&config) {
            self.libcrux()?.hpke_setup_sender_and_export(
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
        if routes_to_libcrux(&config) {
            self.libcrux()?.hpke_setup_receiver_and_export(
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
        if routes_to_libcrux(&config) {
            self.libcrux()?.derive_hpke_keypair(config, ikm)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot_storage::{SnapshotOpenMlsProvider, SnapshotStorageProvider};
    use openmls::prelude::{tls_codec::*, *};
    use openmls_basic_credential::SignatureKeyPair;
    use openmls_traits::OpenMlsProvider;

    /// The PRODUCTION provider with empty in-memory storage — the lifecycle
    /// test must exercise the exact provider wiring that ships, not a copy.
    fn test_provider() -> SnapshotOpenMlsProvider {
        SnapshotOpenMlsProvider::new(SnapshotStorageProvider::from_entries(vec![]))
    }

    fn make_identity(
        provider: &SnapshotOpenMlsProvider,
        name: &[u8],
        cs: Ciphersuite,
    ) -> (CredentialWithKey, SignatureKeyPair) {
        let credential = BasicCredential::new(name.to_vec());
        let signer =
            SignatureKeyPair::new(cs.signature_algorithm()).expect("signature keypair gen");
        signer.store(provider.storage()).expect("store signer");
        let cwk = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.public().into(),
        };
        (cwk, signer)
    }

    /// RustCrypto alone must NOT support X-Wing — proves delegation is required.
    #[test]
    fn rust_crypto_does_not_support_xwing() {
        let rust = openmls_rust_crypto::RustCrypto::default();
        assert!(
            rust.supports(Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519)
                .is_err()
        );
    }

    /// HybridCrypto must report X-Wing as supported.
    #[test]
    fn hybrid_crypto_supports_xwing() {
        let hybrid = HybridCrypto::new();
        hybrid
            .supports(Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519)
            .expect("X-Wing should be supported by hybrid provider");
        assert!(
            hybrid
                .supported_ciphersuites()
                .contains(&Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519)
        );
    }

    /// Classical operations must never initialize the libcrux provider —
    /// proves lazy init keeps classical suites independent of libcrux.
    ///
    /// This test also MECHANICALLY ENFORCES the reachability justifications in
    /// `.cargo/audit.toml`: RUSTSEC-2026-0075 (libcrux-ed25519) and
    /// RUSTSEC-2026-0124 (libcrux-chacha20poly1305) are ignored there on the
    /// grounds that signature and AEAD operations never route to libcrux. If a
    /// future refactor changes that routing, this test fails and the ignore
    /// entries must be re-justified.
    #[test]
    fn classical_ops_do_not_init_libcrux() {
        let hybrid = HybridCrypto::new();
        assert!(hybrid.libcrux.get().is_none(), "libcrux must start uninitialized");

        let classical_cs = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

        // Classical ciphersuite operations across every delegation family.
        hybrid.supports(classical_cs).expect("classical suite supported");
        hybrid.hash(HashType::Sha2_256, b"data").expect("hash");
        hybrid
            .hkdf_extract(HashType::Sha2_256, b"salt", b"ikm")
            .expect("hkdf extract");
        hybrid.hmac(HashType::Sha2_256, b"key", b"msg").expect("hmac");
        hybrid
            .derive_hpke_keypair(classical_cs.hpke_config(), &[7u8; 32])
            .expect("classical hpke keypair");

        // Signature key generation — the RUSTSEC-2026-0075 justification:
        // must run on RustCrypto/ed25519-dalek, never libcrux-ed25519.
        hybrid
            .signature_key_gen(SignatureScheme::ED25519)
            .expect("ed25519 keygen");

        // AEAD — the RUSTSEC-2026-0124 justification: must run on RustCrypto,
        // never the libcrux-chacha20poly1305 path.
        let ct = hybrid
            .aead_encrypt(
                AeadType::ChaCha20Poly1305,
                &[1u8; 32],
                b"plaintext",
                &[2u8; 12],
                b"aad",
            )
            .expect("aead encrypt");
        hybrid
            .aead_decrypt(AeadType::ChaCha20Poly1305, &[1u8; 32], &ct, &[2u8; 12], b"aad")
            .expect("aead decrypt");

        assert!(
            hybrid.libcrux.get().is_none(),
            "classical operations must not touch libcrux \
             (audit.toml RUSTSEC ignore justifications depend on this)"
        );

        // First X-Wing operation initializes it.
        hybrid
            .supports(Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519)
            .expect("xwing supported");
        assert!(hybrid.libcrux.get().is_some(), "X-Wing op must initialize libcrux");
    }

    /// The public API ciphersuite list and the provider must stay in sync,
    /// as a **bijection**: every suite advertised by `supported_ciphersuites()`
    /// (api/types.rs) must be supported by the shipped crypto provider, and
    /// every suite the provider supports must be nameable in `MlsCiphersuite`
    /// *and* present in that list.
    ///
    /// Both directions matter. A suite in the list the provider cannot run is
    /// a promise we break; a suite the provider runs but the enum cannot name
    /// makes `inspect_welcome` fail on a group the caller could otherwise have
    /// joined, because it maps the group's ciphersuite before returning.
    #[test]
    fn api_list_matches_provider_support() {
        let hybrid = HybridCrypto::new();
        let api_list = crate::api::types::supported_ciphersuites();

        for api_cs in &api_list {
            let native = crate::api::types::ciphersuite_to_native(api_cs);
            hybrid
                .supports(native)
                .unwrap_or_else(|e| panic!("API advertises {native:?} but provider rejects it: {e:?}"));
        }

        for native in hybrid.supported_ciphersuites() {
            // Deliberately NOT `if let Ok(..)`: skipping the suites the enum
            // cannot name is what let openmls 0.9.0's nine new ciphersuites go
            // out on the wire while the Dart API still offered four.
            let api_cs = crate::api::types::native_to_ciphersuite(native).unwrap_or_else(|e| {
                panic!("provider supports {native:?} but MlsCiphersuite cannot name it: {e}")
            });
            assert!(
                api_list.iter().any(|c| ciphersuite_to_native_eq(c, &api_cs)),
                "provider supports {native:?} (mapped to enum) but API list omits it"
            );
        }
    }

    /// Helper: MlsCiphersuite has no PartialEq (FRB type) — compare via native.
    fn ciphersuite_to_native_eq(
        a: &crate::api::types::MlsCiphersuite,
        b: &crate::api::types::MlsCiphersuite,
    ) -> bool {
        crate::api::types::ciphersuite_to_native(a) == crate::api::types::ciphersuite_to_native(b)
    }

    /// Routing drift guard: of every ciphersuite this provider supports,
    /// **exactly one** — X-Wing (0x004D) — may be delegated to libcrux.
    ///
    /// This is the test that pins the reachability arguments recorded in
    /// `.cargo/audit.toml` and `rust/deny.toml`: a libcrux advisory is only
    /// arguable as unreachable for a given operation family while the set of
    /// suites reaching libcrux is exactly this one. `classical_ops_do_not_init_libcrux`
    /// proves classical suites stay away from libcrux, but it samples a single
    /// hard-coded suite and so cannot bound the set — this one enumerates.
    ///
    /// It went red for three suites when openmls 0.9.0 gave `XWingKemDraft6`
    /// to four ciphersuites instead of one.
    #[test]
    fn libcrux_routing_is_limited_to_xwing() {
        let hybrid = HybridCrypto::new();
        let intended = Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519;

        let routed: Vec<Ciphersuite> = hybrid
            .supported_ciphersuites()
            .into_iter()
            .filter(|cs| routes_to_libcrux(&cs.hpke_config()))
            .collect();

        assert_eq!(
            routed,
            vec![intended],
            "exactly one supported ciphersuite may route to libcrux, got {routed:?} — \
             the libcrux advisory reachability arguments in .cargo/audit.toml and \
             rust/deny.toml are stated over this set"
        );

        // The same claim operationally rather than through the predicate.
        //
        // All five HPKE methods make their own `routes_to_libcrux` call, so
        // exercising one of them says nothing about the other four: a wrong
        // backend introduced in `hpke_open` alone would leave both the
        // predicate above and a keygen-only probe green. Every one of the five
        // therefore runs, on a fresh provider per suite, and libcrux must still
        // be uninitialised after each — `libcrux` is a `OnceLock` filled on
        // first use, so `get().is_none()` is a faithful "was never reached".
        //
        // `HpkeConfig` is neither `Copy` nor `Clone`, hence `cs.hpke_config()`
        // per call rather than one binding reused.
        const INFO: &[u8] = b"routing probe";
        const AAD: &[u8] = b"routing aad";
        const PTXT: &[u8] = b"routing plaintext";
        const CTX: &[u8] = b"routing exporter";

        for cs in hybrid.supported_ciphersuites().into_iter().filter(|cs| *cs != intended) {
            let probe = HybridCrypto::new();
            let untouched = |method: &str| {
                assert!(
                    probe.libcrux.get().is_none(),
                    "{cs:?} reached libcrux through {method}; only {intended:?} may"
                );
            };

            let kp = probe
                .derive_hpke_keypair(cs.hpke_config(), &[3u8; 32])
                .unwrap_or_else(|e| panic!("{cs:?} derive_hpke_keypair failed on RustCrypto: {e:?}"));
            untouched("derive_hpke_keypair");

            let ctxt = probe
                .hpke_seal(cs.hpke_config(), &kp.public, INFO, AAD, PTXT)
                .unwrap_or_else(|e| panic!("{cs:?} hpke_seal failed on RustCrypto: {e:?}"));
            untouched("hpke_seal");

            let ptxt = probe
                .hpke_open(cs.hpke_config(), &ctxt, &kp.private, INFO, AAD)
                .unwrap_or_else(|e| panic!("{cs:?} hpke_open failed on RustCrypto: {e:?}"));
            assert_eq!(ptxt, PTXT, "{cs:?} HPKE round-trip returned different bytes");
            untouched("hpke_open");

            let (enc, sender_secret) = probe
                .hpke_setup_sender_and_export(cs.hpke_config(), &kp.public, INFO, CTX, 32)
                .unwrap_or_else(|e| {
                    panic!("{cs:?} hpke_setup_sender_and_export failed on RustCrypto: {e:?}")
                });
            untouched("hpke_setup_sender_and_export");

            let receiver_secret = probe
                .hpke_setup_receiver_and_export(cs.hpke_config(), &enc, &kp.private, INFO, CTX, 32)
                .unwrap_or_else(|e| {
                    panic!("{cs:?} hpke_setup_receiver_and_export failed on RustCrypto: {e:?}")
                });
            assert_eq!(
                &*sender_secret, &*receiver_secret,
                "{cs:?} sender and receiver exported different secrets"
            );
            untouched("hpke_setup_receiver_and_export");
        }
    }

    /// Every ciphersuite OpenMLS advertises **by default** must be one this
    /// provider can actually execute, and one the public API can name.
    ///
    /// `capabilities_to_native` (api/types.rs) passes `None` for an empty
    /// ciphersuite list, and `Capabilities::new(None, ..)` fills that with
    /// `default_ciphersuites()` — so this list is what goes out in a leaf node
    /// whenever the caller does not pin capabilities. Advertising a suite the
    /// provider cannot run makes peers pick it and fail; advertising one the
    /// enum cannot name makes `inspect_welcome` reject the group before the
    /// application can decide whether to join.
    ///
    /// openmls 0.9.0's `draft-ietf-mls-pq-ciphersuites` feature grew this
    /// default list from 4 entries to 13 with no signature change here.
    #[test]
    fn openmls_defaults_are_executable_and_nameable() {
        let hybrid = HybridCrypto::new();
        let defaults: Vec<Ciphersuite> = Capabilities::new(None, None, None, None, None)
            .ciphersuites()
            .iter()
            .map(|vc| {
                Ciphersuite::try_from(*vc)
                    .unwrap_or_else(|e| panic!("default ciphersuite {vc:?} is not a known suite: {e:?}"))
            })
            .collect();

        for cs in &defaults {
            hybrid.supports(*cs).unwrap_or_else(|e| {
                panic!("OpenMLS advertises {cs:?} by default but this provider rejects it: {e:?}")
            });
            crate::api::types::native_to_ciphersuite(*cs).unwrap_or_else(|e| {
                panic!("OpenMLS advertises {cs:?} by default but MlsCiphersuite cannot name it: {e}")
            });
        }

        // Set equality, not just the subset above: a suite the provider can run
        // but OpenMLS does not advertise by default would silently drop out of
        // every leaf node built without explicit capabilities.
        let mut defaults_sorted = defaults.clone();
        let mut supported_sorted = hybrid.supported_ciphersuites();
        defaults_sorted.sort_by_key(|c| u16::from(*c));
        supported_sorted.sort_by_key(|c| u16::from(*c));
        assert_eq!(
            defaults_sorted, supported_sorted,
            "OpenMLS's default ciphersuite list and this provider's support list have drifted apart"
        );
    }

    /// Full MLS group lifecycle on the one suite delegated to libcrux, plus the
    /// two things only this suite can assert: that the material on the wire is
    /// really ML-KEM-sized, and that it is really libcrux producing it.
    #[test]
    fn xwing_full_group_lifecycle() {
        let cs = LIBCRUX_CIPHERSUITE;
        let hybrid = HybridCrypto::new();

        // Backend identity, classical direction first (the assertion below is
        // only meaningful while libcrux is still untouched).
        let classical = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
        let classical_kp = hybrid
            .derive_hpke_keypair(classical.hpke_config(), &[9u8; 32])
            .expect("derive classical HPKE keypair");
        assert_eq!(
            classical_kp.public.len(),
            32,
            "classical X25519 HPKE public key should be 32 bytes"
        );
        assert!(hybrid.libcrux.get().is_none(), "classical HPKE must not touch libcrux");

        let xwing_kp = hybrid
            .derive_hpke_keypair(cs.hpke_config(), &[9u8; 32])
            .expect("derive X-Wing HPKE keypair");

        // Backend identity, X-Wing direction. The size check below cannot carry
        // this on its own: RustCrypto's `kem_mode` also maps `XWingKemDraft6`,
        // so an ML-KEM-sized key proves the algorithm, not the provider.
        assert!(
            hybrid.libcrux.get().is_some(),
            "X-Wing HPKE must be delegated to libcrux, not answered by RustCrypto"
        );

        // Anti-downgrade guard: an X-Wing HPKE keypair MUST carry real ML-KEM-768
        // material on the wire, not a silent X25519-only fallback. A bare X25519
        // public key is exactly 32 bytes; X-Wing's HPKE public key embeds the
        // ML-KEM-768 encapsulation key (~1184 bytes) plus the X25519 share, so it
        // is well over 1000 bytes. If routing ever silently degraded to classical
        // X25519, this assertion would fail.
        let pubkey_len = xwing_kp.public.len();
        assert!(
            pubkey_len > 1000,
            "X-Wing HPKE public key must be ML-KEM-sized (>1000 bytes), \
             got {pubkey_len} bytes — possible silent downgrade to X25519"
        );

        full_group_lifecycle(cs);
    }

    /// Every ciphersuite the public API advertises must survive a complete
    /// group lifecycle — not merely be accepted by `supports()`.
    ///
    /// `supported_ciphersuites()` is a promise made to callers, and the cost of
    /// breaking it is not a compile error: a peer picks the suite out of a leaf
    /// node and the failure lands at `inspect_welcome` or at the first commit.
    /// openmls 0.9.0 grew that list from 4 suites to 13 with no signature
    /// change, so keygen-level evidence is not enough — this runs the whole
    /// cycle, including the ML-DSA signature suites, whose identities come from
    /// `openmls_basic_credential` and need its `draft-ietf-mls-pq-ciphersuites`
    /// feature (see rust/Cargo.toml).
    #[test]
    fn all_supported_ciphersuites_full_group_lifecycle() {
        for api_cs in crate::api::types::supported_ciphersuites() {
            full_group_lifecycle(crate::api::types::ciphersuite_to_native(&api_cs));
        }
    }

    /// One full MLS group lifecycle on `cs`, against the production provider
    /// wiring: create group → key package → add member (commit + Welcome) →
    /// join → application messages in both directions.
    fn full_group_lifecycle(cs: Ciphersuite) {
        // Captured output is replayed on failure, so the last line printed
        // names the suite whose lifecycle broke.
        println!("full_group_lifecycle: {cs:?}");

        let alice_provider = test_provider();
        let bob_provider = test_provider();

        let (alice_cwk, alice_signer) = make_identity(&alice_provider, b"alice", cs);
        let (bob_cwk, bob_signer) = make_identity(&bob_provider, b"bob", cs);

        // Alice creates the group (X-Wing HPKE keys in the leaf node).
        let mut alice_group = MlsGroup::builder()
            .ciphersuite(cs)
            .use_ratchet_tree_extension(true)
            .build(&alice_provider, &alice_signer, alice_cwk)
            .expect("alice creates group");

        // Bob creates a key package (X-Wing HPKE init key), serialized round-trip.
        let bob_kp_bundle = KeyPackage::builder()
            .build(cs, &bob_provider, &bob_signer, bob_cwk)
            .expect("bob key package");
        let bob_kp_bytes = bob_kp_bundle
            .key_package()
            .tls_serialize_detached()
            .expect("kp serialize");

        // Alice validates and adds Bob — commit + Welcome (HPKE seal to X-Wing key).
        let bob_kp_in =
            KeyPackageIn::tls_deserialize_exact_bytes(&bob_kp_bytes).expect("kp deserialize");
        let bob_kp = bob_kp_in
            .validate(alice_provider.crypto(), ProtocolVersion::Mls10)
            .expect("kp validate");

        let (_commit, welcome_out, _group_info) = alice_group
            .add_members(&alice_provider, &alice_signer, &[bob_kp])
            .expect("alice adds bob");
        alice_group
            .merge_pending_commit(&alice_provider)
            .expect("alice merges add commit");

        // Bob joins via Welcome (HPKE open with X-Wing key), serialized round-trip.
        let welcome_bytes = welcome_out
            .tls_serialize_detached()
            .expect("welcome serialize");
        let welcome_msg =
            MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes).expect("welcome deserialize");
        let welcome = match welcome_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => panic!("expected a Welcome message"),
        };
        let mut bob_group = StagedWelcome::new_from_welcome(
            &bob_provider,
            &MlsGroupJoinConfig::default(),
            welcome,
            None, // ratchet tree extension enabled
        )
        .expect("bob stages welcome")
        .into_group(&bob_provider)
        .expect("bob joins group");

        assert_eq!(alice_group.epoch(), bob_group.epoch());
        assert_eq!(alice_group.members().count(), 2);
        assert_eq!(bob_group.members().count(), 2);
        assert_eq!(alice_group.ciphersuite(), cs);
        assert_eq!(bob_group.ciphersuite(), cs);

        // Alice → Bob application message.
        let msg_out = alice_group
            .create_message(&alice_provider, &alice_signer, b"hello bob")
            .expect("alice creates message");
        let msg_bytes = msg_out.tls_serialize_detached().expect("msg serialize");
        let protocol_msg = MlsMessageIn::tls_deserialize_exact_bytes(&msg_bytes)
            .expect("msg deserialize")
            .try_into_protocol_message()
            .expect("protocol message");
        let processed = bob_group
            .process_message(&bob_provider, protocol_msg)
            .expect("bob processes message");
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(am) => {
                assert_eq!(am.into_bytes(), b"hello bob".to_vec());
            }
            _ => panic!("expected application message"),
        }

        // Bob → Alice application message.
        let msg_out = bob_group
            .create_message(&bob_provider, &bob_signer, b"hi alice")
            .expect("bob creates message");
        let msg_bytes = msg_out.tls_serialize_detached().expect("msg serialize");
        let protocol_msg = MlsMessageIn::tls_deserialize_exact_bytes(&msg_bytes)
            .expect("msg deserialize")
            .try_into_protocol_message()
            .expect("protocol message");
        let processed = alice_group
            .process_message(&alice_provider, protocol_msg)
            .expect("alice processes message");
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(am) => {
                assert_eq!(am.into_bytes(), b"hi alice".to_vec());
            }
            _ => panic!("expected application message"),
        }
    }
}
