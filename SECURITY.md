# Security

## Architecture Overview

This library uses **Flutter Rust Bridge (FRB)** with the **OpenMLS** Rust crate.

**Key security properties:**

- **Memory safety** is handled by Rust's ownership system
- **Cryptographic operations** are implemented in OpenMLS (with RustCrypto backend)
- **No manual memory management** in Dart - FRB handles all cleanup automatically
- **No `dispose()` calls needed** - Rust drops resources when they go out of scope (except `MlsEngine.close()` for deterministic key release)

## Security Scope

### In Scope

This package provides Dart bindings to openmls via Flutter Rust Bridge. The security scope covers:

- **Memory safety** of the FRB wrapper and the hand-written Rust in `rust/src/api/`
- **Correct API usage** of the underlying openmls primitives
- **Secret handling** across the FFI boundary (deterministic `dispose()`, keeping secrets in Rust where possible)
- **Supply-chain integrity** of the prebuilt native binaries (build pipeline, fail-closed download verification, release/tag protections)

### Out of Scope

The core cryptography / functionality is implemented and maintained upstream in openmls — the algorithm implementations, their constant-time / side-channel resistance, and protocol design. Report those to the upstream project (see **Upstream Security** below).

### Threat Model Limitations

Out of scope for this wrapper:

- **Physical side-channels** (power analysis, electromagnetic emissions)
- **Fault injection** (Rowhammer, voltage/clock glitching)
- **Hardware vulnerabilities**
- **Compromised host** — secrets that cross into Dart's GC heap cannot be reliably erased

## Security Considerations

### A: Memory Safety (Rust-handled)

With FRB, memory management is handled automatically:

```dart
// FRB Architecture - no cleanup needed
final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
final signerBytes = serializeSigner(
  ciphersuite: ciphersuite,
  privateKey: keyPair.privateKey(),
  publicKey: keyPair.publicKey(),
);
// keyPair is automatically cleaned up when no longer referenced
```

Rust's ownership system ensures:
- No use-after-free
- No double-free
- No memory leaks
- Deterministic cleanup

### B: Key Material Handling

Never expose key material in logs or errors:

```dart
// WRONG - exposes key material
print('Signer key: $signerBytes');
throw Exception('Failed with key: $keyBytes');

// CORRECT - no key material in logs
print('Generated new signing key pair');
throw Exception('Key operation failed');
```

### C: Encrypted Storage (MlsEngine)

`MlsEngine` stores all MLS state in an encrypted database. Encryption is handled automatically:

| Platform | Backend | Encryption |
|----------|---------|------------|
| Native | SQLCipher | AES-256 full-database encryption |
| Web (WASM) | IndexedDB | AES-256-GCM per-value encryption via `crypto.subtle` |

```dart
// Provide a 32-byte encryption key. Store it in platform secure storage
// (Keychain, Android Keystore, flutter_secure_storage).
final engine = await MlsEngine.create(
  dbPath: 'mls_data.db',    // file path on native, IDB name on web
  encryptionKey: myKey,       // 32-byte AES-256 key
);

// Use ":memory:" for ephemeral storage (testing only, data lost on drop)
final testEngine = await MlsEngine.create(
  dbPath: ':memory:',
  encryptionKey: testKey,
);
```

**Engine lifecycle:**

```dart
// Close the engine to release the DB connection and encryption key resources.
// After close, all operations fail immediately with "MlsEngine is closed".
await engine.close();
assert(engine.isClosed()); // synchronous check

// Re-create from platform secure storage on unlock
engine = await MlsEngine.create(dbPath: 'mls_data.db', encryptionKey: myKey);
```

`close()` is idempotent (safe to call multiple times) and provides deterministic resource release — the app controls exactly when the DB connection is closed, rather than relying on Dart's garbage collector. This is useful for screen lock / app background scenarios where encryption key material should be released from memory as soon as possible.

**Note:** `close()` does not guarantee cryptographic zeroization of key material. On native, SQLCipher manages its own key memory; on WASM, the `CryptoKey` becomes eligible for browser GC. See [Known Limitations](#known-limitations).

**Key management requirements:**

- **Secure key storage** - the 32-byte encryption key must be stored in platform secure storage, not in plain files
- **Access control** - only the app should read/write MLS state
- **Backup considerations** - MLS state includes forward-secrecy keys; restoring old state breaks protocol guarantees

**Native hardening (SQLCipher).** Every connection is opened with:

| Setting | Why |
|---------|-----|
| raw key `x'<hex>'` | your 32 bytes are the AES key — no PBKDF2 pass over a passphrase |
| `cipher_memory_security = ON` | SQLCipher wipes its own working buffers on free and keeps them out of swap; those buffers hold MLS plaintext while it is being encrypted |
| `journal_mode = DELETE` | never WAL — a WAL side file holds committed data that a file-level backup or crash can drop |
| `synchronous = FULL` | fsync on every commit |
| `locking_mode = EXCLUSIVE` | single writer, see below |
| file mode `0600` (Unix) | the file is created owner-only rather than with the process umask default (typically world-readable on desktops) |

`fullfsync` is deliberately **off**. On Apple platforms it additionally flushes the drive's own write cache, which measured **16 ms per MLS operation** against 318 µs without it — paid on every message sent and received. `synchronous = FULL` still fsyncs each commit, so the residual exposure is a power cut with data in a volatile drive cache, costing at most the last operation.

The wrapper zeroizes its own copies of stored values and of the hex-encoded key; the 32-byte key you pass in from Dart still lives in Dart's heap (see [Known Limitations](#known-limitations) #1).

**One engine per database file.** The database is locked exclusively: a second `MlsEngine` on the same file — another instance, isolate, or process — is refused with *"Database is already open by another connection or process"* instead of silently overwriting the first one's group state. `close()` releases the lock, and a second opener waits out a 5-second timeout before failing, which covers a brief overlap while the previous engine tears down. Do not share one database file between an app and an extension or background process. (An app-group shared container is doubly unsuitable on iOS: the system terminates a suspended app that still holds a lock on a file there — exception code `0xdead10cc`.)

Two mechanisms hold that lock, because on Unix neither is sufficient alone:

| mechanism | what it covers |
|---|---|
| `locking_mode = EXCLUSIVE` + a write transaction at open | SQLite's own locks, taken immediately so a second opener fails at `create()` rather than colliding on a later write |
| `<db_path>.lock`, held with `flock` for the engine's lifetime | keeps other engines out **across processes**, for as long as this one lives — which SQLite's locks alone do not |

The lock file exists because SQLite's locks are POSIX advisory (`fcntl`) locks, and POSIX releases *every* advisory lock a process holds on a file the moment that process closes *any* descriptor for it. SQLite compensates for descriptors it opened itself, but it cannot know about anyone else's. So a single ordinary read of the database file from elsewhere in your app — a backup copy, an integrity check, a crash reporter attaching the file — silently drops the exclusive lock while the engine is still running, with no error anywhere, and another process can then open the same database. A lock on a separate file is immune to that: `flock` binds the lock to one open file description rather than to the process, and nothing else ever opens that file.

What the lock file restores is precisely that **no second `MlsEngine` can open the database**. It does not put SQLite's own lock back: after such a read the engine keeps writing with no lock held on the database file itself, so a *non-engine* SQLite writer that has the key — a migration script, a `sqlite3` shell, a SQLite-based backup tool — is not excluded either before or after this change. Do not point one at a database an engine currently holds.

Consequences worth knowing:

- **An empty `<db_path>.lock` appears beside every database** on Unix (`0600`). The engine creates it and never deletes it — unlinking it would let the next opener create a fresh inode and lock that instead, which guards nothing. It holds no data, so it needs no special handling in backups; it is safe to delete only when no engine is running. Deleting it while one is running lets a second engine open the same database.
- **`":memory:"` databases take no lock file.** Each is private to its engine, so several may run at once.
- **A `file:` URI is rejected**, because the path it resolves to cannot be identified without parsing the URI's query parameters — such a database would silently get neither owner-only permissions nor a lock file. Pass a plain path.
- **Windows is not affected by the underlying defect** (its locks are mandatory and tied to the handle), and takes no lock file.

**Holding one engine open is fine.** The exclusive lock costs nothing while a single engine owns the file, and releasing it does not require lifecycle handling. Measured on macOS with an engine that is deliberately never closed: a Flutter hot restart drops the previous engine as the isolate tears down, and the next open completes in tens of milliseconds rather than waiting out the busy timeout; a `SIGKILL`ed process leaves behind neither a lock nor a journal, because the operating system releases file locks when a process exits. `close()` earns its keep in three places — handing the file to another engine, releasing the encryption key at screen lock, and switching accounts — not as a routine per-operation step.

**Anti-rollback storage (deployment requirement).** Encryption at rest does not protect *freshness*. Anyone who can replace the database file with an older copy of itself — a snapshot restore, a backup rollback, a filesystem-level attacker — makes the engine reuse MLS state it has already spent.

- Put the database on rollback-protected storage: a hardware monotonic counter, TPM 2.0 NV storage, or Android StrongBox, and refuse to run when the counter and the database disagree.
- **Sealing the key in hardware is not a fix.** Secure Enclave / StrongBox / TPM protect confidentiality; the same key still decrypts the stale copy.
- MLS is not defenceless: every application message carries a fresh random `reuse_guard` (RFC 9420 §6.3.2), so a single rollback produces a rejected message rather than a repeated keystream. But the guard is 32 bits — across a large or repeated rollback the birthday bound (~2¹⁶ messages under one key) makes an actual collision, and with it keystream reuse, plausible.
- **iOS provides no app-accessible monotonic counter**, so on iOS this cannot be fully closed today; it is an accepted limitation.

### D: Initialization

Always initialize the library before use:

```dart
void main() async {
  await Openmls.init();  // Initialize FRB runtime
  runApp(MyApp());
}
```

### E: Group State Integrity

MLS group state must be consistent. Avoid:

- Processing the same message twice (replay)
- Skipping messages (causes epoch mismatch)
- Restoring old group state from backup (breaks forward secrecy)

The library returns errors for protocol violations. Handle them appropriately rather than silently ignoring.

Concurrent Dart calls on one `MlsEngine` are safe: each operation loads its snapshot, runs, and writes back under an engine-wide lock, so overlapping calls queue instead of overwriting each other's state. Ordering across the *protocol* is still yours to get right — the lock decides who goes first, not what the correct order is.

## Supply Chain Security

- **SHA256 Checksums (fail-closed)**: pre-built native libraries are verified against a checksums file published in the same GitHub Release. Verification is **fail-closed** — if the checksums cannot be fetched or lack an entry for the archive, the build hook (`hook/build.dart`) **aborts** rather than loading an unverified binary. The escape hatch `OPENMLS_ALLOW_UNVERIFIED_DOWNLOAD=1` exists only for older releases with no checksums file.
- **Dependency Auditing**: `cargo audit` (`make rust-audit`) and `cargo deny` (`make rust-deny`) run in CI. `cargo-deny` enforces RustSec advisories, an allowed-license list, and a source allow-list restricted to crates.io and explicitly-listed git repositories (see `rust/deny.toml`).

- **Build Provenance (authenticity)**: SHA256 verifies *integrity* but not *authenticity* — the checksums file ships in the same release as the archive. To break that self-trust, every release archive is attested with [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations) (Sigstore, SLSA Build L2): CI signs a provenance statement proving each archive was built by this repository's tag-triggered `build-openmls.yml` workflow from a specific commit. Verify a downloaded archive with `gh attestation verify openmls_frb-<version>-<platform>.tar.gz --repo djx-y-z/openmls_dart`; for fully offline verification use the attached `openmls_frb-<version>.sigstore.jsonl` bundle with `--bundle` and a pre-fetched `gh attestation trusted-root`.

> **Known limitation:** attestation verification is manual — the build hook verifies SHA256 only (there is no Sigstore/DSSE implementation for Dart). Automatic (opt-in) verification via an installed `gh` CLI is a possible future hardening step.

### Release & build-trigger protection

The native binaries above are published by `build-openmls.yml`, triggered by a `openmls_frb-*` tag push or by manual dispatch. Two controls restrict who can cause a publish, mirroring the `pub.dev` environment that gates the pub.dev publish:

- **Tag protection** — a repository ruleset restricts creating, moving, and deleting **all tags** to Admins/Maintainers (and requires them signed), so a plain `write` collaborator cannot mint a release tag (`openmls_frb-*` / `v*`) or any other tag.
- **Approval gate** — the publishing job runs in the `native-build` environment, whose required reviewers must approve before any binary is released. Unlike the tag ruleset, this also covers the `workflow_dispatch` path.

Setup, the exact `gh` commands to apply / verify / roll back, and residual risks are in [`.github/rulesets/README.md`](.github/rulesets/README.md).

CI workflows run with a least-privilege `GITHUB_TOKEN` (`contents: read` by default; only the release-publishing jobs get the specific writes they need), third-party actions are pinned to commit SHAs, and pub.dev publishing uses OIDC — no long-lived publishing tokens exist.

## Build Security

- **Reproducible Builds**: CI builds are automated and reproducible
- **Minimal Dependencies**: We keep dependencies minimal and well-audited
- **LTO and Stripping**: Release builds use Link-Time Optimization and symbol stripping
- **Hardened profile**: the wrapper crate is compiled with `overflow-checks` (integer overflow panics instead of wrapping) and `unsafe_code = "deny"` on hand-written code
- **Static Analysis**: Dart (`dart analyze --fatal-infos`) and Rust (`cargo clippy`, warnings treated as errors) run in CI

## What's Handled by Rust/FRB

These concerns are handled automatically by the architecture:

| Concern | Handled By |
|---------|------------|
| FFI pointer management | Rust ownership |
| Resource cleanup | Rust drop semantics |
| Double-free prevention | Rust borrow checker |
| Buffer overflow prevention | Rust bounds checking |
| Use-after-free | Rust ownership |
| Cryptographic operations | OpenMLS + RustCrypto |
| Key zeroization | Rust (zeroize crate) |
| Encryption at rest (native) | SQLCipher |
| Encryption at rest (WASM) | Web Crypto API (`crypto.subtle`) |
| Key protection (WASM) | Non-extractable `CryptoKey` |

## Zeroing Sensitive Data

### SecureBytes wrapper (automatic zeroing)

```dart
// Wrap takes ownership - no extra copy
final secureData = SecureBytes.wrap(sensitiveBytes);
try {
  // ... use secureData.bytes ...
} finally {
  secureData.dispose(); // Immediate zeroing (recommended)
}

// Copy constructor - original NOT zeroed (caller responsible)
final secureCopy = SecureBytes(sensitiveBytes);
sensitiveBytes.zeroize(); // Zero the original yourself
```

### Manual zeroing extension

```dart
final sensitiveList = Uint8List.fromList([...]);
try {
  // ... use sensitiveList ...
} finally {
  sensitiveList.zeroize(); // Zero all bytes
}
```

### APIs that Return Sensitive Data

The following APIs return data that should be zeroized after use (via `SecureBytes.wrap()` or `.zeroize()`):

| API | Returns | Sensitivity |
|-----|---------|-------------|
| `MlsSignatureKeyPair.privateKey()` | Private signing key | HIGH — long-term key material |
| `serializeSigner()` | JSON with private key | HIGH — contains private key bytes |
| `engine.exportSecret()` | MLS exporter secret | HIGH — derived secret |
| `engine.getPastResumptionPsk()` | Resumption PSK | HIGH — pre-shared key |

These return `Uint8List` or `List<int>` due to FRB signature constraints. Callers must zeroize.

### Limitations

- Dart's garbage collector may copy data before zeroing occurs
- These utilities provide defence-in-depth, not absolute security guarantees
- For critical secrets, prefer keeping them in Rust (opaque types with `zeroize` crate)

## Web (WASM) Security

### Web Crypto API

On WASM, the database encryption key is imported as a **non-extractable `CryptoKey`** via `crypto.subtle.importKey()`. The raw key bytes are zeroized from WASM memory immediately after import.

**What this protects against:**
- Key extraction via `WebAssembly.Memory` inspection (key is not in WASM linear memory)
- Key extraction via JavaScript API (`crypto.subtle.exportKey()` fails for non-extractable keys)

**What this does NOT protect against:**
- Monkey-patching `crypto.subtle.encrypt/decrypt` to intercept plaintext (requires XSS)
- Browser extensions with page access
- Browser-level attacks (compromised browser binary)

### Web Deployment Recommendations

Since `crypto.subtle` protects the key but not the plaintext at the API boundary, preventing XSS is critical:

1. **Content Security Policy (CSP)** - Enable strict CSP headers:
   ```
   Content-Security-Policy: script-src 'self'; object-src 'none';
   ```
2. **HTTPS** - Required for `crypto.subtle` (also works on `localhost` for development)
3. **Minimize third-party scripts** - Each script on the page is a potential attack vector
4. **Subresource Integrity (SRI)** - Pin hashes of loaded scripts

### Secure Context Requirement

`crypto.subtle` requires a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts) (HTTPS or localhost). The library returns a clear error if `crypto.subtle` is unavailable.

## Known Limitations

1. **Dart VM memory:** Dart's garbage collector may copy data before Rust can zero it. This is a platform limitation. OpenMLS uses the `zeroize` crate for sensitive data on the Rust side.

2. **In-memory storage:** `MlsEngine.create(dbPath: ':memory:', ...)` creates an ephemeral in-memory database. All state is lost when the engine is dropped. Use a file path in production.

3. **Minimal `unsafe` code:** The wrapper layer has one `unsafe` usage: `Send + Sync` impl for `WasmCryptoKey` (wrapping `web_sys::CryptoKey`), which is safe because WASM is single-threaded. All other `unsafe` usage is in upstream OpenMLS, RustCrypto, and `web-sys` crates.

4. **Concurrency:** Operations on one `MlsEngine` are serialized internally — each load → operate → save runs under an engine-wide async lock — and a second connection to the same database file is refused, so concurrent calls cannot lose each other's state. What the library cannot decide for you is *protocol* order: handing `processMessage` messages out of order still breaks the group's epoch sequence.

5. **Storage atomicity:** Each operation's write-back is a single SQL transaction (native) or IDB transaction (WASM) — including `deleteGroup`, which writes the group's final state and purges its rows together — so a crash cannot apply half of one operation. Durability is `synchronous = FULL` without `fullfsync` (see Section C), so a power cut can still lose the last committed operation on Apple hardware. Database **migrations** are transactional — each runs in its own transaction with the version written atomically inside it, and a failed migration is fully rolled back.

6. **`test-utils` feature dependency:** The `openmls` and `openmls_basic_credential` crates are compiled with the `test-utils` feature enabled. This is required for `SignatureKeyPair::private()`, which powers the `privateKey()` API. The feature only enables accessor methods — no test-only code paths are activated in production.

7. **Automatic commit merging:** `processMessage` and `processMessageWithInspect` automatically merge staged commits after processing. There is no mechanism to inspect a commit and then reject it — this is by design, as MLS requires commits to be applied in order. `processMessageWithInspect` returns commit details (adds, removes, updates) for logging/UI purposes.

8. **Unconditional proposal acceptance:** `flexibleCommit` and `joinGroupExternalCommitV2` accept all pending proposals unconditionally (the internal proposal filter callback returns `true` for all proposals). Applications should validate proposals at the application layer before calling commit operations, or use `removePendingProposal` to reject unwanted proposals first.

9. **X.509 certificate chain validation:** The `MlsCredential.x509()` function does not validate certificate chains (expiration, signatures, revocation, trust anchors). The application layer must validate X.509 chains before use.

10. **serde_json intermediate buffers:** During signer serialization/deserialization, `serde_json` creates temporary `Vec<u8>` buffers containing sensitive data. These are dropped without zeroization. This is a platform limitation — Rust's allocator does not guarantee memory is not copied, so zeroizing every intermediate buffer provides limited benefit.

11. **Web Crypto plaintext visibility:** On WASM, while the encryption key is protected as a non-extractable `CryptoKey`, plaintext is briefly visible during `crypto.subtle.encrypt/decrypt` calls. An attacker with XSS could monkey-patch these methods. Mitigate with strict CSP headers (see [Web Deployment Recommendations](#web-deployment-recommendations)).

## Code Review Security Checklist

When reviewing code changes, verify:

- [ ] No `':memory:'` databases in production code
- [ ] No key material in logs or error messages
- [ ] `Openmls.init()` called before any operations
- [ ] `engine.close()` called on screen lock / app background
- [ ] One `MlsEngine` per database file — no second engine, isolate, or process on the same path
- [ ] Database stored on rollback-protected storage (see Section C)
- [ ] Encryption key stored in platform secure storage (not hardcoded)
- [ ] Error handling doesn't leak sensitive information
- [ ] MLS protocol messages processed in order
- [ ] Sensitive data in Dart uses `SecureBytes` or `.zeroize()` extension
- [ ] No hardcoded keys or secrets
- [ ] Web deployments use strict CSP headers

## Fuzzing

A `cargo-fuzz` harness lives under `rust/fuzz/`. Add one target per byte-parsing
entry point that handles untrusted input (deserializers, message parsers,
decryptors). A `Fuzz` workflow builds and runs every target on `rust/**` pull
requests and on a weekly schedule.

Seed the corpus with valid inputs so fuzzing starts from structurally-correct
data instead of discovering your formats blind: extend
`rust/fuzz/examples/gen_corpus.rs` whenever you add a target. CI regenerates
the corpus (`make fuzz-seed`) before every run.

```bash
make setup-fuzz                          # one-time: nightly toolchain + cargo-fuzz
make fuzz-list                           # list targets
make fuzz-seed                           # generate seed corpus under rust/fuzz/corpus/
make fuzz ARGS="mls_message -- -max_total_time=60"
```

## Upstream Security

This package wraps OpenMLS. For security issues in the underlying library:

- Check the upstream repository: [openmls/openmls](https://github.com/openmls/openmls)
- Security advisories may be published there first

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. Use [GitHub's private vulnerability reporting](https://github.com/djx-y-z/openmls_dart/security/advisories/new) to report the issue
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Development**: Depends on severity and complexity
- **Public Disclosure**: Coordinated with reporter after fix is available

## Security Updates

Subscribe to releases on this repository to receive notifications about security updates.
