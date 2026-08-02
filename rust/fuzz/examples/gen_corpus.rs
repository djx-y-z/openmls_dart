//! Seed-corpus generator for the fuzz targets — EXTEND ME.
//!
//! libFuzzer explores much faster when it starts from structurally-correct
//! inputs instead of discovering your wire formats blind. This program writes
//! such seeds to `corpus/<target>/` (the directory `cargo fuzz` picks up
//! automatically). Run it via `make fuzz-seed`; the Fuzz CI workflow runs it
//! before every fuzzing session.
//!
//! As you add fuzz targets, add a section per target that produces VALID
//! serializations of the objects that target parses, using your library's own
//! API. For example, for a `keys` target that deserializes key material:
//!
//! ```ignore
//! if let Ok(key_pair) = KeyPair::generate() {
//!     if let Ok(bytes) = key_pair.serialize() {
//!         write_seed(&base.join("keys"), "key_pair", &bytes);
//!     }
//! }
//! ```
//!
//! If a target dispatches on a selector byte (`match data[0] % N`), prefix
//! each seed with the selector the payload corresponds to.

use openmls_frb::api::credential::MlsCredential;
use std::fs;
use std::path::Path;

fn write_seed(dir: &Path, name: &str, bytes: &[u8]) {
    if let Err(e) = fs::create_dir_all(dir) {
        eprintln!("skip {}: {}", dir.display(), e);
        return;
    }
    let path = dir.join(name);
    if let Err(e) = fs::write(&path, bytes) {
        eprintln!("skip {}: {}", path.display(), e);
    } else {
        println!("wrote {} ({} bytes)", path.display(), bytes.len());
    }
}

fn main() {
    let base = std::env::args().nth(1).unwrap_or_else(|| "corpus".to_string());
    let base = Path::new(&base);

    // --- credential target (fuzz_targets/credential.rs) ---
    // A BasicCredential serialization is a valid seed: MlsCredential::deserialize
    // round-trips it. Cheap to produce via the public sync API (no provider init
    // required), so libFuzzer starts from a structurally-correct TLS credential.
    if let Ok(cred) = MlsCredential::basic(b"alice@example.com".to_vec()) {
        if let Ok(bytes) = cred.serialize() {
            write_seed(&base.join("credential"), "basic", &bytes);
        }
    }
    if let Ok(cred) = MlsCredential::basic(Vec::new()) {
        if let Ok(bytes) = cred.serialize() {
            write_seed(&base.join("credential"), "empty_identity", &bytes);
        }
    }

    // --- mls_message target (fuzz_targets/mls_message.rs) ---
    // A structurally-valid MLS protocol message requires full group state to
    // construct (signer + ratchet tree + epoch secrets), which is out of scope
    // for a standalone generator. Seed with an empty input and let libFuzzer
    // explore the MlsMessageIn TLS structure from there. For high-value seeds,
    // drop real serialized messages captured from a running group (e.g. the
    // bytes an integration test hands to process_message) into
    // corpus/mls_message/.
    write_seed(&base.join("mls_message"), "empty", b"");

    // --- wire_decode target (fuzz_targets/wire_decode.rs) ---
    // Same constraint as mls_message: a valid ratchet tree or key package needs
    // a provider, a signer and real group state to produce. Seed empty and let
    // libFuzzer explore. High-value seeds here are the `ratchetTreeBytes` and
    // key-package bytes an integration test passes to joinGroupFromWelcome /
    // addMembers — drop them into corpus/wire_decode/.
    write_seed(&base.join("wire_decode"), "empty", b"");

    println!("Seed corpus generation complete.");
}
