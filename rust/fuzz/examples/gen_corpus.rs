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

use openmls_frb::api::config::MlsGroupConfig;
use openmls_frb::api::credential::MlsCredential;
use openmls_frb::api::engine::MlsEngine;
use openmls_frb::api::keys::{MlsSignatureKeyPair, serialize_signer};
use openmls_frb::api::types::{MlsCiphersuite, MlsWireFormatPolicy};
use std::fs;
use std::future::Future;
use std::path::Path;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

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

/// Runs one of the engine's calls to completion.
///
/// Natively the engine never waits on anything outside its own call: SQLCipher
/// is synchronous, and nothing else holds its locks here. So polling until the
/// future is ready is all an executor has to do, and this needs none.
///
/// Should that ever change, the call fails after a minute rather than spinning
/// on: the Fuzz workflow runs this with no time limit of its own but GitHub's,
/// six hours.
fn block_on<T>(future: impl Future<Output = Result<T, String>>) -> Result<T, String> {
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut future = pin!(future);
    let mut context = Context::from_waker(Waker::noop());
    loop {
        if let Poll::Ready(output) = future.as_mut().poll(&mut context) {
            return output;
        }
        if Instant::now() >= deadline {
            return Err("the engine's call was still waiting after a minute".to_string());
        }
        std::thread::yield_now();
    }
}

/// One participant of a seed group: an engine on an in-memory database, and
/// a signer on the group's suite.
struct Member {
    engine: MlsEngine,
    signer: Vec<u8>,
    public_key: Vec<u8>,
    identity: Vec<u8>,
}

impl Member {
    fn new(name: &str, suite: fn() -> MlsCiphersuite) -> Result<Self, String> {
        let keys = MlsSignatureKeyPair::generate(suite())?;
        let signer = serialize_signer(suite(), keys.private_key(), keys.public_key())?;
        let engine = block_on(MlsEngine::create(":memory:".to_string(), vec![7; 32]))?;
        Ok(Self {
            engine,
            signer,
            public_key: keys.public_key(),
            identity: name.as_bytes().to_vec(),
        })
    }
}

fn config(suite: fn() -> MlsCiphersuite, plaintext: bool) -> MlsGroupConfig {
    let mut config = MlsGroupConfig::default_config(suite());
    config.wire_format_policy = if plaintext {
        MlsWireFormatPolicy::Plaintext
    } else {
        MlsWireFormatPolicy::Ciphertext
    };
    config
}

/// A key package as the network carries one: in an MLSMessage (RFC 9420 §6),
/// version mls10 (`0x0001`), wire format mls_key_package (`0x0005`). The
/// engine returns the bare KeyPackage.
fn mls_message_of_key_package(key_package: &[u8]) -> Vec<u8> {
    let mut message = vec![0x00, 0x01, 0x00, 0x05];
    message.extend_from_slice(key_package);
    message
}

/// The objects a two-member group produces on `suite`, as the targets parse
/// them: `(name, bytes, is an MLSMessage)`.
///
/// With `plaintext`, handshake messages travel as PublicMessages; otherwise as
/// PrivateMessages. Application messages are PrivateMessages either way.
fn group_objects(
    suite: fn() -> MlsCiphersuite,
    plaintext: bool,
) -> Result<Vec<(&'static str, Vec<u8>, bool)>, String> {
    let alice = Member::new("alice", suite)?;
    let bob = Member::new("bob", suite)?;
    let group = block_on(alice.engine.create_group(
        config(suite, plaintext),
        alice.signer.clone(),
        alice.identity.clone(),
        alice.public_key.clone(),
        None,
        None,
    ))?
    .group_id;
    let key_package = block_on(bob.engine.create_key_package(
        suite(),
        bob.signer.clone(),
        bob.identity.clone(),
        bob.public_key.clone(),
        None,
    ))?
    .key_package_bytes;
    let added = block_on(alice.engine.add_members(
        group.clone(),
        alice.signer.clone(),
        vec![key_package.clone()],
    ))?;
    block_on(bob.engine.join_group_from_welcome(
        config(suite, plaintext),
        added.welcome.clone(),
        None,
        bob.signer.clone(),
    ))?;
    let tree = block_on(alice.engine.export_ratchet_tree(group.clone()))?;
    let group_info = block_on(alice.engine.export_group_info(group.clone(), alice.signer.clone()))?;
    let application = block_on(alice.engine.create_message(
        group.clone(),
        alice.signer.clone(),
        b"a seed".to_vec(),
        Some(b"with additional data".to_vec()),
    ))?
    .ciphertext;
    let update = block_on(bob.engine.self_update(group.clone(), bob.signer.clone()))?.commit;
    block_on(alice.engine.process_message(group.clone(), update.clone()))?;
    // Last: a pending proposal would ride along in any later commit.
    let proposal = block_on(alice.engine.propose_remove(group.clone(), alice.signer.clone(), 1))?
        .proposal_message;

    Ok(vec![
        ("key_package", mls_message_of_key_package(&key_package), true),
        ("key_package_bare", key_package, false),
        ("welcome", added.welcome, true),
        ("add_commit", added.commit, true),
        ("group_info", group_info, true),
        ("ratchet_tree", tree, false),
        ("application", application, true),
        ("update_commit", update, true),
        ("remove_proposal", proposal, true),
    ])
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

    // --- mls_message and wire_decode (fuzz_targets/mls_message.rs, wire_decode.rs) ---
    // What a real group sends, made by the engine itself: two members on an
    // in-memory database, on three suites (the mandatory one, P-256, and the
    // post-quantum X-Wing, whose keys are much larger), with handshakes sent
    // encrypted and in the clear. `mls_message` parses MLSMessages;
    // `wire_decode` tries each input as an MLSMessage, a ratchet tree and a key
    // package, so it gets everything. An empty input stays as a seed of each.
    write_seed(&base.join("mls_message"), "empty", b"");
    write_seed(&base.join("wire_decode"), "empty", b"");
    let suites: [(&str, fn() -> MlsCiphersuite); 3] = [
        ("x25519", || MlsCiphersuite::Mls128DhkemX25519Aes128gcmSha256Ed25519),
        ("p256", || MlsCiphersuite::Mls128DhkemP256Aes128gcmSha256P256),
        ("xwing", || MlsCiphersuite::Mls256XwingChacha20poly1305Sha256Ed25519),
    ];
    for (suite_name, suite) in suites {
        for plaintext in [false, true] {
            let wire = if plaintext { "public" } else { "private" };
            // A panic skips its group as an error does, and the other groups
            // still write their seeds. This crate turns debug assertions on
            // for every dependency, so an assertion upstream can fire here.
            let made = std::panic::catch_unwind(|| group_objects(suite, plaintext))
                .unwrap_or_else(|_| Err("it panicked".to_string()));
            match made {
                Ok(objects) => {
                    for (name, bytes, is_message) in objects {
                        let seed = format!("{suite_name}_{wire}_{name}");
                        if is_message {
                            write_seed(&base.join("mls_message"), &seed, &bytes);
                        }
                        write_seed(&base.join("wire_decode"), &seed, &bytes);
                    }
                }
                // A seed is a head start, never a requirement: the fuzzers
                // still run from what was written.
                Err(e) => eprintln!("skip the {suite_name} {wire} group: {e}"),
            }
        }
    }

    println!("Seed corpus generation complete.");
}
