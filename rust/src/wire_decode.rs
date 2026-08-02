//! Panic-free decoding of attacker-controlled TLS wire bytes.
//!
//! Lives outside `crate::api` on purpose: FRB only scans `crate::api`, so
//! nothing here reaches the generated Dart surface. It is `pub` so the fuzz
//! crate (`rust/fuzz`) can drive the real helper instead of a copy of it.

use openmls::prelude::tls_codec::{Deserialize as TlsDeserialize, Error as TlsCodecError};
use openmls::prelude::{KeyPackageIn, MlsMessageIn, RatchetTreeIn};

/// Deserialize a TLS-encoded value from exact wire bytes — same contract as
/// `tls_deserialize_exact_bytes` (every byte must be consumed) but WITHOUT its
/// panic risk.
///
/// Some openmls versions can panic while decoding malformed wire bytes: the
/// affected code lives in hand-written `DeserializeBytes` impls, which slice the
/// input at the *re-serialized* length and go out of bounds when that exceeds
/// the bytes actually consumed. The `Read`-based `tls_deserialize` never calls
/// those impls, so we drive it directly and enforce "no trailing bytes"
/// ourselves — malformed input yields an error instead of aborting the process.
///
/// Use this for every parse of attacker-controlled bytes whose type can reach
/// one of those impls. `MlsMessageIn` has one of its own, and reaches
/// `PublicMessageIn`'s and `ProposalIn`'s through its body; `RatchetTreeIn` and
/// `KeyPackageIn` reach `Extension`'s and `UnmergedLeaves`' through the leaf and
/// parent nodes nested inside them.
///
/// Safe to substitute because every type we pass here derives *both* codecs from
/// the same field list (or, for `MlsMessageIn`, hand-writes `Deserialize` and
/// defines `DeserializeBytes` in terms of it), so the two paths validate
/// identically.
///
/// Reported upstream; drop this helper and go back to
/// `tls_deserialize_exact_bytes` once we depend on a fixed openmls release. See
/// `TODO.md` for details.
pub fn from_exact_bytes<T: TlsDeserialize>(bytes: &[u8]) -> Result<T, TlsCodecError> {
    let mut reader = bytes;
    let value = T::tls_deserialize(&mut reader)?;
    if !reader.is_empty() {
        return Err(TlsCodecError::TrailingData);
    }
    Ok(value)
}

/// Fuzz entry point — drives [`from_exact_bytes`] over every type the API
/// decodes from attacker-controlled bytes. The contract under test is simply
/// "never panics"; an `Err` is a pass.
///
/// It lives here, rather than in the fuzz crate, so the fuzzer exercises the
/// real decoder. Doing it the other way round would mean giving `rust/fuzz` its
/// own `openmls` dependency, and nothing keeps that tag in step with
/// `rust/Cargo.toml` when `make check-new-openmls-version` bumps it.
#[doc(hidden)]
pub fn fuzz_decode_wire_types(bytes: &[u8]) {
    let _ = from_exact_bytes::<MlsMessageIn>(bytes);
    let _ = from_exact_bytes::<RatchetTreeIn>(bytes);
    let _ = from_exact_bytes::<KeyPackageIn>(bytes);
}
