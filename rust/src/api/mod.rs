//! FRB API modules for openmls.

pub mod config;
pub mod credential;
pub mod init;
pub mod keys;
pub mod engine;
pub mod types;

// Temporary, and reverted with the pull request that carries it. This line
// exists to put a change inside `codegen-guard`'s scope predicate (`^rust/`)
// without moving the FFI surface, so the guard's regeneration path runs for
// the first time on a case whose expected verdict is known: `make codegen`
// produces no drift here, verified locally before the branch was pushed.
