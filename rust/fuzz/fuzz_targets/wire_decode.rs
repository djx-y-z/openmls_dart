#![no_main]
//! Fuzz target for the wire-bytes decoders behind the group-join and
//! add-member APIs.
//!
//! `joinGroupFromWelcome` / the external-commit entry points decode a peer's
//! `ratchetTreeBytes`, and every add-member variant decodes peer key packages —
//! all of it attacker-controlled bytes straight off the network. Those types
//! nest leaf nodes, parent nodes and extension lists inside one another, the
//! shape behind both the `MlsMessageIn` panic (GHSA-rrmv-c79f-cf5r) and the
//! unbounded recursion through nested extensions (GHSA-gc79-23g3-8g52). This
//! target checks that the decoder the API actually uses neither panics nor
//! crashes on malformed input — an `Err` is a success.

use libfuzzer_sys::fuzz_target;
use openmls_frb::fuzz_decode_wire_types;

fuzz_target!(|data: &[u8]| {
    fuzz_decode_wire_types(data);
});
