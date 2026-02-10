//! openmls_frb - Rust bridge layer for openmls.
//!
//! Dart wrapper for OpenMLS — a Rust implementation of the Messaging Layer Security (MLS) protocol (RFC 9420)

#![allow(dead_code)]

mod encrypted_db;
mod snapshot_storage;
mod frb_generated;
mod utils;

pub mod api;

pub use utils::current_time;
