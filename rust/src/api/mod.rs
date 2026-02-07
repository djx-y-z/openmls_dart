//! FRB API modules for openmls.
//!
//! This module contains the public API exposed to Dart via Flutter Rust Bridge.
//! Each submodule should contain `pub` functions that will be generated as Dart bindings.
//!
//! Example:
//! ```rust
//! // In api/greeting.rs:
//! pub fn greet(name: String) -> String {
//!     format!("Hello, {}!", name)
//! }
//! ```
//!
//! Then add `pub mod greeting;` below.

pub mod init;

// Add your API modules here:
// pub mod greeting;
