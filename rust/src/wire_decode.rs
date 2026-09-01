//! Fuzz entry point for decoding attacker-controlled TLS wire bytes.
//!
//! This module used to hold `from_exact_bytes`, a `Read`-based substitute for
//! `tls_deserialize_exact_bytes` that avoided an out-of-bounds panic in
//! openmls' hand-written `DeserializeBytes` impls (GHSA-rrmv-c79f-cf5r). That
//! is fixed upstream as of openmls 0.9.0 — both the remainder arithmetic and
//! the trailing-byte handling extensions used to skip — so the API decodes
//! through openmls' own path again and the substitute is gone.
//!
//! What remains is the fuzz target. It lives here, rather than in the fuzz
//! crate, so the fuzzer drives the decoders through *this* crate's `openmls`
//! dependency. Doing it the other way round would mean giving `rust/fuzz` its
//! own `openmls` entry, and nothing would keep that tag in step with
//! `rust/Cargo.toml` when `make check-new-openmls-version` bumps it.
//!
//! Kept after the upstream fix on purpose: these are the types the API parses
//! straight off the network, so they are worth fuzzing whichever decoder is
//! behind them. Upstream added its own targets over the same surface in #2148;
//! this one differs in covering the exact entry points this crate exposes.

use openmls::prelude::tls_codec::DeserializeBytes as TlsDeserializeBytes;
use openmls::prelude::{KeyPackageIn, MlsMessageIn, RatchetTreeIn};

/// Fuzz entry point — drives the decoders over every type the API reads from
/// attacker-controlled bytes. The contract under test is simply "never panics";
/// an `Err` is a pass.
#[doc(hidden)]
pub fn fuzz_decode_wire_types(bytes: &[u8]) {
    let _ = MlsMessageIn::tls_deserialize_exact_bytes(bytes);
    let _ = RatchetTreeIn::tls_deserialize_exact_bytes(bytes);
    let _ = KeyPackageIn::tls_deserialize_exact_bytes(bytes);
}
