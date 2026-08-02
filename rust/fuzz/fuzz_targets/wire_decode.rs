#![no_main]
//! Fuzz target for the wire-bytes decoders behind the group-join and
//! add-member APIs.
//!
//! `joinGroupFromWelcome` / the external-commit entry points decode a peer's
//! `ratchetTreeBytes`, and every add-member variant decodes peer key packages —
//! all of it attacker-controlled bytes straight off the network. Those types
//! reach openmls' hand-written `DeserializeBytes` impls (`Extension`,
//! `UnmergedLeaves`) through their nested leaf and parent nodes, which is the
//! shape that produced the `MlsMessageIn` panic. This target proves the decoder
//! the API actually uses never panics on malformed input — an `Err` is a
//! success.

use libfuzzer_sys::fuzz_target;
use openmls_frb::fuzz_decode_wire_types;

fuzz_target!(|data: &[u8]| {
    fuzz_decode_wire_types(data);
});
