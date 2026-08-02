//! openmls_frb - Rust bridge layer for openmls.
//!
//! Dart wrapper for OpenMLS — a Rust implementation of the Messaging Layer Security (MLS) protocol (RFC 9420)

#![allow(dead_code)]

mod encrypted_db;
mod hybrid_crypto;
mod snapshot_storage;
// The FRB-generated bridge and a couple of hand-written modules
// (snapshot_storage's interior-mutability shim, encrypted_db's WASM
// `unsafe impl Send/Sync`) legitimately need unsafe; they carry their own
// `#[allow(unsafe_code)]` / `#![allow(unsafe_code)]`. Everything else is
// covered by `unsafe_code = "deny"` in Cargo.toml.
#[allow(unsafe_code)]
mod frb_generated;
mod utils;
mod wire_decode;

pub mod api;

pub use utils::current_time;
// Exposed so `rust/fuzz` can fuzz the real decoder rather than a copy of it.
pub use wire_decode::{from_exact_bytes, fuzz_decode_wire_types};
