## [Unreleased]

### For Users

#### ✨ Highlights

- **Judge a commit before it takes effect** — `inspectMessage` reports what a
  commit would do, with who proposed each change and whose leaves it removes,
  and applies nothing.
- **Merge an own commit only once the delivery service took it** —
  `FlexibleCommitOptions.keepPending`.
- **Group-context extensions OpenMLS defines are passed typed** — so an
  application's own extension can be required with `RequiredCapabilities`.
- **On macOS, `dart run`, `dart test` and `flutter test` work from a deep
  project path** — the native library now leaves room for any path in its
  install name; see *Fixed*.
- **openmls v0.9.2** — unchanged this release.
- **openmls_frb v2.4.0** — Rust FFI bindings

#### Added

- **`MlsEngine.inspectMessage`** — processes a message like
  `processMessageWithInspect` and reports the same, without merging a commit,
  storing a proposal, advancing a ratchet or writing to storage. MLS lets any
  member commit any Add or Remove and leaves who may to the application; with
  this, an application judges a commit by its own policy and processes it
  only when it accepts it. A refused commit is never processed by the member
  that refuses it — which keeps only that member in the current epoch: if
  others accept it, the refuser is the one left behind (see `SECURITY.md`).
- **`StagedCommitInfo.removeCredentials`** — the credential of each removed
  member, read before the merge, one per `removeIndices` entry: after the
  merge those leaves are gone.
- **`StagedCommitInfo.proposals`** (`StagedProposalInfo`) — every proposal
  the commit applies, with its own sender and whether it came by reference.
  A commit can carry other members' proposals, so the committer is not
  necessarily the author of each change.
- **`StagedCommitInfo.committerCredential`** — the committer's new leaf
  credential when the commit has an update path, which can replace it.
- **`StagedCommitInfo.groupContextExtensions`** — every extension of the
  group context the commit leads to, the types OpenMLS interprets itself
  (`RequiredCapabilities`, `ExternalSenders`, …) included, in wire form.
- **`StagedCommitInfo.externalSenders`** (`MlsExternalSenderInfo`) — the
  external senders that group context admits, decoded: each may propose adds
  and removes without being a member. **`decodeExternalSenders`** decodes the
  same from an extension's data.
- **Per-proposal detail in `StagedProposalInfo`** — `sender`
  (`MlsSenderInfo`: member, external sender, new member), `leaf` (the
  credential, signature and encryption key an Update or Add introduces),
  `affectedMember` (the member a Remove takes out or an Update replaces, as
  this client's tree has it) and `extensions` (what a GroupContextExtensions
  proposal sets). OpenMLS does not check that an Update keeps the proposer's
  identity; with `leaf` next to `affectedMember` the application can.
- **`ProcessedMessageInspectResult.sender` and `.proposalInfo`** — the
  authenticated sender of any inspected message, external senders included
  (`senderIndex` is `null` for those), and for a proposal message the same
  detail as a commit's proposals, before it is stored.
- **`FlexibleCommitOptions.keepPending`** (default `false`) — leaves the
  commit pending instead of merging it, for `mergePendingCommit` once the
  delivery service accepted it or `clearPendingCommit` when another member's
  commit won the epoch. Processing that member's commit also replaces it.

#### Changed

- **Extensions are decoded as OpenMLS decodes received ones**
  (`extensions_from_mls`) — a type OpenMLS defines (`RequiredCapabilities`
  0x0003, `ExternalSenders` 0x0005, …) becomes its typed variant instead of an
  unknown extension, wherever the API takes `MlsExtension`s: group creation,
  key packages, leaf nodes, group-context updates and proposals, flexible
  commits. OpenMLS looks for the typed variants: an application's
  group-context extension used to be refused for want of a
  `RequiredCapabilities` listing it, which could not be given. A malformed
  extension of such a type is now an `Invalid extension 0x….` error at the
  call.
- **`StagedCommitInfo` has five more fields, `ProcessedMessageInspectResult`
  two** — all optional in their constructors (empty lists, `null`), so code
  that builds one itself, a test double say, compiles unchanged.
- **Own messages that cannot be read back say so more helpfully** — a
  commit of this member's fanned back while it is pending now points to
  `mergePendingCommit` under the ciphertext wire format too. The hint is
  wording only: the content type it reads is not authenticated before
  decryption, and any member can send a message that names this one as
  its sender, so nothing acts on it and the error says the message proves
  nothing — merge on the delivery service's confirmation, not on it.
- **`flexibleCommit` refuses to run while a commit is pending** — with or
  without `keepPending`, which is what lets a commit stay pending. OpenMLS's
  commit builder replaced a pending commit silently; had the first already
  reached other members and been replaced, the group would have forked onto
  incompatible epoch secrets. Merge or clear the pending commit first.
- **The native library's dependencies move to their latest compatible
  releases** (`rust/Cargo.lock`, #72) — Dependabot's 47 updates, none of them
  an openmls crate and none adding or removing one: among them the
  post-quantum `ml-kem` 0.3.2 → 0.3.3 and `x-wing` 0.1.0 → 0.1.1, `sha2`
  0.11.0 → 0.11.1, `der` 0.8.3, `spki` 0.8.1, `rand` 0.10.3, `zerocopy`
  0.8.63, `tokio` 1.54.1, and `cc` 1.4.4 → 1.10.0, which compiles the bundled
  SQLCipher and OpenSSL. CI built and tested the library with them on Linux,
  macOS and Windows, cross-compiled it for Android, type-checked it for iOS,
  and passed `cargo audit`, `cargo deny` and the fuzz targets. Takes effect
  with the next `openmls_frb` release.

#### Fixed

- **On macOS, `dart run`, `dart test` and `flutter test` no longer fail from a
  deep project path** (`rust/build.rs`) — each copies the native library into
  the project and rewrites its install name to the copy's absolute path
  (`install_name_tool -id`), and the released libraries left room in their
  Mach-O header for about 180 characters of it: 183 for the arm64 build, 199
  for x86_64. A project whose copy landed deeper failed with "larger updated
  load commands do not fit". `openmls_frb` is now linked with
  `-headerpad_max_install_names` on Apple targets, which leaves room for any
  path, and the release workflow refuses a library without that room.
  Measured on a local build: room for 3,255 characters instead of 183, a
  library no larger, and consumers at a 186-character path, which failed under
  both `dart run` and `flutter test`, now pass, as do ones at 400. Flutter app
  builds for macOS and iOS were never affected: they install the library as a
  framework under a short `@rpath/` name. Takes effect with the next
  `openmls_frb` release.

#### Documentation

- **Commit refusal, forks and Welcome ordering** — `inspectMessage`,
  `CommitResult.welcome`, `FlexibleCommitOptions.keepPending` and
  `SECURITY.md` (item 7, which said there was no inspect-then-reject path)
  now state that a refusal is local, that a delivery service can fork a group
  and `groupEpochAuthenticator` detects it, that reported credentials are
  claims to verify, that inspecting an application message consumes nothing,
  and that a Welcome goes out only after the delivery service accepted its
  commit.
- **A commit's GroupInfo waits for the delivery service too** —
  `CommitResult.groupInfo` and `FlexibleCommitOptions.keepPending` say so: a
  party joining by external commit from a GroupInfo published early enters an
  epoch that may never happen. And `MlsSenderInfo.index` of an external sender
  says which list it counts in: the `ExternalSenders` the message was verified
  against, which for a commit's proposals is the one before the commit, not
  `StagedCommitInfo.externalSenders`.

### For Contributors

#### Added

- **Tests that hold #57's guarantees from the outside**
  (`test/inspect_guarantees_test.dart`) — written when it was merged, apart
  from its own tests: `inspectMessage` leaves the database file byte for byte
  as it was, for a commit, a proposal and an application message, and the
  same bytes then process, while `processMessageWithInspect` does apply the
  commit it reports; `decodeExternalSenders` refuses every truncation of a
  valid body, lengths that claim more than follows and trailing data, and
  answers boundary mutations and 2,000 random inputs without a panic; no call
  that makes a commit replaces a pending one, which then merges as the commit
  the others applied; and an `ExternalSenders` change proposed on its own
  shows in the inspected proposal and in the commit that applies it.

#### Changed

- **Copier template v4.18.0 → v4.19.0** — `repair-build` refuses a named run
  built from a fork, by the run's `head_repository`, instead of checking out
  the fork's tree beside the agent's provider key; an AI provider key holding
  anything but printable ASCII is refused when it is read, by the name of its
  variable, so `dart:io`'s header error can no longer carry it into a
  template-update pull request; an upstream `RELEASE_NOTES.md` or
  `CHANGELOG.md` that could not be fetched (a rate-limited anonymous request
  answers 403, and `curl -s` exits 0) is reported as unknown instead of as "No
  release notes were published"; `finalizeChangelog` rewrites only the
  footer's `[Unreleased]:` link and refuses a second one; `publish.yml` passes
  the release notes behind a random delimiter; `CONTRIBUTING.md` names the bot
  branches the signing ruleset leaves out; and `verify_release_artifacts.py`
  refuses an Apple library with less than 1,024 characters of install-name
  room. One conflict, in `CONTRIBUTING.md`: the template places its
  *Releasing* and *Repository rulesets* sections elsewhere than this file
  does, so this file's layout was kept with the template's one changed line.

## [3.2.2] - 2026-10-26

### For Users

#### ✨ Highlights

- **A peer can no longer crash the application with nested extensions** —
  GHSA-gc79-23g3-8g52, fixed upstream in openmls 0.9.1; every earlier release
  of this package is affected.
- **A member an external commit removes no longer stays in the group** —
  GHSA-94v4-rg25-x625, fixed upstream in openmls 0.9.2; every earlier release
  of this package is affected, and upgrading does not repair a group it
  already damaged; see *Security*.
- **A malformed X-Wing key from a peer no longer panics** — RUSTSEC-2026-0331,
  on the 0x004D suite only.
- **The P-256 and P-384 suites carry an open constant-time advisory** —
  RUSTSEC-2026-0387 (`crypto-bigint` 0.5.5), accepted until OpenMLS moves to
  `p256`/`p384` 0.14; the other ten suites are unaffected. See *Security*.
- **Async calls no longer stop answering when another isolate shuts down** —
  native platforms, also when an application initializes several
  flutter_rust_bridge packages, in any order; see *Fixed*.
- **On the web, `Openmls.init()` throws when the WASM module is not served** —
  instead of waiting forever; see *Fixed*.
- **`hooks` and `code_assets` 2.x are admitted beside 1.x** — each Flutter
  resolves the major it supports; see *Changed*.
- **openmls v0.9.2** — two patch releases: 0.9.1 with the
  GHSA-gc79-23g3-8g52 fix, 0.9.2 with the GHSA-94v4-rg25-x625 and
  GHSA-p276-g3f3-wwgh fixes, and nothing else this package's API exposes.
- **openmls_frb v2.3.2** — Rust FFI bindings

#### Changed

- **The build hook uses a local build only when `make build` made it from the
  current crate version and lock file** (`hook/build.dart`, `Makefile`) — a
  library in `rust/target/release/` or `rust/target/debug/` took priority over
  the released one on the sole condition that it existed, so one left over
  from an earlier crate loaded silently, and `rustContentHash`, which hashes
  only the names of the bridged functions, could not notice a moved wire
  format. `make build` now writes `rust/target/release/.crate-version`, as
  `make build-web` already did beside the WASM module, and both leave
  `.cargo-lock` beside the stamp, a copy of the `rust/Cargo.lock` the build
  was made from: an upstream update moves the dependencies but not the crate
  version, so a build from before it passed the version check and ran the
  previous upstream code. The hook refuses a missing or stale stamp, and a
  copy that differs from `rust/Cargo.lock`, with a `HookException`, and no
  longer reads `rust/target/debug/`. `make build` also drops the hook's cached
  result for this package (`.dart_tool/hooks_runner/openmls/`), which kept
  `dart test` on a downloaded library after a host build. Only a local build
  is affected — the published package carries no `rust/target/` — and one
  built before this change is refused until `make build` (or
  `make build-web`) runs again.
- **`hooks` and `code_assets` admit 2.x as well as 1.x** (`pubspec.yaml`) —
  `^1.0.0` held every application on 1.x, and pub.dev took 10 of its 160
  points for it on 3.2.1 ("Support up-to-date dependencies"). The range is
  now `>=1.0.0 <3.0.0`, so each Flutter resolves the major it supports:
  Flutter 3.38 to 3.44 pin `meta` below the 1.19.0 that `hooks` 2.1 needs, and
  an application on 3.38.4 resolves `hooks` 2.0.2 with `code_assets` 1.2.1
  (measured on `example/`), while this package resolved on its own takes
  `hooks` 2.2.0 with `code_assets` 2.1.0. `hook/build.dart` needs no change:
  it analyzes clean and its tests pass with 2.2.0/2.1.0, 2.0.2/1.2.1 and
  1.0.1/1.0.0, and the whole suite passes with 2.2.0/2.1.0 and with
  1.0.1/1.0.0. A 3.x is a migration again, and Dependabot holds it back.

#### Security

- **A peer can no longer crash the application with nested extensions
  (GHSA-gc79-23g3-8g52)** — fixed in openmls 0.9.1 (`rust/Cargo.toml`,
  `rust/Cargo.lock`). openmls 0.9.0 decoded an extension's body before
  checking that its type is allowed where it appears, so a `ratchet_tree`
  extension inside a leaf node was decoded in full, its leaf nodes and their
  extensions included, one stack frame deeper per level of nesting. Input
  nested deeply enough ran the stack out, which is not a panic, so no
  `PanicException` stands in for it. In most environments the process ends;
  through a C FFI, as here, or in WebAssembly, the advisory says the outcome
  depends on the environment and linker configuration, at worst memory
  corruption. Neither was measured here. Every call that decodes
  a message, `Welcome`, `GroupInfo`, ratchet tree or key package from a peer
  was exposed, whatever the ciphersuite: incoming messages (`processMessage`,
  `processMessageWithInspect` and the synchronous `mlsMessageExtractGroupId`,
  `mlsMessageExtractEpoch` and `mlsMessageContentType`), the `Welcome`,
  `GroupInfo` and ratchet tree of a join, a `Welcome` that is only inspected
  (`inspectWelcome`, `exportWelcomeSecret`), and key packages (`addMembers`,
  `proposeAdd`, `keyPackageLifetime` and the rest). 0.9.1 checks the type
  first, so the same input fails with an ordinary error. Where that error
  carries the decoder's message (ratchet trees, key packages, the `GroupInfo`
  of an external join, unencrypted handshake messages), it now names the
  extension type that is out of place, where 0.9.0 said "Found duplicate
  extensions". The fix is upstream's
  ([advisory](https://github.com/openmls/openmls/security/advisories/GHSA-gc79-23g3-8g52):
  high, CVSS 4.0 8.7, CWE-674). Every native library released before this
  one carries an affected openmls, `openmls_frb` 2.3.1 (package 3.2.1)
  included; `SECURITY.md` (Known Limitations #14) covers them.
- **A member an external commit removes no longer stays in the group
  (GHSA-94v4-rg25-x625)** — fixed in openmls 0.9.2 (`rust/Cargo.toml`,
  `rust/Cargo.lock`). When an external commit removed a member and the
  removal truncated the ratchet tree, adding the joiner's own leaf extended
  the tree again with the removed leaf, and some parent nodes, restored from
  before the commit. The committer and every member processing the commit
  computed the same tree, so nothing diverged, but the removed leaf kept its
  encryption key and later commits kept encrypting path secrets to it: a
  party that holds the removed client's state and keeps processing the
  group's handshake messages can derive the secrets of every later epoch
  until the leaf is removed again. In this package the commit is a resync —
  `joinGroupExternalCommit` and `joinGroupExternalCommitV2` remove any member
  that has the joiner's signature key — or another client's external commit
  that includes a SelfRemove (`leaveGroupViaSelfRemove`) by reference, and
  every member that processes either with `processMessage` or
  `processMessageWithInspect` computes the same tree. Measured on 0.9.1, with
  members at leaves 0 to 3, leaf 2 removed and the member at leaf 3 rejoining
  by either call: `groupMembers` still listed index 3, which
  `processMessageWithInspect` had reported in `removeIndices`, and while two
  leaves shared a signature key no new member could join, by Welcome or by
  external commit. 0.9.2 leaves the regrown part of the tree blank, as RFC
  9420 requires; the same steps list three members. Only groups that accept
  external commits are affected, and upgrading does not repair a tree the bug
  already wrote: a group stays affected until a member removes the restored
  leaf with `removeMembers`, an ordinary commit every version accepts
  (`SECURITY.md`, Known Limitations #16). Per the advisory, an external commit
  that meets the bug is rejected between clients on 0.9.2 and clients on an
  affected openmls, this package up to 3.2.1 included, with a path length or
  confirmation tag mismatch, rather than leaving them on different trees
  ([advisory](https://github.com/openmls/openmls/security/advisories/GHSA-94v4-rg25-x625):
  medium, CWE-459).
- **A malformed X-Wing key from a peer no longer panics (RUSTSEC-2026-0331)**
  — up to `openmls_frb` 2.3.1, an X-Wing (0x004D) public key shorter than
  1184 bytes made the next encryption to it panic inside `libcrux-kem` (0.0.9
  from `openmls_frb` 2.1.0, 0.0.7 before it, with the same defect): a
  `PanicException` on native, and on the web an abort that left the database
  unusable until the page was reloaded. The key is peer data — the init key
  of a key package being added, another member's tree node, the `GroupInfo`
  of an external join. The native library now checks its length
  before libcrux sees it, and the operation fails with the ordinary error the
  fixed `libcrux-kem` 0.0.10 returns. Nothing leaked and nothing could be
  forged (CVSS `VC:N/VI:N/VA:H`), and no other suite touches libcrux. The
  crate itself stays at 0.0.9: OpenMLS pins it — 0.9.2 too — and the fix
  needs an OpenMLS release that does not exist yet. It is recorded in
  `.cargo/audit.toml` and `rust/deny.toml` together with RUSTSEC-2026-0329
  (`libcrux-hmac-drbg`) and RUSTSEC-2026-0330 (`libcrux-kem`), which nothing
  in the dependency graph can reach; `SECURITY.md` (Known Limitations #13)
  covers the releases that still panic.
- **The post-quantum suites' constant-time helper is fixed
  (RUSTSEC-2026-0385)** — `ctutils` 0.4.2 → 0.4.5 (`rust/Cargo.lock`).
  RustCrypto's ML-KEM decapsulation selects its result with it, and ML-DSA's
  signing arithmetic compares and selects with it, on secret values, so every
  post-quantum suite except X-Wing (0x004D, which runs on libcrux) relies on
  it. Before 0.4.4 its masks could compile to a branch on commonly used
  platforms, and its `u128` comparisons did on 32-bit targets; a branch on a
  secret value can leak it through a side channel. 0.4.4 fixes both, and
  0.4.5 also hardens `Choice` composition and Thumb-1 comparisons.
  `openmls_frb` 2.1.0 to 2.3.1 carry 0.4.2; nothing was measured here
  ([advisory](https://rustsec.org/advisories/RUSTSEC-2026-0385)).
- **The P-256 and P-384 suites carry an open constant-time advisory
  (RUSTSEC-2026-0387)** — `crypto-bigint` 0.5.5, in every release since
  1.0.0, has operations meant to be constant-time that could compile to
  branches on secret values, depending on the compiler and CPU. Its fix,
  0.7.6, cannot be taken: `elliptic-curve` 0.13 requires 0.5, and only an
  OpenMLS release on `p256`/`p384` 0.14 lifts that. Reviewed before it was
  accepted: P-256's scalar arithmetic is crypto-bigint's, so every signature
  on `mls128DhkemP256Aes128GcmSha256P256` (0x0002) and
  `mls128Mlkem768Aes256GcmSha384P256` computes with the private key and the
  nonce through its modular addition and subtraction, which turn a borrow
  into a mask with no optimization barrier — the construct the fixed release
  guards. On `mls192Mlkem1024Aes256GcmSha384P384` the arithmetic is
  fiat-crypto, and crypto-bigint only range-checks, zero-checks and encodes
  the secrets; the other ten suites do not run it on secret data. Whether
  the compiled code branches was not measured. The advisory is accepted in
  `.cargo/audit.toml` and `rust/deny.toml`, and `SECURITY.md` (Known
  Limitations #15) says which suites to prefer
  ([advisory](https://rustsec.org/advisories/RUSTSEC-2026-0387)).
- **GHSA-p276-g3f3-wwgh did not reach this package** — every openmls this
  package has shipped advanced the claimed sender's ratchet before decrypting
  a message's content and verifying its signature, and stored it before the
  signature check, so a member could send a message in another member's name
  that every receiver rejected and that still made the genuine sender's
  messages — commits included — fail for the rest of the epoch. Here a failed
  call writes nothing back: every operation works on a snapshot of the stored
  state, which `processMessage` and `processMessageWithInspect` have dropped
  on any error since 1.0.0. Measured on 0.9.1 through both calls: after a
  message at generation 6 that decrypted and then failed signature
  verification, the sender's messages 0 to 5 all decrypted; with
  `processMessage` patched to write the snapshot back on error, messages 0
  and 1 were lost as too old. 0.9.2 fixes it upstream by applying the ratchet
  step only once a message is processed successfully
  ([advisory](https://github.com/openmls/openmls/security/advisories/GHSA-p276-g3f3-wwgh):
  low, CVSS 3.1 3.7, CWE-460).

#### Fixed

- **Async calls no longer stop answering when another isolate shuts down**
  (`lib/src/openmls.dart`, `lib/src/platform/platform_io.dart`,
  `lib/src/platform/platform_web.dart`) — flutter_rust_bridge sends every
  Rust-to-Dart message (an async call's result, a store callback) through one
  process-wide `Dart_PostCObject` pointer per native library, and replaces it
  with a no-op when that library's count of live isolates drops to zero. An
  isolate missing from the count kept its sync calls, while every async call
  waited for an answer that had been dropped, and flutter_rust_bridge 2.13.0
  leaves one out in two ways. `RustLib.init()` installs the pointer *before*
  it counts the new isolate, so the last other counted isolate shutting down
  in between left the no-op behind. And the watcher that counts an isolate is
  one per isolate for every flutter_rust_bridge library, so an isolate is
  counted only by the first library it initializes: when the main isolate had
  initialized another flutter_rust_bridge package first, a worker that used
  openmls alone — a `compute()` or `Isolate.run` worker included — took
  openmls's count to zero for the whole process, once the exited worker's
  watcher was garbage-collected. `Openmls.init()` now counts its isolate in
  openmls's own library before `RustLib.init()`, through flutter_rust_bridge's
  `frb_create_shutdown_callback`, which closes both; the order in which an
  application initializes its flutter_rust_bridge packages no longer matters
  for this one. Measured with a copy of the library initialized first in the
  other package's place: once a worker that used only openmls had exited and
  been collected, the main isolate's next async call went unanswered for 15 s
  with the previous code and was answered with this one; openmls alone, five
  workers in a row, was answered with both. The symbol is internal to
  flutter_rust_bridge, which this package pins to 2.13.0; a version that
  renamed it would make `init()` fail rather than hang. Two things stay open:
  a finalizer on another thread that has counted to zero and not yet written
  the no-op, which only flutter_rust_bridge can close, and another
  flutter_rust_bridge package without this change, which still needs the same
  initialization order in every isolate for itself. The web has neither the
  pointer nor the count.
- **On the web, `Openmls.init()` throws when the WASM module is not served,
  instead of waiting forever** (`lib/src/openmls.dart`,
  `lib/src/platform/platform_web.dart`) — flutter_rust_bridge loads
  `pkg/openmls_frb.js` through a `<script>` tag and waits for its `load` event
  with no error path or timeout, so a missing module — a 404, or the app's own
  HTML page that a development server sends in its place with a 200 — left
  `init()` pending with nothing reported. `init()` now fetches the script
  first and throws a `StateError` naming it, its HTTP status and content type,
  and the ways out, when the answer is not a success or is HTML. A request
  that fails outright, under a Content Security Policy that forbids `fetch`
  say, throws nothing, and the loader runs as before. Measured in headless
  Chrome: with no module served, `init()` threw at once with
  `pkg/openmls_frb.js is not served (HTTP 404, text/plain; charset=utf-8)`;
  with it served, `init()` completed, and a sync call
  (`supportedCiphersuites()`) and an async one (`MlsEngine.create`) answered.

#### Documentation

- **The README says when `web/pkg/` can be left empty, and what `init()` then
  does** (`README.md`, *Known Limitations*) — a `flutter run -d chrome` that
  skips the build hook after a run for another platform is Flutter 3.38 to
  3.41's: 3.38.4 runs the hooks through the `dart_build` target, whose stamp
  does not include the target platform, while 3.44.8 and 3.47.4 call them
  directly with the target platform (3.41 not checked here). Where it still
  happens, `init()` throws the `StateError` above; the README no longer says
  the call stays pending.
- **`SECURITY.md` no longer says the tag ruleset stops a `write`
  collaborator** — it reserved tags to "Admins/Maintainers", but the
  ruleset's bypass list also held role 4, which GitHub names `write`. The list
  now holds Admin only (`.github/rulesets/protect-release-tags.json`), and the
  text says that Admins bypass the ruleset's signature rule as well; the
  release scripts sign their tags.
- **`THIRD_PARTY_NOTICES.txt` gives the openmls crates the canonical MIT
  text** — the file ships in every native archive and in the package. With
  openmls taken from crates.io (see *For Contributors*), its seven openmls
  crates carry the MIT text with `Copyright (c) OpenMLS Authors`, composed
  from the crate metadata, because a published `.crate` has no LICENSE file;
  until now it quoted the repository's LICENSE, which names the year 2020.
  The licence terms are unchanged.

### For Contributors

#### Added

- **A regression test for GHSA-94v4-rg25-x625**
  (`test/group_lifecycle_test.dart`) — a resync by `joinGroupExternalCommit`
  and by `joinGroupExternalCommitV2`, in a group where the removal it carries
  truncates the tree, must leave three members and no signature key twice.
  Both cases fail on openmls 0.9.1, which still lists the removed leaf.

#### Changed

- **copier template adopted: v4.15.1 -> v4.15.2** — workflow fixes.

  `.copier-answers.yml` records the new template revision.

  **The agent workflows now use `anthropics/claude-code-action` v1.0.261**
  (`.github/workflows/ai-review.yml`,
  `.github/workflows/repair-build.yml`) — both pins move from v1.0.235: to
  v1.0.236 with this adoption, to v1.0.240 in Dependabot's #54 and to
  v1.0.261 with the v4.18.0 adoption below, bringing the generated workflows
  onto the newer bundled Claude Code and Agent SDK versions.

  **The notices refresh now supplies the repository to its signed commit**
  (`.github/workflows/refresh-notices.yml`) — the `Commit and push` step's
  `env:` gains `GH_REPO: ${{ github.repository }}`, so the GraphQL mutation and
  its `verification.verified` read-back receive a repository instead of
  failing when `$GH_REPO` is unset. The obsolete `APP_SLUG` setting is removed
  because that step no longer uses it for the Git identity or bot lookup.

  **Large notices inventories now reach `jq` without exceeding Linux's
  argument limit** (`.github/workflows/refresh-notices.yml`) — the base64
  content is written to `$RUNNER_TEMP/notices.b64` and passed with `--rawfile`
  instead of being expanded into one `--arg` argument. This lets the signed
  commit payload handle inventories whose base64 representation is larger than
  the per-argument limit.

- **The App token is kept out of the update-checker checkouts**
  (`.github/workflows/check-openmls-updates.yml`,
  `.github/workflows/check-template-updates.yml`) — both jobs mint a
  write-scoped GitHub App token and then run repository code and third-party
  tooling (`make`, `pip install copier`) in the same job. The
  `actions/checkout` step no longer receives that token; it uses the job's
  default, read-scoped `GITHUB_TOKEN` (the jobs grant `contents: read`), and
  `persist-credentials: false` keeps even that out of `.git/config`, so nothing
  in the worktree can read a write-scoped credential. `GITHUB_TOKEN` is enough
  to check the repository out whether it is public or private. The pull request
  is still pushed by `peter-evans/create-pull-request` via its App-token input,
  and the `gh` steps read the App token from `GH_TOKEN`. Mirrors
  `refresh-notices.yml`.

- **The update checkers can regenerate their own pull requests**
  (`.github/rulesets/signing-commit.json`, `.github/rulesets/README.md`) —
  `peter-evans/create-pull-request` refreshes an existing branch by
  force-pushing it, and `Signing commit` forbids that on `~ALL` branches with
  no bypass actors, so `force_update` could not regenerate an open update pull
  request: measured on 2026-10-20 (run `39450303118`), the App's signed API
  commit was created and the ref update refused with "Cannot force-push to
  this branch". A scheduled run fails the same way when a version's branch
  outlives its pull request. `refs/heads/update-openmls-*` and
  `refs/heads/update-template-v*` are now excluded from that ruleset, as
  `refs/heads/dependabot/**/*` already is: a push there may rewrite history
  and need not be signed, and the App signs regardless. `main` keeps its
  pull-request gate, its signatures and its no-bypass ban on force-pushes,
  and the branches stay under `Delete branches`.

- **copier template adopted: v4.15.2 -> v4.17.0** — by hand, superseding the
  update bot's #55 (v4.16.1). `.copier-answers.yml` records the new revision
  and the new question's answer, `upstream_source: git_tag`; switching the
  source is a change of its own.

  **pub.dev's upload limits are measured** (`make verify-pub-limits`) —
  pub.dev refuses a README.md, CHANGELOG.md, LICENSE or example over 256 KiB,
  or a pubspec.yaml over 128 KiB, at upload, after the tag, and the dry-run
  checks none of them. CI runs it on the Linux x86_64 leg and warns from
  200 KiB, `make publish-dry-run` runs it first, and `make release` measures
  the finalized CHANGELOG before committing.

  **iOS is type-checked on every push and pull request**
  (`make rust-check-ios`, the `Type-check (iOS)` job) — the three iOS targets
  were compiled only by a release tag, so an iOS-only compile error first
  showed up there.

  **`make release` refuses a stage-1 release whose native sources moved since
  its tag** — `rust/` (except `rust/fuzz` and `rust/deny.toml`) and
  `lib/src/rust/` are compared with the `openmls_frb-*` tag, so any commit
  there after stage 1 needs a new crate.

  **Every Ubuntu job names its image, `ubuntu-26.04`** — the Linux release
  builds move from `ubuntu-latest` (x86_64) and `ubuntu-24.04-arm` (arm64) to
  `ubuntu-26.04` and `ubuntu-26.04-arm`; a Linux library records the glibc
  symbol versions of the image that built it.

  **An upstream bump moves only what the new release requires** —
  `make rust-update` is `cargo update --workspace`, and the rest of the graph
  moves in Dependabot's weekly cargo pull request, which now takes transitive
  crates too (`allow: dependency-type: all`).

  **Only an Admin can create, move or delete a tag** — see *Documentation*
  above; on GitHub the ruleset changes when
  `make setup-repo-protections ARGS="--update"` applies it.

  **The agent workflows** — OpenCode is pinned at 1.18.35 and makes no
  session-title call unless `AGENT_OPENCODE_TITLE_MODEL` names a model; the AI
  reviewer is told where each file's hunks start and who wrote each commit;
  the build repair leaves drafts alone, re-runs a first failure once, leaves a
  commit to a person after two runs that ended without a verdict, and can run
  the wasm32 half of `make rust-doc`; the update bot's CHANGELOG entry is
  written from the lockfile diff and the bound upstream files' patches.

  **`make get` passes `ARGS` on**, so
  `make get ARGS="--directory=example_cli"` resolves that package.

  The App-token checkout hardening and the update checkers' branch exclusion,
  both above, now come from the template.

- **openmls comes from crates.io instead of a git tag** (`rust/Cargo.toml`,
  `rust/Cargo.lock`, `rust/deny.toml`, `.github/dependabot.yml`,
  `.copier-answers.yml` and the files the `upstream_source: crates_io` answer
  renders) — the update check found upstream releases through GitHub's latest
  release and accepted only an `openmls-vX.Y.Z` tag, so openmls 0.9.1,
  published on 2026-10-07 under the tag `v0.9.1` and with no GitHub release,
  was invisible to it. `openmls` is now pinned exactly (`"=X.Y.Z"`) on both of
  its declarations, the four other openmls crates sit at the requirements that
  release declares, and the check reads crates.io. The switch, made on 0.9.0
  before the bump in *Security*, moved no code: all nine openmls packages in
  the lockfile were published from the commit the `openmls-v0.9.0` tag names
  (`3a3e35de`), and only their `source` and `checksum` lines moved.
  `rust/deny.toml` no longer allows the openmls git repository, and Dependabot
  ignores the four openmls crates that arrive only through the others, so they
  move with the openmls release that requires them.

- **copier template adopted: v4.17.0 -> v4.18.0** — by hand.
  `.copier-answers.yml` records the new revision and the new question's
  answer, `enable_upstream_advisories: true`. Three files conflicted, each
  resolved to the template's side: the `claude-code-action` pin in both agent
  workflows and a comment in `.github/dependabot.yml`. What a consumer
  observes is under *For Users*: the isolate count in `init()`, the web module
  check, the `hooks`/`code_assets` range and the build hook's lock-file check.

  **openmls/openmls's own security advisories are checked every day**
  (`make check-upstream-advisories`, a job of `check-openmls-updates.yml`) —
  `make rust-audit` and `make rust-deny` read RustSec and Dependabot reads
  GitHub's global database, and GHSA-gc79-23g3-8g52 reached none of them. The
  check reads the repository's published advisories and holds them against
  every version `rust/Cargo.lock` resolves; on this tree none of the seven
  covers one.

  **`make setup-repo-protections` configures both release environments** —
  `native-build` and `pub.dev` get the owner as the one required reviewer, no
  admin bypass, and a deployment policy that admits only `openmls_frb-*` and
  `v*` tags; `publish.yml`'s `publish` job now runs on a tag only. GitHub
  changes when the command runs: `--dry-run` on this repository shows
  `native-build` letting an Admin skip the review and both environments
  admitting any ref.

  **The minimum Rust version is checked against the dependency graph**
  (`make check-msrv`, on the Linux x86_64 leg) — 1.91 everywhere it is stated,
  the floor openmls 0.9.2 declares.

  **cargo-deny fails on a yanked crate version and on a wildcard dependency**
  (`rust/deny.toml`) — `yanked = "deny"`, and with every crate from crates.io
  `wildcards = "deny"`, path dependencies allowed; `make rust-deny` passes.

  **The update tooling** — `make update-template ARGS="--version vX.Y.Z --data
  key=value"` answers a question a new version adds, and from the next
  adoption on reports text a merge put in twice (none in this one: every
  merged file was compared with a fresh render of both versions); and
  `make update-evidence` writes down what an upstream update changed, attached
  to the update pull request, which now also says whether it could be merged
  unread, as a report only. The build repair reads the openmls crates' source
  from crates.io, takes the update it repairs from the compare API, may write
  `CHANGELOG.md`, `README.md` and `SECURITY.md`, and asks what moved behind a
  changed signature; the AI reviewer holds a bot entry's upstream claims
  against the upstream range; the update bot replaces the upstream Highlights
  line whoever last wrote it.

  **The macOS and Windows jobs name their images, `macos-26` and
  `windows-2025-vs2026`** — the release builds included, and the images
  `-latest` already gave them: `openmls_frb` 2.3.1 was built on
  `macos-26-arm64` and `windows-2025-vs2026`.

  **`Swatinem/rust-cache` moves to v2.9.3** — and `claude-code-action` to
  v1.0.261 (see the v4.15.2 entry above); both upstream tags dereferenced to
  the pinned commits. This supersedes Dependabot's #71.

  **Dependabot** — the `coverage >= 1.16.0` and `ffigen`-major ignores now come
  from the template, which took them from this repository: its text replaces
  ours and gives `ffigen` a reason of its own, flutter_rust_bridge's
  `frb_dart` pinning `^20.1.1`, where ours named hooks 2. The
  `hooks`/`code_assets` ignore now holds back 3.x.

  Smaller: `compareVersions` orders prereleases and build metadata as SemVer
  does; the update-openmls skill no longer describes a crate bump the update
  never makes; README and CONTRIBUTING say what the update pull request
  changes; `protect-main.json` names
  `require_extra_approval_for_unattributed_changes: true`, which the live
  ruleset already holds.

## [3.2.1] - 2026-09-29

### For Users

#### ✨ Highlights

- **A failed start on the Web now says why, instead of spinning forever** —
  the example app reports the error and names the usual cause and its fix.
- **The `--wasm` limitation now tracks the pull request that fixes it** — and
  says where that fix is: a prerelease, so the limitation still stands here.
- **openmls v0.9.0** — unchanged this release
- **openmls_frb v2.3.1** — Rust FFI bindings

#### Fixed

- **The example app now reports an initialization failure instead of spinning
  forever** (`example/lib/main.dart`) — `_initOpenmls()` is fire-and-forget
  from `initState()` and caught nothing, so any `Openmls.init()` throw left
  `_isInitialized` false with the progress indicator running and the exception
  reaching the console and nowhere else. A hang that names no cause is a much
  longer diagnosis than the one-line problem behind it.

  The body now branches three ways — initialized, failed, neither — and the
  failure path renders the error. The raw message is kept on purpose: *any*
  `init()` failure lands there, not only the missing-WASM one the hint names,
  so a message asserting the cause would be wrong as often as right. The hint
  names the usual cause on web and the command that fixes it.

  ⚠ This does not fix the underlying reason `init()` fails on web, which is
  not fixable from this package: `flutter run -d chrome` after a run for
  another platform reuses that run's `dart_build` stamp — the build directory
  key does not include the target platform — and skips the build hook above
  `hooks_runner`, so `web/pkg/` is never provisioned. *Known Limitations*
  names the escape. What changes here is that the app says so.

#### Documentation

- **The `--wasm` limitation now names the pull request that fixes it, instead
  of a stale issue about something else** (`README.md`) — *Known Limitations*
  tracked [flutter_rust_bridge#2575][frb2575], which was closed in July 2025
  and describes a different failure (a `DartFnFuture` callback crash under
  Chrome), not the decoder cast this package actually hits. It now tracks
  [flutter_rust_bridge#3182][frb3182], the pull request that replaces that
  cast, merged on 2026-09-05. The quoted error is the verbatim one as well, so
  that searching for what the console prints finds this section.

  The limitation still applies and was re-measured rather than assumed. What
  is new for a reader is where the fix is and why waiting is the only option:
  it is in `flutter_rust_bridge` 2.14.0-beta.2, a prerelease, and this package
  can neither ship a stable release that depends on a prerelease nor be
  rescued by a `dependency_override` in the host app, because its own
  generated bindings carry the same cast. The section now says so.

### For Contributors

#### Added

- **The resolved cargo feature graph is now a gate, not a comment**
  (`scripts/verify_feature_graph.dart`, `scripts/src/feature_graph.dart`,
  `Makefile`, `.github/workflows/test-reusable.yml`,
  `test/scripts/feature_graph_test.dart`,
  `test/scripts/feature_graph_policy_test.dart`, `CLAUDE.md`) —
  `rust/Cargo.toml` carries a comment
  explaining that `openmls`'s `test-utils` must stay absent from a shipped
  binary, because it implies `backtrace` and `LibraryError::custom()` then
  formats a symbolized Rust backtrace — build-machine paths, symbol names,
  crate layout — into an error that travels the *ordinary* error channel out to
  the Dart caller, no panic required. Nothing enforced it.

  A manifest comment cannot: cargo unifies features across the graph, so the
  feature can be switched on for a crate this manifest never mentions, by a
  dependency arriving transitively in a version bump nobody here reviewed. The
  check therefore reads `cargo tree` — what openmls is *built* with — rather
  than the manifest text.

  ⚠ **It is keyed by crate, and a flat list of feature names would be red on a
  healthy tree.** Measured rather than assumed: `openmls_basic_credential`
  carries `test-utils` deliberately — it is what makes
  `SignatureKeyPair::private()` reachable, and that crate's `test-utils`
  implies no backtrace — and `allo-isolate`, which arrives under
  `flutter_rust_bridge`, enables a `backtrace` feature of its own. Both sit in
  the test fixture for exactly that reason. `backtrace` is forbidden alongside
  `test-utils` because upstream allows enabling it on its own, which is a
  shorter path to the same leak.

  Absence is a failure rather than a pass: if a crate named in the rules is
  missing from the graph, the check fails instead of reporting clean, so a
  renamed or dropped dependency cannot silently retire it.

  The mechanism has since moved into the copier template, so the two scripts
  and the mechanism test are now byte-identical to what it renders and a future
  adoption will not conflict over them. What stays is the part that is this
  project's rather than the template's: the rules — `openmls` must carry
  neither `test-utils` nor `backtrace` — and
  `feature_graph_policy_test.dart`, whose fixture is the real graph
  (`openmls_basic_credential` carrying `test-utils` on purpose,
  `allo-isolate` carrying its own `backtrace`) and therefore the evidence that
  a flat list of feature names would be red on a healthy tree.

  `CLAUDE.md` gains a `## Feature Graph Gate` section carrying what the code
  cannot say: why the rules are keyed by crate, and why `--manifest-path` is
  right here although `make rust-clippy-web` requires the opposite. It is a
  section of its own rather than lines inside the existing blocks, because that
  file is template-owned — an edit inside a rendered block conflicts at every
  adoption, while a section the template knows nothing about does not.

  `--edges normal` (the graph that ends up inside the shipped library),
  `--target all` (a clean union means every target is clean) and `--locked`
  (a property of the revision, not of the machine). It resolves without
  compiling and runs inside the already-required Linux x86_64 test job, so it
  adds no required context. Verified red as well as green: with `js` added to
  the rule set the gate fails and names the crate, the feature, the enabled
  set and the `cargo tree --invert` command that finds the culprit.

#### Changed

- **copier template adopted: v4.15.0 -> v4.15.1** — the notices refresh now writes
  signed commits through GitHub's GraphQL API instead of pushing an unsigned
  commit.

  `.copier-answers.yml` records the new template revision.

  **The notices refresh now creates a mergeable commit**
  (`.github/workflows/refresh-notices.yml`) — it previously used an ordinary
  `git commit` and `git push` on Dependabot cargo branches. The exclusion for
  `refs/heads/dependabot/**/*` in `signing-commit.json` allows that push, but
  it does not make the resulting pull request mergeable into `main`, where
  `required_signatures` still rejects the unsigned workflow commit. An
  approval therefore cannot unblock the pull request.

  The workflow now uses GraphQL `createCommitOnBranch`, which signs the bytes
  it writes, and passes `expectedHeadOid` so a concurrent push causes the
  mutation to fail instead of silently reverting newer work. This also removes
  the `git config` setup and `/users/{bot}` lookup that were needed only to
  imitate the commit attribution; the mutation credits the token's owner.

  The workflow reads `verification.verified` from the new commit and fails if
  it is not `true`. A signing failure is therefore reported during the refresh
  instead of being left for the pull request's merge check to discover.

- **copier template adopted: v4.14.1 -> v4.15.0** — superseded template-update pull requests can now be closed safely, and the generated workflows and documentation catch up with several template fixes.

  `.copier-answers.yml` records the new template revision. The resolved feature-graph gate and its supporting scripts produce no diff in this project; that machinery was already present here.

  **Older template-update pull requests are now managed automatically**
  (`.github/workflows/check-template-updates.yml`) — the workflow identifies older
  `update-template-vX.Y.Z` branches and closes their pull requests during scheduled
  runs, while manual runs default to a dry run. It leaves a pull request open when
  the branch is not an older template-update branch, carries `agent-repaired`, has
  a commit with a `repair-build:` trailer, or contains a human-authored commit.
  Those vetoes matter because a newer update supersedes an untouched older one, but
  must not discard a branch whose conflicts or repair work a human has addressed.

  **The agent workflows now read their configuration from the default branch**
  (`.github/workflows/repair-build.yml`, `.github/workflows/ai-review.yml`) —
  `OPENCODE_CONFIG` previously pointed into the checkout being repaired or
  reviewed, while the workflow and its expected permissions came from another
  revision. Both workflows now use `gh api` to read the default-branch config
  into `$RUNNER_TEMP`, so a pull request cannot supply the permissions that govern
  the agent judging it. The repair workflow also reports a deleted update branch
  as missing instead of displaying the 404 response as a branch head.

  **The generated documentation and ignore rules now describe the current build
  behavior** (`CLAUDE.md`, `.gitignore`) — `CLAUDE.md` documents the
  `.crate-version` stamp required by local Web builds, why an unstamped or stale
  WASM directory is rejected, and how to rebuild it. `.gitignore` now excludes
  Python `__pycache__` directories, preventing local release-gate runs from
  adding generated bytecode to commits.

  The `setup-android` comments in `.github/workflows/test-reusable.yml` and
  `.github/workflows/build-openmls.yml` now match the `v4.0.4` pin and explain why
  the explicit `packages: platform-tools` input remains. The OpenCode setup is
  still duplicated between the two agent workflows; this adoption records why a
  shared local composite action is not used, rather than changing that behavior.

- **copier template adopted: v4.14.0 -> v4.14.1** — `make build-web` now
  stamps local WASM builds with the Rust crate version, and `hook/build.dart`
  rejects a missing or stale stamp instead of serving an older module.

  `Makefile` writes `rust/target/wasm32/.crate-version` from the version in
  `rust/Cargo.toml`. The web build hook compares that stamp with the current
  crate before it copies a local module into `web/pkg/`; a directory built
  before this change has no stamp and is rejected. This matters because a
  local `rust/target/wasm32/` build can otherwise outlive a crate bump while
  still satisfying the old existence-only check. The stamp is also a build
  dependency, so changing it invalidates the cached hook result.

  `test/hook/build_hook_test.dart` adds the regression cases for the missing
  and mismatched version stamps. `.copier-answers.yml` records the new
  template revision.

  The workflow changes in v4.14.1 are byte-identical in this project and
  produce no diff: the `actions/checkout@v7` update in
  `.github/workflows/release.yml` and the `anthropics/claude-code-action` and
  `android-actions/setup-android` pins in the generated workflow files were
  already present here.

## [3.2.0] - 2026-09-20

### For Users

#### ✨ Highlights

- **Past epoch message secrets are now yours to keep and to clear** — seven
  engine methods read and set how many past epochs a group keeps, and delete
  what is kept. Retaining them is a forward-secrecy trade-off, not a tuning
  knob; the default still keeps none.
- **A second browser tab can no longer overwrite the first** — every operation
  on the Web runs under an exclusive cross-tab lock, so the tabs and workers of
  an origin queue instead of dropping each other's writes.
- **openmls v0.9.0** — unchanged this release
- **openmls_frb v2.3.0** — Rust FFI bindings

#### Added

- **Past epoch message secrets can now be retained and deleted on demand** (`rust/src/api/engine.rs`) — `pastEpochDeletionPolicy` reads how many past epochs a group keeps, `setPastEpochDeletionPolicyMaxEpochs` and `setPastEpochDeletionPolicyKeepAll` set it, and four `delete…` methods remove what is kept: `deleteAllPastEpochSecrets`, `deletePastEpochSecretsOlderThan`, `deletePastEpochSecretsBefore` and `deletePastEpochSecretsWithoutTimestamps`.

  An application message is encrypted under the epoch its sender was in, so a
  message still in flight when a commit advances the group can only be read
  from that epoch's secrets. `MlsGroupConfig.maxPastEpochs` could already keep
  a fixed number of them, but only at creation, and it cannot express "keep
  all" at any number — nor could anything delete them before their turn came.

  ⚠ Retaining them is a forward-secrecy trade-off rather than a tuning knob:
  the secrets of a past epoch decrypt every message of that epoch, including
  traffic recorded earlier, for as long as they are stored. The default keeps
  none, and `keepAll` keeps them forever unless the application deletes them —
  which is what the four `delete…` methods are for. SECURITY.md says so where
  it discusses group state.

  ⚠ `setConfiguration` resets the policy, because `MlsGroupConfig` carries the
  same setting as `maxPastEpochs` and the struct has no "leave as is". Set the
  policy after the configuration, not before. Documented on the setter, on
  `setConfiguration` and on the field, and pinned by a test.

  `deleteAllPastEpochSecrets` deliberately takes no `maxPastEpochs` cap, unlike
  the other three: OpenMLS applies that modifier only to the selective
  deletions, so "delete everything but keep a few" would delete everything. The
  combination is absent from the API rather than documented as a trap. It is
  also a sweep rather than a switch — under `keepAll` the next commit starts
  recording past epochs again, so stopping accumulation means setting a
  `maxEpochs` policy, not deleting.

  `setPastEpochDeletionPolicyMaxEpochs` refuses 4294967295 and names `keepAll`
  in the error. That single value is what OpenMLS writes to mean keep-all where
  `usize` is 32 bits — the Web and 32-bit Android — so accepting it would make
  two settings one stored value there and two everywhere else.

  ⚠ Secrets recorded by a version of this package built on OpenMLS 0.8.1 or
  earlier (that is, before 3.0.0) carry no timestamp, and the two time-based
  deletions skip them in silence. `deletePastEpochSecretsWithoutTimestamps` is
  the step that clears them. It applies only where `maxPastEpochs` was above
  zero back then, since the default recorded no past epochs at all. No database
  migration is involved: OpenMLS reads the older encoding through a serde alias
  and a defaulted field, and the schema version does not move.

  Shown by execution on both platforms, because the storage encoding of
  keep-all is written in terms of `usize::MAX` and therefore differs by target.
  Measured in a browser: a stored keep-all comes back from IndexedDB as
  `MaxEpochs(4294967295)` on wasm32 and is normalised so that Dart sees the
  same answer everywhere. 17 Dart tests cover the native path, and five Rust
  tests the conversions, one of them driving a real IndexedDB group. Negative
  controls: removing the normalisation fails three browser tests while the
  whole Dart suite stays green, and dropping the `maxPastEpochs` cap from its
  test makes a deleted epoch decrypt again.


#### Security

- **Every operation on the Web now takes a cross-tab lock** (`rust/src/web_lock.rs`, `rust/src/api/engine.rs`) — a second browser tab was an unguarded second writer to the same IndexedDB database. Each tab runs its own WASM instance with its own engine, so the engine-wide mutex that serializes overlapping calls could not see it: two tabs could load the same snapshot, operate on it, and write back in turn, and the later write-back would drop what the first had saved — a merged commit, an advanced ratchet, a stored proposal — desynchronizing the group.

  Every load → operate → save cycle now runs under an exclusive Web Lock named
  after the IndexedDB database, so the tabs and workers of an origin queue
  instead of overwriting each other. They are not refused the way a second
  native process is, because a tab is opened and closed by the person using the
  application rather than by the application: a contending operation waits, for
  at most five seconds, and then fails with "Database is busy" rather than
  waiting behind a wedged tab forever. That failure is retryable and leaves
  nothing behind: the lock is taken before any snapshot is read, so an
  operation that cannot get in has loaded no state and released the
  engine-wide mutex on its way out.

  ⚠ The guarantee needs a secure context, which is where `navigator.locks`
  exists at all: `https`, or `http` on `localhost`. Served over plain `http`
  from any other host the API is absent, and operations run exactly as they did
  before — without the cross-tab guarantee, never with an error. The
  degradation is deliberate: the alternative is failing every operation on an
  origin where the Web build used to work.

  ⚠ A panic inside a guarded operation does not release the lock. wasm32 aborts
  on panic, so `Drop` never runs, while the instance itself keeps working — so
  every later operation on that database reports "Database is busy" until the
  page is reloaded. The escape is a reload, not a retry. Native unwinds and
  releases.

  Native is unchanged and was never exposed: its sidecar lock file has refused
  a second opener outright since 2.0.0. This closes the same hole on the one
  platform whose processes are tabs.

  Shown by execution rather than by construction, which on wasm32 is the only
  kind of evidence that counts — a wasm32 body is a different implementation of
  the same function, so nothing that runs on the host touches a line of it.
  Three browser tests (`make test-web`) cover exclusivity, the busy error on
  contention, release on drop, independence of unrelated database names, and
  the absent-API fallback.

### For Contributors

#### Added

- **`Refresh Dependency Notices` regenerates `THIRD_PARTY_NOTICES.txt` on Dependabot's cargo pull requests** (`.github/workflows/refresh-notices.yml`) — the inventory is generated from the resolved cargo graph, and Dependabot edits `rust/Cargo.toml` and `rust/Cargo.lock` with no way to run `make third-party-notices` afterwards, so every cargo pull request arrived with a stale inventory and failed `verify-third-party-notices`.

  That was cosmetic until the ruleset in v4.10.0 required the whole matrix. The
  step runs `if: matrix.name == 'Linux x86_64'`, so it fails the job reported as
  `test / Test (Linux x86_64)` — now one of twelve required contexts. The same
  redness that used to be ignorable makes every cargo pull request unmergeable
  by anyone without a ruleset bypass. The fix follows its cause by one day.

  It is a separate workflow rather than a step in `test.yml` because a workflow
  triggered by a Dependabot pull request gets a read-only `GITHUB_TOKEN` and no
  Actions secrets — measured, and this repository has no Dependabot secrets
  either, so such a job can mint no App token and push nothing. `schedule` plus
  `workflow_dispatch` run in the base repository's context instead;
  `pull_request_target` was rejected, since it would hand a write token to a job
  checking out pull-request content.

  An ordinary unsigned `git push` is what lands the commit, and that is only
  legal because `signing-commit.json` excludes exactly `refs/heads/dependabot/**/*`
  from the signature requirement — written down in the workflow, because if that
  exclusion is ever narrowed the commit has to go through the GitHub API
  instead. Scoped to `dependabot/cargo/**` and to Dependabot's own authorship,
  checked twice: once when selecting pull requests and again in the job holding
  the token, since a branch name is not a credential and anyone who can push can
  create `dependabot/cargo/x`.

  The work is split across two jobs for the same reason `repair-build.yml` is,
  and the author check is what makes the split necessary rather than optional:
  it proves Dependabot *opened* the pull request, not that nobody pushed to its
  branch afterwards — and the signing exclusion above means such a push need not
  even be signed. So the job that runs branch content — the `Makefile`, the
  scripts, and the composite actions `uses: ./…` resolves out of the workspace —
  holds no credential at all and checks out with `persist-credentials: false`;
  the job holding the App token runs nothing from the tree, taking the one file
  back as an artifact and refusing to commit if anything else in the working
  tree moved. Checking untrusted files out is safe; executing them beside a
  credential is not.

  The revision the inventory was generated from travels with it, because the
  two jobs check the branch out at different moments and only this workflow's
  own runs are serialised — nothing stops Dependabot moving the branch in
  between. The commit job compares, and steps aside when they differ rather
  than committing an inventory for a lockfile the branch no longer has, which
  would leave the gate red for exactly as long as it looked fixed.

  That hole was found by this repository's own automated reviewer, on the pull
  request adding the workflow — the first finding of its kind it has produced
  here that survived checking.

  Two things were measured rather than assumed. `.author.login` is
  `app/dependabot` through `gh --json`, not `dependabot[bot]` as the REST API
  spells it, so the obvious `startswith("dependabot")` predicate selects nothing
  — for ever, while staying green; the check normalises both forms. It was
  exercised while being written against seven hand-built cases, including an
  impostor author on a `dependabot/cargo/` branch, a closed pull request and
  the two non-cargo ecosystems, with the jq program extracted from the workflow
  so the exercise could not drift from what runs. That was a measurement taken
  during development, not a committed test: nothing in the repository reruns it,
  so a later edit to the predicate is guarded by review alone.

  And the generator reads licence files out of the cargo registry without
  fetching them, so the job fetches explicitly: nothing else in it compiles
  anything, which is why `test-reusable.yml` never needed the step and this
  would otherwise have been a laptop-only pass.

  ⚠ Pushing to a Dependabot branch stops Dependabot rebasing it. That is wanted
  here — a rebase would discard the notices commit — but it means a stale pull
  request needs a human, and `@dependabot rebase` is the wrong repair.

#### Changed

- **copier template adopted: v4.13.0 -> v4.14.0** (18 files, plus this entry) — three new gates arrive, each covering something nothing here was checking: the wasm32 half of the crate is now linted, every native library is loaded before it is shipped, and every release archive is checked against what its name claims.

  `make rust-clippy-web` is the lint gate, and `.github/workflows/test-reusable.yml`
  runs it on the Linux x86_64 leg. It is a second gate rather than a
  thoroughness setting: `make rust-clippy` runs under the host target, and a
  `cfg(target_arch = "wasm32")` body is a different implementation of the same
  function, so the host pass reads none of its lines while reporting green over
  the file that contains them. The target uses `cd rust` rather than
  `--manifest-path`, because cargo discovers `.cargo/config.toml` relative to
  the working directory and the repository root drops the wasm32 rustflags.
  The other half of this — the crate actually being clean under that lint —
  landed separately and is recorded above.

  `scripts/verify_library_loads.py` loads each built library before it is
  packed. `ctypes.CDLL` is the whole check and it is more than it looks: it runs
  the library's initialisers, resolves its dependencies and refuses a wrong
  architecture. It then looks up `frb_init_frb_dart_api_dl`, which
  flutter_rust_bridge exports from its own binding rather than from generated
  code, so a library without it is not an FRB library whatever else it is. It
  runs only on the legs whose runner IS the target — both Linux architectures,
  macOS arm64 and Windows — since a cross-compiled artefact cannot be loaded by
  the machine that built it. ⚠ Upstream measured `ctypes.CDLL` on macOS only;
  the Linux and Windows legs are inference until this repository's first
  native build runs them.

  `scripts/verify_release_artifacts.py` refuses an archive that does not hold
  what its name says, and runs at both points that can get it wrong:
  a `verify-artifacts` job over what the build jobs produced, placed before
  `create-release` and outside its environment so a bad build is caught without
  spending a reviewer's approval, and again inside `create-release` over the
  packed archives, before the provenance attestation signs them.
  ⚠ Checking the architecture would not have caught the likely error: a Linux
  arm64 and an Android arm64 `.so` carry the same ELF header, and a macOS, an
  iOS and an iOS-simulator `.dylib` the same Mach-O cputype — exactly the pairs
  a copy-paste slip in the hand-written `tar` list produces. It parses headers
  instead of calling `file`, reading the libc in `DT_NEEDED` (glibc asks for
  `libc.so.6`, Bionic for `libc.so` plus `liblog.so`) and the platform field of
  `LC_BUILD_VERSION`.

  Measured here against this project's own published release rather than taken
  on trust: `make verify-release-artifacts` over all twelve archives of
  `openmls_frb-2.2.0` passes, which is the same call `create-release` makes on
  the archives it packs. That also settles the question the script cannot answer
  about itself — its platform table is rendered from the copier answers, and
  nothing had checked that the rendered table matches the archive names THIS
  repository publishes. It does, and the discriminators do real work on them:
  `linux-arm64` reads as glibc and `android-arm64-v8a` as bionic at the same
  `e_machine`, and `macos-arm64` as macOS against `ios-device-arm64` as iOS at
  the same Mach-O cputype.

  `.github/workflows/repair-build.yml` and `.github/agent-prompts/repair-build.md`
  extend the repair agent to open bot-authored pull requests, committing to
  their own branches. A red update branch never reaches `main`, so nothing
  watching `main` would ever see it. Most such branches never reach a model:
  the commonest failure is that the update workflow could not run the binding
  generator and left the branch labelled `codegen-failed`, which the repair
  simply runs and clears. Three labels carry state, and `agent-repaired` is a
  contract — the repair commits with the same App token as the branch's own
  commits, so nothing else can tell a branch an agent has worked on from one it
  has not, and a branch carrying it must not be closed automatically.

  `scripts/src/update_changelog.dart` now returns a `ChangelogUpdate` rather
  than a model, carrying the one fact only that run can observe: whether
  `[Unreleased]` was left naming two upstream versions because a rewritten
  Highlights line was standing. `ciOutputsFor` emits both keys on both
  outcomes, since a key that appears only when true cannot be told apart from a
  script too old to emit it. `.github/workflows/check-openmls-updates.yml`
  surfaces it as a numbered step in the pull-request body. The generator also
  anchors a created `#### Changed` on the first `#### ` heading, so it no longer
  lands above `#### Added`, and the changelog prompt gains two further rules:
  no attributing a change by the list of files it touched, and no scope file
  telling a model with no tools to go and fetch something.

  Smaller: `.github/dependabot.yml` records that `increase-if-necessary` holds
  only the neighbours of a capped pin and returns the bumped one as a caret;
  `.github/actionlint.yaml` carries a second suppression for the same actionlint
  bug; `CLAUDE.md`, `CONTRIBUTING.md` and
  `.claude/skills/update-openmls/SKILL.md` follow. `.copier-answers.yml` records
  template version `v4.14.0`.

  `.github/agent-prompts/changelog-scope.md` is updated by hand, because it is
  the one thing in this release copier structurally cannot deliver: the template
  writes that file once and never overwrites it, so guidance v4.14.0 adds to its
  source reaches an existing project only if somebody applies it. The guidance
  asks that the file name a dependency living in a DIFFERENT repository that
  still reaches users, and this package has one — the libcrux crates arrive from
  crates.io through `hpke-rs-libcrux`, at versions openmls pins, and are named
  nowhere in the bound list. They can reach the X-Wing ciphersuite and nothing
  else. ⚠ The compare the changelog prompt is given covers the openmls
  repository alone, where such a change leaves one trace — a version number in a
  manifest — so an entry reports the version move and stops rather than
  inferring what changed inside. The file was also checked for the other thing
  that guidance forbids, an instruction telling a model with no tools to go and
  fetch something; it carries none.

  Three files conflicted and were resolved by hand. `CONTRIBUTING.md` took the
  template's `make rust-clippy-web` row into the commands table this file
  already maintains, rather than the second table copier tried to place inside
  the release section; the gate is also named in the pre-push list and the pull
  request checklist, since it blocks in CI.
  `.github/workflows/check-openmls-updates.yml` kept both sides — the
  template's stacked-highlights step and this project's database-migration
  step. `CHANGELOG.md` conflicted in two places and kept this
  project's side at both. The first is the file's head: this one has begun at
  `## [Unreleased]` since the project was generated, with no title and no Keep
  a Changelog blurb, so the paragraph v4.14.0 adds above that heading has no
  context to attach to and is not adopted. Three of the four projects generated
  from this template start the same way, and `CLAUDE.md` already carries what
  that paragraph says, at more length. The second is the template's seeded
  initial release, which this project's real `## [1.0.0]` section supersedes.
  The released `## [1.0.1]` section is left as it shipped: copier had rewritten its headings into the audience split by
  position, matching its own seeded release rather than anything about this
  project, and released sections do not change.

- **The wasm32 half of the crate is now clean under clippy** (`rust/src/encrypted_db.rs`) — `make rust-clippy` runs under the host target only, so every `cfg(target_arch = "wasm32")` body in the crate had never been linted, here or in CI. A wasm32 body is a different implementation of the same function, so nothing the host lints touches a line of it.

  Measured with `--target wasm32-unknown-unknown --all-targets -- -D warnings`:
  one finding, a `collapsible_if` in the IndexedDB structural migration, now
  collapsed. Nothing changes at runtime — the two conditions were already
  evaluated one after the other — but a lint gate for that target cannot be
  added while the crate fails it, so this is the half of that gate which
  belongs to this repository rather than to the template that owns the
  Makefile.

- **copier template adopted: v4.12.0 -> v4.13.0** — the generated workflows now use the current Claude action and no longer request the deleted Android SDK Tools package, while the changelog generator gains stricter upstream and highlight handling.

  `.github/workflows/ai-review.yml` and `.github/workflows/repair-build.yml` move
  `anthropics/claude-code-action` from `v1.0.216` to `v1.0.222`. The pin is
  updated in both callers so review and automated repair do not drift onto
  different action releases.

  `.github/workflows/test-reusable.yml` and
  `.github/workflows/build-openmls.yml` now pass `packages: platform-tools` to
  `android-actions/setup-android`. Its default also asks `sdkmanager` for the
  obsolete `tools` package, which Google removed; leaving that name in place
  fails the Android job before it reaches the pinned NDK installation. The
  NDK step remains responsible for installing the version the builds need.

  `scripts/src/update_changelog.dart` now normalises a model-supplied list
  marker before writing a Highlights line, and shares the default highlight
  text between the prompt and the logic that recognises and supersedes it.
  Rewritten, multi-line highlights are left intact, while an old generated
  default can be replaced so successive dependency bumps do not accumulate
  contradictory native-library versions. The prompt also distinguishes the
  fetched upstream inputs from facts about a release, preventing an absent
  release body from being reported as a release-level claim.

  When release notes are empty, the generator makes a best-effort request for
  the upstream repository's `RELEASE_NOTES.md`. It accepts that fallback only
  when its first line names the requested tag, avoiding reuse of a file left
  over from an earlier release. The placeholder for missing notes is now a
  shared constant, so this case can be handled consistently.

  The upstream dependency summary now uses the compare response's commits and
  changed files together. `scripts/src/update_changelog.dart` separates those
  two inputs and tells the model whether the file list is complete: GitHub's
  300-file limit and the generator's 12000-character prompt limit are treated
  as truncation rather than evidence that no other files changed. With a
  complete list, the prompt asks for the actual files changed by the bound
  crates instead of relying on a generic out-of-scope sentence.

  `test/scripts/update_changelog_test.dart` adds coverage for these cases,
  including marker normalisation, release-notes fallback and tag checking,
  default-versus-rewritten highlight handling, and complete versus truncated
  upstream file lists. `.copier-answers.yml` records template version
  `v4.13.0`.

- **copier template adopted: v4.10.0 -> v4.12.0** — two template releases at
  once: the notices workflow this project contributed comes back carrying the
  edits the template made to it, and the dependency-bump changelog prompt is
  rewritten.

  `.github/workflows/refresh-notices.yml` is **not** byte-identical to the copy
  that went up. `actions/upload-artifact` moves v4 -> v7 and
  `actions/download-artifact` v4 -> v8; those two lines are the only difference
  that can change what the job does, and they put the file on the pins every
  other workflow here already uses, clearing a Node 20 deprecation warning.
  Measured before moving them: the extraction-layout break in
  `download-artifact` v5 applies to downloads **by ID**, this one downloads by
  name, and a v7 -> v8 round trip by name read from a flat path is already
  green in this repository — `ai-review.yml` does exactly that. Every other
  difference is a comment: four passages that recorded measurements about this
  repository by name, reworded to say the same thing without naming it, plus a
  new block recording why the job deliberately has no `Setup Protoc` step —
  nothing in it compiles, so no build script runs, so nothing reaches for
  `protoc`.

  `.github/rulesets/README.md` now says the `refs/heads/dependabot/**/*`
  exclusion from required signatures is load-bearing rather than merely
  convenient: the workflow pushes an ordinary unsigned commit, so restoring
  signatures on those branches while keeping the force-push and deletion
  exclusions would put every cargo pull request back to unmergeable with
  nothing saying why.

  `scripts/src/update_changelog.dart` now gives the dependency-bump changelog
  prompt a checkable scope argument. Rule 1 asks for the documented bold
  summary and em-dash format instead of fixing a title as the first line.
  Rule 2 requires both where an upstream change landed and why that location
  is outside this package's resolved dependency graph, rejecting a bare
  out-of-scope verdict or a location without its reason.

  Rule 4 continues to require the exact no-impact phrase, but the phrase is
  now shared as `noImpactPhrase` with `breakingContradictsNoImpact`, so the
  prompt and its guard cannot silently drift apart. The prompt also requires
  the conclusion to appear once in a sentence rather than as a detached
  `Note:` line. Its concrete example has been replaced by an abstract answer
  shape and an explicit anti-example, making the failure modes inspectable
  without teaching the model one project-specific response.

  `.copier-answers.yml` records template version `v4.12.0`.

- **copier template adopted: v4.9.0 -> v4.10.0** — the generated project now documents the FFI scan boundary and makes the pull-request gate report the full test matrix instead of disappearing behind a path filter.

  `.claude/skills/frb-patterns/SKILL.md` now says that `rust/src/api/` is a
  scanned directory, not a general-purpose folder. Because
  `flutter_rust_bridge.yaml` scans from `crate::api`, a module declared under
  `api/mod.rs` becomes part of the generated FFI surface. Helpers intended only
  for the crate therefore belong at the crate root and must be declared from
  `rust/src/lib.rs`; otherwise code generation can silently publish an API and
  change `rustContentHash`.

  `.github/rulesets/protect-main.json` now requires the complete generated
  check set, including `FRB bindings were regenerated` and the test matrix.
  `.github/workflows/test.yml` removes the `pull_request` path filter that
  would otherwise make required checks report nothing for documentation-only
  pull requests; the filter remains on `push` for cache-scope control.

  `.github/workflows/codegen-guard.yml` changes in a comment only — the
  paragraph explaining why the job's `name:` is load-bearing now says that name
  is *one of* the required contexts rather than *the* one. Its job, trigger and
  steps are byte-identical: measured on the diff, every changed line is a
  comment line.

  `.github/rulesets/README.md` now explains the required-check model and how to
  change it safely: context names must be taken from a real pull-request run,
  `make setup-repo-protections ARGS="--update"` must be used to apply an
  existing ruleset edit, and flaky legs should be removed from the required
  list while remaining in the workflow. It also records the job-level `if:`
  approach for an expensive leg, since a skipped job still reports and can
  satisfy the gate. `.copier-answers.yml` records the new template version.

## [3.1.0] - 2026-09-08

### For Users

#### ✨ Highlights

- **Three bindings taken from openmls 0.9.0** — a secret can now be exported
  from a Welcome before deciding whether to join, a signature-key rotation can
  be sent as a proposal instead of a commit, and a key package's validity window
  can be read out and judged against a clock other than the device's. All three
  are additive: no existing signature moves.
- **openmls v0.9.0** — unchanged this release
- **openmls_frb v2.2.0** — Rust FFI bindings

#### Added

- **`exportWelcomeSecret`** (`rust/src/api/engine.rs`) — `exportSecret` one step
  earlier in the join. It takes the same `label`, `context` and `keyLength` and
  derives from the exporter secret of the epoch the Welcome invites you into, so
  an invitee can agree a key with the inviter, or prove it can read the epoch,
  before it accepts. The value is identical to what `exportSecret` returns after
  joining that epoch, which the tests assert against both the joiner and a
  member already in the group.

  Like `inspectWelcome`, it commits nothing, and that is load-bearing rather
  than incidental: processing a Welcome makes OpenMLS delete the key package it
  was addressed to unless that package is last-resort. Here the delete lands in
  the call's snapshot and is discarded with it, so a later
  `joinGroupFromWelcome` on the same Welcome still finds its key package. A test
  now pins that behaviour end to end — inspect, export, then join — because a
  commit added to either function would silently burn the invitation instead of
  failing loudly.

  It reads the *unverified* group info, the same as `inspectWelcome`: the
  confirmation tag is only checked when the Welcome is staged into a group.

- **`proposeSelfUpdateWithNewSigner`** (`rust/src/api/engine.rs`) — the proposal
  form of `selfUpdateWithNewSigner`, filling the one gap in that pair. An Update
  proposal has to be carried by somebody else's commit, so this is what a member
  sends when it wants its signature key rotated by the next committer rather
  than committing itself.

  Two signers are required because the message and its payload are authenticated
  against different keys: the envelope by `oldSignerBytes`, since the sender's
  leaf in the tree still carries the old key, and the new leaf inside the
  proposal by `newSignerBytes`, so it verifies against the key it announces.
  Upstream additionally requires that a credential set in the leaf-node
  parameters equal the new signer's; this wrapper builds leaf-node parameters
  from `leafNodeCapabilities` and `leafNodeExtensions` only and never sets a
  credential there, so the new signer's credential is always the one folded in
  and the precondition cannot be violated from the Dart surface.

  Availability rests on this crate not enabling openmls's
  `virtual-clients-draft` feature. Upstream gates the function on
  `not(virtual-clients-draft)`, its own `test-utils`, or `test` — and that
  `test-utils` was deliberately dropped from the shipped binary in 3.0.0, so
  `not(virtual-clients-draft)` is the only arm holding it open.

- **`keyPackageLifetime` and `checkLifetimeAt`** (`rust/src/api/engine.rs`) —
  two synchronous helpers that expose a key package's validity window and let it
  be judged against a supplied instant, such as a timestamp from a server,
  rather than the device's clock. `checkLifetimeAt` calls OpenMLS's own
  `Lifetime::validate_with_time` rather than re-implementing the comparison, so
  the boundaries match what a peer will decide about the same package:
  `notAfter` is exclusive — an instant equal to it is already expired — while
  `notBefore` is inclusive. Neither bound is adjusted here: OpenMLS's hour of
  clock-skew margin is added by `Lifetime::new` when a key package is *created*
  (`lifetime.rs`, `not_before = now - 1h`), so it is already inside the
  `notBefore` that `keyPackageLifetime` reads back, and `checkLifetimeAt`
  compares whatever bounds it is handed unmodified — it reaches OpenMLS through
  `Lifetime::init`, which upstream documents as "raw lifetime without skew".

  **The device's clock still gates the reading half, and the split of these into
  two functions is what says so.** Getting at the window means validating the
  key package, and OpenMLS's validation checks signatures, protocol version,
  extensions *and* the lifetime, that last one against this device's clock;
  there is no way to skip it from outside the crate. So `keyPackageLifetime`
  fails on a package this device believes is expired and never yields its
  bounds — measured here, not inferred, by a test that builds an already-expired
  key package and asserts on the error OpenMLS reports. The pair can therefore
  apply an authority *stricter* than the local clock, which is the useful
  direction when choosing among a user's key packages, but cannot rescue one the
  local clock has already rejected. `checkLifetimeAt` takes the two bounds
  rather than key package bytes precisely so that half of the check has no local
  clock in it at all, for a caller that holds bounds from elsewhere.

  An instant past the year 9999 is an error rather than a verdict, and the cap
  is explicit rather than left to the platform. The platforms do not agree about
  what a `SystemTime` can hold: `web_time`'s on wasm32 is a bare `Duration`
  since the epoch and accepts every `u64` of seconds, while native
  `std::time::SystemTime` does not — so the same call with `u64::MAX` was a
  verdict on one target and an error on the other, measured on both. The cap is
  set where no calendar can mean a larger value rather than at any platform's
  limit, which is what keeps it correct without a survey of the platforms:
  9999-12-31T23:59:59Z costs no caller anything, and below it every target this
  package ships for answers a given argument the same way. It also catches the
  likeliest way to call this wrongly — Dart has no `secondsSinceEpoch`, so a
  caller reaching for `DateTime` meets `millisecondsSinceEpoch` first, and a
  present-day millisecond count sits far past the cap, failing loudly instead
  of returning a confident verdict about a date tens of thousands of years out.

#### Security

- **The snapshot's read path no longer leaves plaintext copies in freed memory**
  (`rust/src/snapshot_storage.rs`) — `kv_read` handed out a clone of the stored
  value and every caller dropped it unwiped, so each read of MLS key material —
  `EpochSecrets` and `MessageSecrets` among them — left a plaintext copy on the
  heap that nothing ever overwrote. Its two siblings did not have this: both
  `kv_write` and `kv_delete` already zeroized the value they displaced, and both
  snapshot maps are zeroized on `Drop`. The read was the one way out that was
  not covered.

  Pre-existing rather than a regression: the diff of this file from `v2.0.1` was
  additions only. The exposure was bounded by the same window as the rest of the
  snapshot — single-digit milliseconds per operation — but unlike the maps, the
  copies were never wiped at all, so they persisted until the allocator reused
  the pages.

  The fix is a type rather than a convention: `kv_read` returns
  `Zeroizing<Vec<u8>>`, so a caller cannot bind the value unwrapped without
  saying so, and the wipe runs on every path out, `?` included. The three
  decoded item lists behind it (`append_to_list`, `read_list`,
  `remove_from_list`) are wrapped the same way, because deserializing allocates
  fresh buffers that the wrapper around the *value* does not reach, and
  `remove_from_list` additionally wipes both the element `Vec::remove` hands
  back and the needle it was given.

  Zeroization cannot be asserted from a test — the wipe lands on memory the
  allocator may already have reused, and reading it back would be undefined
  behaviour — so a source-level test pins the shape instead, in the same way the
  release-profile test in `utils.rs` pins its invariant. It reads this file and
  fails if `kv_read`'s return type is widened back, if any decoded item list is
  bound outside the wrapper, or if the three lists it counts are no longer
  there. All three of those checks were confirmed to fail on a deliberately
  broken tree that still compiles.

#### Documentation

- **The README names a Flutter behaviour that leaves `web/pkg/` empty** — the
  build hook provisions the WASM module into an app's `web/pkg/`, and
  `flutter build web` always reaches it, but `flutter run -d chrome` reaches it
  only while Flutter considers its `dart_build` target out of date. That
  target's cache key does not include the platform, so a debug run for *another*
  platform leaves a stamp the Chrome run accepts, logs `Skipping target:
  dart_build`, and never invokes the hook — `RustLib.init()` then fails on a 404
  for `pkg/openmls_frb.js`. No hook can defend against it: the skip happens
  above `hooks_runner`, where nothing the hook declares is read. *Known
  Limitations* now names the three escapes (`flutter build web`,
  `rm -f build/*/dart_build.stamp`, `flutter clean`). Behaviour is unchanged —
  this was always true and was undocumented.

### For Contributors

#### Changed

- **`web-time` is now a direct wasm32 dependency of the native crate**
  (`rust/Cargo.toml`) — `Lifetime::validate_with_time` takes a `SystemTime`, and
  openmls's `lifetime.rs` chooses which one by `cfg(target_arch)`:
  `web_time`'s on wasm32 and `std`'s everywhere else. They are unrelated types,
  so `checkLifetimeAt` cannot name the epoch it adds to without this. Same
  version openmls already resolves (1.1.0), so no crate enters the graph and
  `THIRD_PARTY_NOTICES.txt` does not move — confirmed by the gate, not assumed.

  Worth knowing for anyone touching wasm32 code here: **`make rust-doc` does not
  catch this class of error.** Its `--target wasm32-unknown-unknown` pass went
  green on a deliberately wrong `SystemTime`, because rustdoc does not type-check
  function bodies. `make build-web` rejected the same tree with `expected
  web_time::time::system_time::SystemTime, found SystemTime`, so it is the only
  local gate that compiles wasm32 bodies at all.

- **copier template adopted: v4.8.0 → v4.9.0** (23 files, plus this entry) —
  most of it was
  written from this project's own findings and has been waiting on the template
  release; it lands here now. One conflict, in `README.md`, where the template
  inserts the *Known Limitations* subsection above a heading this project had
  renamed; resolved by keeping the local headings. Every workflow, composite
  action and ruleset file is byte-identical to a v4.9.0 render afterwards, and
  the `Makefile`'s three local hunks (the `mls_message` fuzz-target examples and
  the `classical_ops_do_not_init_libcrux` reference) survived the merge.

  **Android is cross-compiled on every pull request**, all three ABIs, in
  `test-reusable.yml`. Until now nothing outside a release tag cross-compiled
  Android at all, which is exactly how the `openssl-src` 3.6 / NDK r26
  assembler break sat on main under every green gate and first surfaced as a
  twice-failed stage 1. Measured before it was written: about four minutes per
  ABI against this workflow's six-and-a-half-minute critical path, so the wall
  clock does not move.

  **`make verify-android-alignment` measures the 16 KB alignment Google Play
  requires** rather than trusting the tool that supplies it. The alignment comes
  from `cargo-ndk`'s linker flags, not from the NDK — `openmls_frb-2.0.1` (r26)
  and `2.1.1` (r28) both measure `p_align=0x4000` — so `cargo-ndk` is now pinned
  to 4.1.2 in the release job and the pull-request job together, and both jobs
  verify the bytes that come out. A misaligned `.so` breaks no test here; it
  makes a *consumer's* app unpublishable.

  **`codegen-guard` regenerates the bindings instead of only reading a label.**
  A pull request that changes an existing signature was already caught, because
  `frb_generated.rs` stops compiling — but one that merely ADDS a `pub fn`
  compiled fine and simply lacked the function on the Dart side. The job now
  runs `make codegen` and refuses drift under `lib/src/rust/` or
  `rust/src/frb_generated.rs`, keeping its name (`FRB bindings were
  regenerated`) because `protect-main.json` matches it as a string.

  **`make actionlint` and a `Workflow Lint (actionlint)` job**, pinned by
  version and by checksum, with the suppressions in `.github/actionlint.yaml` so
  a local run reports what CI reports. It found 93 things across this
  repository's workflows and none of them was a bug: 81 shellcheck findings —
  79 fixed, and two `SC2129`s (style only, on append-to-`$GITHUB_OUTPUT`
  blocks) suppressed inline with a reason — plus 12 false positives from
  actionlint's stale copy of `actions/create-github-app-token`'s inputs.

  **`anthropics/claude-code-action` moves from v1.0.213 to v1.0.216** in
  `ai-review.yml` and `repair-build.yml`, by commit SHA as before. Neither
  workflow touches the published package; both are pinned by hand, because
  Dependabot's `github-actions` ecosystem does not reach the template's copy.

  **`make run-example-web` clears the `dart_build` stamp itself** before
  handing over to `flutter run` — the working half of the Flutter behaviour
  described under *Documentation* above, which otherwise makes a Chrome run
  after a desktop run serve no WASM at all. A stamp that does not exist cannot
  be stale, and an unmatched glob is a no-op under `rm -f`.

  **`make verify-frb-pins` reads a sixth source** when `rust/fuzz/Cargo.toml`
  names `flutter_rust_bridge` — a fuzz crate that drifts from the main crate
  does not merely disagree, it stops resolving, and nothing else notices.

  ⚠ **`protect-main.json` now carries a required status check, and arriving is
  not the same as being applied.** The file is in the tree; GitHub does not read
  it. Applying it takes `make setup-repo-protections ARGS="--update --yes"` as a
  separate step — and `--update` is the load-bearing half: the script is
  idempotent by ruleset **name**, so without it an existing `Protect main
  branch` is skipped with a message and exit 0, which looks exactly like
  success while changing nothing. Verified before overwriting that the live
  rulesets carry no hand-edits the file would clobber: `delete-branches` and
  `signing-commit` match byte for byte, `protect-release-tags` differs only in
  the order of two bypass actors, and `protect-main` differs only by the new
  rule plus a `required_reviewers: []` default GitHub echoes back. Until it
  runs, `codegen-guard` reports nothing and blocks nothing — and it has since
  been run: the live `Protect main branch` ruleset now carries the
  `FRB bindings were regenerated` check, matching the file.

- **The scope file and the README name the new surface**
  (`.github/agent-prompts/changelog-scope.md`, `README.md`) — the scope file is
  what every future openmls release is classified against, so a binding missing
  from it is a binding whose upstream changes get reported as invisible to this
  package's users. It now names `export_welcome_secret`,
  `propose_self_update_with_new_signer`, and `Lifetime` together with
  `KeyPackageIn::validate` — the latter because the whole of that validation
  (signature, protocol version, extensions, lifetime) is on the path
  `keyPackageLifetime` takes and is therefore user-visible. The README's feature
  table and full API reference list the four new names.

## [3.0.0] - 2026-09-06

### For Users

#### ✨ Highlights

- **The published package initialises again** — `2.0.1` shipped
  `flutter_rust_bridge: ^2.12.0` alongside generated bindings that record
  `2.12.0` and are compared against the runtime with `==`. flutter_rust_bridge
  2.13.0 was published on 2026-08-23 and landed inside that caret, so from that
  day on every fresh resolution — there is no committed lockfile to hold it
  still — threw from `RustLib.init()`. The constraint now admits exactly one
  version.
- **`flutter test` finds the native library** — `flutter_tools` installs the
  hooked library under `build/native_assets/<os>/`, a directory neither of the
  two paths searched before covered, so a Flutter package depending on this one
  failed in `init()` in its own unit tests while the app itself ran fine.
- **The post-quantum dependency tree moves off every advisory it was pinned to**
  — the X-Wing path's libcrux crates were held at exact versions by openmls
  0.8.1, and 0.9.0 moves all of them. The ignore lists shrink to one entry.
- **Nine more ciphersuites, all of them post-quantum** **(breaking)** —
  `MlsCiphersuite` grows from four values to thirteen, matching what the crypto
  provider actually runs. The nine were already going out on the wire in every
  leaf node built from the openmls 0.9.0 bump; they were simply not nameable in
  the Dart API, which made a group using one impossible to inspect and therefore
  impossible to decide about joining.
- **X-Wing is again the only suite delegated to libcrux** — three ML-KEM suites
  had begun routing to a backend validated only for X-Wing, and one of them
  could not run there at all. Both this and the item above arrived with the
  0.9.0 bump and are fixed in the same unreleased version, so no published
  release was ever affected.
- **Rust backtraces stop reaching Dart error strings** — the shipped binary
  enabled openmls's `test-utils` feature, and with it openmls formatted a
  symbolized backtrace into the internal errors that travel the ordinary error
  channel out to the caller. Dropping the feature also takes a test harness out
  of the release dependency graph.
- **openmls v0.9.0** — first upstream release since 0.8.1 (2026-02-13), and it
  closes an advisory this package had been working around locally.
- **openmls_frb v2.1.1** — Rust FFI bindings

#### Changed (Breaking)

- **`MlsCiphersuite` gains nine values** (`rust/src/api/types.rs`,
  `lib/src/rust/api/types.dart`) — the enum described four ciphersuites while
  the shipped crypto provider supported thirteen, and it was the provider's list
  that peers saw. `supportedCiphersuites()` now returns all thirteen, and every
  one of them is exercised by a full group lifecycle in both the Rust and the
  Dart test suites — created, added to, joined via Welcome, and messaged in both
  directions — rather than merely advertised.

  The gap was not cosmetic. Enabling `draft-ietf-mls-pq-ciphersuites` for X-Wing
  also put nine ML-KEM suites into OpenMLS's `default_ciphersuites()`, which is
  what `Capabilities::new` fills in when a caller does not pin capabilities — so
  from the 0.9.0 bump onward, key packages and leaf nodes advertised all
  thirteen. A peer picking one of the nine produced a group that
  `inspectWelcome` refused with `Unsupported ciphersuite`, *before* the
  application could decide whether to join, even though the join itself would
  have worked. 0.8.1's default list held exactly the four the enum named, so
  2.0.1 was consistent and the drift never reached a published release — it is
  introduced and fixed within this one.

  Ten of the thirteen are **experimental** suites on provisional code points
  that are not registered with IANA and may be renumbered or withdrawn; several
  are pure ML-KEM, with no classical component to fall back on. The README now
  lists every suite with its code point, its KEM and its signature, and says
  which are hybrid and which are not.

  **Action required:** an exhaustive `switch` over `MlsCiphersuite` no longer
  compiles. Add the nine new cases, or a `default:`. Stored state is untouched —
  the original four keep their names, their meanings and their positions in the
  enum, so existing values continue to serialize identically and no stored group
  or key package has to be migrated.

  **Action required, and this one is on the wire:** what a client advertises
  changes even if you touch no code. `MlsCapabilities.ciphersuites` reads an
  empty list as "use OpenMLS's defaults", and that default list grew with the
  same feature — from four entries to thirteen — so a leaf node or key package
  built without explicit capabilities now advertises all thirteen, nine of them
  provisional code points not registered with IANA. Nothing breaks: RFC 9420
  lets a client advertise suites it is never asked to run, and the group's suite
  stays the creator's choice. But a peer may now pick an experimental suite for
  a group you would join. To keep 2.0.1's advertised set, pass `MlsCapabilities`
  with an explicit `ciphersuites` list of raw code points — `[0x0001, 0x0002,
  0x0003]` — to `createGroupWithBuilder`, `proposeSelfUpdate` and
  `createKeyPackageWithOptions`.

#### Changed

- **The Android libraries are built with NDK r28 instead of r26**
  (`.github/workflows/build-openmls.yml`, `.copier-answers.yml`) — the shipped
  `.so` for all three ABIs is now produced by Clang 19 rather than Clang 17.
  Not a chosen upgrade. `rusqlite`'s `bundled-sqlcipher-vendored-openssl`
  vendors OpenSSL, and the openmls 0.9.0 bump re-resolved that from 3.5.5 to
  **3.6.3**, which ships an SM3 x86-64 assembly implementation using the Intel
  SM3 instructions `vsm3msg1`, `vsm3msg2` and `vsm3rnds2`. NDK r26's Clang 17
  does not know them, so `x86_64-linux-android` failed to build at all
  (`invalid instruction mnemonic`); Clang 18 is the first that assembles them,
  and r28 is the current stable line.

  Rolling OpenSSL back was rejected rather than untried: `openssl-src`'s newest
  3.5 packaging is `300.5.5+3.5.5`, and OpenSSL 3.5.5 carries seven CVEs fixed
  only in 3.5.6 and later, which that crate does not package. The rollback
  would have traded a build failure for known vulnerabilities.

  The gap that let this reach a release tag is that **Android is built only on
  an `openmls_frb-*` tag** — the `Tests` workflow never cross-compiles it — so
  the breakage sat on `main` from the 0.9.0 bump until the first tag after it.

- **flutter_rust_bridge 2.12.0 → 2.13.0** (`pubspec.yaml`, `rust/Cargo.toml`,
  `Makefile`, `lib/src/rust/`, `.copier-answers.yml`) — moved in all five places
  that have to agree, which `make verify-frb-pins` checks, and the published
  constraint is `>=2.13.0 <2.13.1`.

  The reason is compatibility with sibling packages rather than anything in
  2.13.0 itself. Because the constraint admits exactly one version — it has to,
  see the initialisation fix under Fixed — two flutter_rust_bridge wrappers
  pinned to different versions cannot resolve together in one application at
  all. `libsignal_dart` has moved to 2.13.0, so staying on 2.12.0 would have
  published a release known in advance to be unresolvable alongside its next
  one. Both published packages still agree on 2.12.0 today, which made this the
  last moment the divergence could be avoided rather than repaired.

  The move itself is mechanical. `rustContentHash` does not change
  (`585923240` before and after), so the wire signature between Dart and the
  native binary is unchanged; the whole Dart diff is the `@generated by` stamp
  in nine files plus one `codegenVersion` string; the generated Rust gains
  `std::result::Result::Ok` qualification throughout; and `Cargo.lock` moves the
  two flutter_rust_bridge crates and nothing else, so the third-party notices
  change by two version numbers.

  It does require the native binary this release builds anyway: the WebAssembly
  module comes out 8.9 KiB smaller (2,549,220 → 2,540,136 bytes), which is
  change enough to re-run the manual browser check that the crypto has no CI
  gate for — all four post-quantum lifecycles pass on the rebuilt module, with
  key package, commit and welcome sizes identical to the previous run.

- **openmls 0.8.1 → 0.9.0** (`rust/Cargo.toml`) — the X-Wing ciphersuite is
  unaffected despite an upstream feature gate. 0.9.0 puts
  `HpkeKemType::XWingKemDraft6` and
  `MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` behind
  `draft-ietf-mls-pq-ciphersuites`, but nothing was renamed and the code point
  is still 0x004D, so `MlsCiphersuite.mls256Xwing…` keeps working exactly as
  before. Existing databases are unaffected too: the storage format does not
  move, which was verified by reopening a database written by the published
  2.0.1 binary and decrypting a message it had encrypted and never opened.

- **Two upstream message states are now named instead of reported as unknown**
  (`rust/src/api/engine.rs`) — 0.9.0 splits `OwnPendingCommit` and
  `OwnPrivateMessage` out of what used to be errors, and `processMessage` would
  otherwise have returned "Unknown processed message content type" for both.
  `OwnPrivateMessage` replaces 0.8.1's `CannotDecryptOwnMessage`: the same
  input, the same rejection, reached by a different path, and it now says why —
  the own sender ratchet is encryption-only, so a message this client authored
  cannot be read back. `OwnPendingCommit` cannot occur through this engine at
  all, because every commit-producing call merges before it returns and no
  pending commit ever reaches storage; it is handled anyway. No type in the
  Dart API gains a value.

- **Key package lifetime validation errors read differently** (upstream) — no
  code changed here, but the strings these errors produce did, and an
  application matching on them will stop matching. `LifetimeError` replaced
  `RangeTooBig` / `NotCurrent` with `Expired { not_after, now }`,
  `NotValidYet { not_before, now }` and `SystemTimeBeforeUnixEpoch`, so the
  reason is now stated with the timestamps instead of being a single opaque
  case. At the same time `LeafNodeValidationError::Lifetime` and
  `KeyPackageVerifyError::InvalidLifetime` became `#[error(transparent)]`, which
  drops the wrapper prefix: where 0.8.1 produced "Lifetime is not acceptable.",
  0.9.0 produces the inner error's own text. These reach Dart through the
  ordinary error string, so treat the text as diagnostic and branch on the
  operation instead.

- **rusqlite 0.34 → 0.37** (`rust/Cargo.toml`) — not a chosen upgrade. openmls
  0.9.0 pulls `openmls_sqlite_storage`, which pins `rusqlite = "0.37"`; cargo
  resolves optional dependencies into the lockfile even when the feature is
  off, and `links = "sqlite3"` admits exactly one. Nothing about the database
  changes: the SQLCipher amalgamation libsqlite3-sys 0.35 bundles is
  byte-identical to the one 0.32 bundled (same SHA-256, SQLite 3.46.1), so the
  on-disk format is untouched.

#### Security

- **Three ciphersuites had begun using a crypto backend validated only for
  X-Wing** (`rust/src/hybrid_crypto.rs`) — this provider delegates one
  ciphersuite, X-Wing (0x004D), to OpenMLS's libcrux provider, because
  RustCrypto does not accept it; everything else runs on RustCrypto. The
  predicate that made that decision matched on the **KEM**, which identified
  exactly one suite in openmls 0.8.1. 0.9.0 gives `XWingKemDraft6` to four
  suites — X-Wing plus three `MLKEM768X25519` variants, which is arithmetically
  reasonable, since X-Wing *is* ML-KEM-768 combined with X25519 — so three
  ciphersuites silently began having their HPKE operations answered by a
  backend that had never been validated for them. This arrived with the 0.9.0
  bump in this same unreleased version, so no published release shipped it.

  One of the three could not be answered at all:
  `MLS_128_MLKEM768X25519_CHACHA20POLY1305_SHA384_MLDSA44` was advertised in
  every key package while libcrux rejected it with `UnsupportedCiphersuite`,
  having no ML-DSA signatures. RustCrypto implements it, so the routing fix
  makes that suite work rather than merely stop misrouting.

  The predicate now matches the whole `HpkeConfig` triple, which is unique per
  suite and is also the only information the HPKE methods receive — they are
  handed a config, never a ciphersuite. Two tests pin it, and they are the ones
  a libcrux advisory's reachability argument should now cite: one enumerates
  every supported ciphersuite and requires that exactly one reaches libcrux —
  by the predicate *and* by running HPKE keygen on a fresh provider per suite —
  and one keeps the advertised list and the provider in bijection so the set
  cannot grow unnoticed. `.cargo/audit.toml` and the security-review checklist
  now name them. The existing guard was not wrong, it was unbounded: it proved
  that a single hard-coded classical suite stays off libcrux, which said nothing
  about how many other suites had arrived there.

- **openmls no longer formats a Rust backtrace into errors the Dart caller
  receives** (`rust/Cargo.toml`, `rust/src/api/engine.rs`) — the shipped binary
  enabled openmls's `test-utils`, which implies its `backtrace` feature. With
  that on, `LibraryError::custom()` builds its message as
  `"Error description: {s}\n Backtrace:\n{…}"` — a symbolized Rust backtrace
  carrying build-machine paths, symbol names and crate layout. `LibraryError` is
  what openmls raises *instead of* unwrapping when an internal invariant is
  violated, and it is returned like any other error, so this package formatted
  it into the error string the caller gets. **No panic was required to reach
  it.** The feature is now off on every platform: the `" Backtrace:"` literal is
  gone from both shipped artifacts — the native library, 309 KiB smaller, and
  the WebAssembly one, 84 KiB smaller. Web consumers were affected too, because
  cargo unifies features across the platform-specific dependency tables, so the
  wasm32 build had been carrying `test-utils` as well.

  It could not simply be switched off before. Cargo features are additive, and
  `MlsGroup::export_group_context()` was gated behind `test-utils` along with
  the `tree_hash` and `confirmed_transcript_hash` accessors that
  `exportGroupContext()` reports, so dropping the feature meant dropping fields
  from `MlsGroupContextInfo` — a breaking change for the sake of a hygiene fix.
  openmls 0.9.0 made `MlsGroup::public_group()` public, and
  `export_group_context()` is a one-line wrapper over
  `self.public_group.group_context()`, so the replacement is the *same call
  chain* rather than an equivalent one: the same six fields, the same values,
  and regenerating the bindings produces no diff at all. Nothing in the Dart API
  changes.

  `SECURITY.md` described this feature as enabling "accessor methods" with "no
  test-only code paths activated in production". That was true of
  `openmls_basic_credential`'s feature of the same name — still enabled, still
  what makes `privateKey()` possible — but never of openmls's, and the entry now
  says which is which.

- **Signature private keys are wiped from memory when dropped** (upstream,
  `openmls_basic_credential` 0.5.0 → 0.6.0) — `SignatureKeyPair.private` was a
  plain `Vec<u8>`, so a signing key's bytes were left in freed heap memory when
  the pair went out of scope, and no `Drop` impl could be added downstream
  because the type is upstream's. It is now a `SecretVLBytes`, which is
  `ZeroizeOnDrop`. This package constructs one of these per signing operation,
  so it is on a hot path. The fix had been merged upstream since March and
  unreleased; this package argued for its release on
  [openmls#2116][om-2116], which 0.9.0 closes. It needs no change here.

- **The out-of-bounds parsing bug is now fixed upstream, not only worked around
  here** (`rust/Cargo.toml`) — [GHSA-rrmv-c79f-cf5r][gh-rrmv] was published on
  2026-08-25 with `patched_versions: 0.9.0`. It is the bug behind the
  `Read`-based decoder this package has carried since 1.4.2: openmls' manual
  `DeserializeBytes` impls sliced the input at the *re-serialized* length and
  indexed out of bounds when that exceeded the bytes actually consumed, on
  bytes that come straight off the network. Upstream now returns the
  authoritative unconsumed tail. The disclosure window is why 1.4.2's and
  2.0.0's entries describe this as hardening in general terms; this is the
  first release able to name it.

  The local decoder is gone with it (`rust/src/wire_decode.rs`,
  `rust/src/api/engine.rs`): all nineteen call sites decode through openmls'
  own `tls_deserialize_exact_bytes` again. That was held back until the fix
  covered *both* halves of the problem, because the workaround was never only
  about the panic — `Extension::tls_deserialize` did not require a payload to
  be fully consumed, so on input with trailing bytes the two decoders resumed
  from different offsets and disagreed about what the message said. 0.9.0
  fixes the remainder arithmetic (the advisory) and makes known structured
  extension payloads reject trailing bytes (upstream #2134), so the two paths
  now agree and the removal is behaviour-neutral rather than a rollback to the
  old behaviour. The fuzz target over those decoders is deliberately kept: the
  types are still what the API parses straight off the network, and they are
  worth fuzzing whichever decoder is behind them.

- **The X-Wing dependency tree moves off every pinned advisory version**
  (`rust/Cargo.lock`, `.cargo/audit.toml`, `rust/deny.toml`) — 0.8.1 pinned the
  libcrux crates at versions whose advisories could only be accepted or argued
  unreachable. 0.9.0 moves the whole tree: `libcrux-secrets` 0.0.5 → 0.0.6,
  which is the fix version for the one entry that was an **accepted**
  availability risk rather than an unreachable one (RUSTSEC-2026-0212,
  incorrect constant-time swap/select on aarch64); `libcrux-ed25519` 0.0.6 →
  0.0.9, past the 0.0.7 that fixes RUSTSEC-2026-0075; `libcrux-aead` 0.0.7 →
  0.0.9; `hpke-rs` 0.6.1 → 0.7.0. The ignore lists shrink accordingly —
  `.cargo/audit.toml` to nothing, `rust/deny.toml` to a single unmaintained
  build-time proc-macro — verified by deleting the entries and re-running the
  gates rather than by reading version numbers.

- **A panic on the web skips the zeroize that a native panic still performs**
  (`SECURITY.md`) — `wasm32-unknown-unknown` compiles with `panic = "abort"` by
  target default, so a Rust panic there traps the WebAssembly instance instead
  of unwinding and no destructor runs: the snapshot's plaintext `HashMap`s and
  the database key material are left in the module's linear memory until the
  page drops it. Native builds unwind and do zeroize — `[profile.release]`
  deliberately carries no `panic` key — so the hole is web-only and opens only
  on the panic path; ordinary operation zeroizes on both platforms. Nothing in
  the shipped package changed: the property was always this way and is now
  written down, as Known Limitation 12, because a web deployment's threat model
  depends on it.

- **The security policy now covers the post-quantum suites it ships**
  (`SECURITY.md`) — the file said nothing about them: no mention of libcrux,
  X-Wing, or a provisional code point anywhere. That was tolerable while the
  enum named four suites and one of them was experimental; it is not now that
  it names thirteen and ten are. Known Limitation 13 states what a reader has
  to decide about — the code points are unregistered and may be renumbered or
  withdrawn, several suites have no classical component to fall back on, the
  implementations are pre-1.0, and an empty `MlsCapabilities.ciphersuites`
  advertises all thirteen — and where the mitigation is. It also records the
  invariant the `.cargo/audit.toml` reachability arguments are stated over:
  exactly one suite reaches libcrux, enforced by three tests. Documentation
  only; nothing in the shipped code changed.

#### Fixed

- **The published key package lifetime default was wrong, and four other
  documents disagreed with the code** (`rust/src/api/types.rs`,
  `rust/src/api/keys.rs`, `rust/src/api/engine.rs`,
  `rust/src/api/credential.rs`, `README.md`, `SECURITY.md`, `lib/openmls.dart`)
  — `KeyPackageOptions.lifetimeSeconds` documented `None` as "default (90
  days)". openmls 0.9.0 sets that default to `3 * 28` days, i.e. **84**, and it
  is the default that applies: `createKeyPackage` builds without a lifetime and
  `createKeyPackageWithOptions` sets one only when the caller passes it. A
  rotation window sized off the docstring was sized against a number this
  package never used.

  Alongside it, six references in published doc comments named Rust spellings
  that do not exist on the Dart surface — `from_raw()` for `fromRaw`, and the
  parameters `db_path`, `encryption_key`, `process_message`,
  `certificate_chain`, `private_key`. `make doc` cannot catch these: the
  references are in plain backticks, which resolve nothing and so never warn.
  The README's hardening list named `signer.serialize()` as key material when
  it carries only the public key and scheme, where `SECURITY.md` names the two
  that do carry secrets; `SECURITY.md` described RustSec ignore justifications
  in `.cargo/audit.toml`, whose list is empty and whose header says so; the
  "Full API reference" omitted eight methods, two of which the security policy
  tells the reader to use; the architecture table gave iOS one architecture
  while the release ships and the build hook resolves an `x86_64` simulator
  slice (the cell now says so explicitly); and `lib/openmls.dart`'s install snippet still said `^1.0.0`.

- **The way to narrow what a key package advertises was undocumented, and the
  README said it did not exist** (`rust/src/api/engine.rs`,
  `lib/src/rust/api/engine.dart`, `README.md`) — `createKeyPackage` and
  `createKeyPackageWithOptions` carried no doc comment at all, and the README
  stated outright that "`createKeyPackage` takes no capabilities argument, so
  key packages always advertise the full list". The second half is false:
  `KeyPackageOptions.capabilities` exists and reaches
  `builder.leaf_node_capabilities`. Since this release is the one that grows
  the advertised list from four suites to thirteen, that sentence sat exactly
  where a reader would go looking for the mitigation and told them there was
  none. Both functions now document what the defaults advertise and which one
  to reach for; the README points at the option instead of ruling it out.

- **Six dead references in the published API documentation**
  (`rust/src/api/types.rs`, `rust/src/api/engine.rs`, `lib/src/rust/`) —
  flutter_rust_bridge copies a Rust doc comment into the generated Dart
  verbatim, and Rust's intra-doc syntax is not Dart's: ``[`MlsCiphersuite`]``
  puts a code span *inside* the brackets, which dartdoc reads as a reference
  named `` `MlsCiphersuite` `` and cannot resolve. Each one reached pub.dev as a
  dead link — the type-level note on `MlsCiphersuite`, the cross-reference
  between the two ML-DSA-87 suites, and the mentions of `supportedCiphersuites`,
  `MlsCapabilities.ciphersuites` and `MlsEngine.close`. They are now written the
  way this package's Rust API doc comments have to be written: plain backticks
  around the Dart camelCase name, which resolves on neither side and rots on
  neither either.

  Nothing here was noticed by a human: dartdoc reports an unresolved reference
  as a *warning* and exits zero, so the links had been dead for as long as they
  had existed. `make doc` is a blocking gate now (see the template adoption
  below), which is what surfaced them.

- **`RustLib.init()` threw for anyone who resolved this package after
  2026-08-23** (`pubspec.yaml`) — `flutter_rust_bridge` was declared as
  `^2.12.0`, while the committed `lib/src/rust/frb_generated.dart` records
  `codegenVersion => '2.12.0'` and the runtime compares that string to its own
  with `==`. flutter_rust_bridge 2.13.0 was published on 2026-08-23 and landed
  inside the caret, so every fresh resolution from that day on — this
  repository's CI and every consumer of the published package alike — failed
  initialisation with `codegen version (2.12.0) should be the same as runtime
  version (2.13.0)`. `pubspec.lock` is deliberately not committed for a
  library, so nothing held the version still, and the shipped archive carries
  both halves of the contradiction: the caret in its pubspec and the generated
  file that fixes the other side. The two pins that were already exact,
  `="2.12.0"` in `rust/Cargo.toml` and `FRB_CODEGEN_VERSION` in the `Makefile`,
  were never the ones at risk.

  The constraint now admits exactly one version, written `>=X.Y.Z <X.Y.Z+1` —
  this release ships `>=2.13.0 <2.13.1` (see the version move below; the shape
  is the fix, the number is a separate decision). Nothing wider is safe: the
  check is string equality, so every version a range admits except the one that
  generated the bindings fails, and a `<next minor` bound would only narrow the
  window — flutter_rust_bridge ships patch releases, and a 2.13.1 would break it
  identically. One version is also what upstream documents — *"all
  flutter_rust_bridge-related packages will need to have exactly the same
  version"* — and what its own `integrate` step writes with `dart pub add`.

  The range form, rather than the bare version, is forced by the release path
  and not by taste. `dart pub publish` warns that a single-version constraint
  "should allow more than one version", and it exits 65 on any warning, so
  `make publish-dry-run` — which both `make release` and `publish.yml` gate on
  — fails, and the package cannot be published at all. The `>=X.Y.Z <X.Y.Z+1`
  form resolves to the same single version and does not trip that check.
  Measured rather than assumed: four constraint shapes were run through
  `dart pub publish --dry-run`, and only the bare version produced the warning.

  One consequence for consumers, and it is the intended one. Anyone who also
  depends on another flutter_rust_bridge wrapper built against a different
  version now gets a version-solving failure out of `pub get`, instead of a
  successful resolve followed by a throw at `init()`. The incompatibility was
  always there — two sets of generated bindings cannot both equal one runtime
  version — so what changes is only that it surfaces where it can be acted on.

  Nothing else moves for this fix: `rustContentHash` is unchanged, so it needs
  no regeneration of its own. Worth stating what that hash does *not* cover,
  since this release leans on it nowhere: it is computed over the FFI function
  signatures, not over enum variants, so the ciphersuite expansion above leaves
  it unchanged too — bindings naming thirteen suites would load against a native
  binary that knows four without the runtime check firing. What prevents that is
  the release order rather than the hash. The build hook resolves its download
  from the crate version in `rust/Cargo.toml`, which ships inside the archive,
  and the stage-2 release refuses to run until the stage-1 native release for
  that exact version exists.

- **The native library was not found under `flutter test`**
  (`lib/src/platform/platform_io.dart`, `lib/src/openmls.dart`,
  `test/platform/native_asset_search_paths_test.dart`) — the build
  hook registers the library as a `CodeAsset`, but a `package:` asset id is not
  a path: `DynamicLibrary.open()` hands it to `dlopen` verbatim, only
  `@Native(assetId:)` externals go through the asset mapping, and
  flutter_rust_bridge needs a library handle — so the file has to be located on
  disk. The search covered `.dart_tool/lib/` (`dart run` / `dart test`) and
  `../lib/` next to the executable (AOT bundles). `flutter test` uses neither:
  flutter_tools installs the hooked library under `build/native_assets/<os>/`
  and never creates `.dart_tool/lib/`, and on macOS and Linux nothing on
  `flutter_tester`'s dlopen search path covers that directory — so a Flutter
  package depending on this one failed in `init()` in its own unit tests on a
  clean tree, while the app itself built and ran fine. A leftover
  `.dart_tool/lib/` from an earlier `dart test` is what made it look
  intermittent; Windows resolved it by accident, because flutter_tools prepends
  that same directory to the tester's `PATH`. The directory is now probed
  **last**: it is relative to the working directory, so ahead of the
  executable-relative entry it would let a shipped `dart build cli` binary load
  whatever happens to sit under `build/native_assets/<os>/` in the directory it
  was launched from, in preference to the library it shipped with.

### For Contributors

#### Added

- **A test now guards the release profile's panic strategy**
  (`rust/src/snapshot_storage.rs`, `rust/Cargo.toml`) — the *absence* of a
  `panic` key in `[profile.release]` is load-bearing: `panic = "abort"` would
  skip unwinding, so `Drop` would never run and the zeroize of both snapshot
  `HashMap`s and of the database key material would be silently bypassed,
  leaving plaintext key material in memory after any panic. Nothing in the tree
  recorded that, let alone enforced it. It cannot be checked at runtime —
  Cargo forces unwind for the `test` and `bench` profiles and rejects the key
  on per-package overrides, so the setting that actually ships is invisible
  from inside a test binary — so the test reads the manifest instead. It goes
  red on `panic = "abort"` in either TOML string form, on the section being
  renamed away, and — because an exact `[profile.release]` header match is a
  thing TOML gives several ways around — on any non-comment line of the
  manifest that names both `panic` and `abort`, whatever shape it is written
  in. Verified by putting `release.panic = "abort"` somewhere the header match
  cannot see and watching it go red.

#### Changed

- **The libcrux routing guard exercises all five HPKE methods, not one**
  (`rust/src/hybrid_crypto.rs`) — `libcrux_routing_is_limited_to_xwing` has
  two halves, and the operational half ran `derive_hpke_keypair` alone. Each
  of `hpke_seal`, `hpke_open`, `hpke_setup_sender_and_export`,
  `hpke_setup_receiver_and_export` and `derive_hpke_keypair` makes its own
  `routes_to_libcrux` call, so a wrong backend introduced in one of the other
  four left both halves green: the predicate is unchanged, and nothing called
  the method. All five now run per ciphersuite on a fresh provider, with a
  full seal/open round-trip and an exporter-secret agreement check, and
  libcrux must still be uninitialised after each — the failure names the
  method. Confirmed against the defect rather than the patch: routing
  `hpke_open` unconditionally to libcrux turns the test red on the first
  ciphersuite, where before it stayed green.

- **The two `unsafe_code` opt-outs are item-level, and the comments describing
  them are true** (`rust/src/encrypted_db.rs`, `rust/src/lib.rs`,
  `rust/Cargo.toml`) — `encrypted_db.rs` opened with a module-wide
  `#![allow(unsafe_code)]` for a single wasm32-gated `unsafe impl Send + Sync`
  pair, which exempted all 1,500 lines of it, native half included. The allow
  moves onto the two impls. Both comments said the bridge and this module opt
  out "each with its own attribute", naming a module-level one here; both now
  say item-level, which is what they both are.

- **`CLAUDE.md` described a version key that does not exist, and an unsigned
  release tag** — the native library version was documented as
  `openmls: native_version:` in `pubspec.yaml`; there is no such key, and
  `hook/build.dart` reads the crate version out of `rust/Cargo.toml`, which is
  what decides the binary a consumer downloads. The publishing checklist still
  ended in `git tag -a`, which the `Protect release tags` ruleset rejects for
  want of a signature and which the two-stage `make release-frb` / `make
  release` flow replaced; it now points at that flow and lists the gates to
  have green before it, including that stage 1 only *warns* when local main is
  ahead of origin.

- **copier template adopted: v4.7.0 → v4.8.0** (12 files) — half of it had
  already been contributed upstream from here, so what actually arrives is one
  CI gate and three script fixes.

  **`analysis_options.yaml` joins the test workflow's path filters**, on `push`
  and `pull_request` both. That file decides what `make analyze` reports, so a
  commit changing only the lint configuration was precisely the one that did
  not re-run the gate it changes — `dartdoc_options.yaml` sat one entry above
  for the same reason and was already listed. This was the one hole the update
  closed rather than confirmed.

  **`make release` now checks that the stage-1 binary was built from this
  tree**, not merely that a release carrying the same version string exists.
  The old check was keyed on the crate version alone, and the crate version
  does not move until stage 1 runs — so running stage 2 on its own passed it
  and would publish bindings against whatever binary the previous stage 1 left
  behind. Neither runtime net catches that: `rustContentHash` compares the FFI
  *surface*, which an FRB upgrade need not move, and the codegen assert
  compares the bindings against the flutter_rust_bridge runtime package.

  **Two version readers are anchored.** `getUpstreamVersion` — now split into a
  testable `parseUpstreamTag` — and `frbVersionFromGeneratedBindings` both used
  an unanchored `firstMatch`, which takes whichever match comes first in the
  file rather than the live declaration. A commented-out pin, the shape an
  upgrade leaves behind, therefore outranked the real one below it. Latent
  here, since this manifest carries no commented-out pin, and the direction
  that matters is a comment naming a *newer* tag: `check_updates.dart` would
  then report the dependency as already current and an upstream release,
  security fixes included, would silently never land, with nothing failing.

  **The manifest test that enforces the panic strategy moves to its template
  home.** It was contributed upstream from this project and comes back in
  `rust/src/utils.rs`, so the local copy in `rust/src/snapshot_storage.rs` is
  removed and `rust/Cargo.toml`'s comment now names the file that holds it. The
  suite still reports 27 tests; the assertion is the same one, and it still
  goes red both on `panic = "abort"` inside `[profile.release]` and on a
  `release.panic` written where an exact section match cannot see it.

- **copier template adopted: v4.6.0 → v4.7.0** (34 files) — the release is
  mostly gates, and two of them close holes this project knew it had.

  **wasm32 is executed in CI, not merely compiled.** `test-reusable.yml` gains
  `Build WASM` and `Rust unit tests (browser)`, and `make test-web` runs the
  crate's `#[cfg(target_arch = "wasm32")]` tests in headless Chrome through
  wasm-pack. Until now every wasm32 branch in the crate was covered by nothing:
  `make test` is the Dart VM and `make build-web` only compiles, while a wasm32
  body is a *different implementation* of the same function rather than the same
  code on another host. The manifest gains
  `[target.'cfg(target_arch = "wasm32")'.dev-dependencies] wasm-bindgen-test`,
  which is invisible to `make third-party-notices` — it runs
  `cargo tree --edges normal,build`, which excludes every dev-dependency on
  every target — and `make verify-third-party-notices` confirms the inventory is
  unchanged despite eight new crates in `Cargo.lock`.

  **Two documentation gates now block.** `make doc` promotes
  `unresolved-doc-reference` to an error through a new `dartdoc_options.yaml`
  (`.pubignore`d, so pub.dev's own dartdoc run is not held to it and a future
  dartdoc release cannot break documentation generation for an already-published
  version), and `make rust-doc` runs rustdoc under `-D warnings` on the host and
  on wasm32. The first was red on adoption — see the six dead references above.

  **Bookkeeping no longer outranks tests.** `verify-third-party-notices` and
  `verify-frb-pins` moved *after* the test steps, so a stale inventory no longer
  fails the Linux leg before a single test has run.

  **Answers, not just files.** `rust_version` is raised to `1.91` to match the
  manifest, so `README.md` and `CONTRIBUTING.md` stop advertising a toolchain
  that cannot build the crate and the next update cannot render the stale number
  back over it; the new `enable_freezed` question is answered `false`, because
  flutter_rust_bridge needs freezed only for data-carrying enums and structs
  this API does not have.

  Also arriving: `codegen-guard.yml` (a pull request labelled `codegen-failed`
  fails a required check rather than relying on a reviewer noticing),
  `.github/agent-prompts/repair-build.md`, `--locked` in the release builds,
  `make rust-geiger` and `make run-example-web`, `lib/src/rust/**` excluded from
  the coverage report (370 lines over 10 files becomes 51 over 4 — the
  hand-written half — both at 100%, so the badge does not move), four items in
  the upstream-bump checklist (a feature gate
  reads as `E0599`; features are additive and reach the shipped artifacts;
  advisory ignores are re-earned on every bump; MSRV lives in two files), and a
  CONTRIBUTING that is a document rather than a stub.

- **The `unsafe_code = "deny"` comment named an opt-out that does not exist**
  (`rust/Cargo.toml`, `rust/src/lib.rs`) — both copies listed
  `snapshot_storage`'s "interior-mutability shim" as one of three modules
  opting out of the deny, but that module contains no `unsafe` at all. There
  are two opt-outs: the FRB-generated bridge and `encrypted_db`'s WASM `unsafe
  impl Send + Sync`. The parenthetical claiming both go through a module-level
  `#![allow(unsafe_code)]` was wrong too — the bridge carries an item-level
  `#[allow]`. `SECURITY.md`'s own count was already right, which is how the
  drift stayed invisible.

- **MSRV 1.89 → 1.91** (`rust/Cargo.toml`) — required by openmls 0.9.0, whose
  workspace declares it. The 1.89 floor was ours, chosen for
  `std::fs::File::try_lock` so the single-writer lock would not need an `unsafe`
  `libc::flock`; that requirement still holds, it is simply no longer the
  binding one. No CI change was needed — the MSRV job reads `rust-version` out
  of the manifest and installs that toolchain, so the two cannot drift.

- **Dependabot may not raise rusqlite past 0.37** (`.github/dependabot.yml`) —
  for two independent reasons, both written out at the entry. It is pinned
  rather than chosen, because `openmls_sqlite_storage` requires `rusqlite
  = "0.37"` and `links = "sqlite3"` admits exactly one package, so 0.38+ does
  not resolve at all. And 0.40.x is separately unshippable: it bundles SQLCipher
  4.14.0, whose `sqlcipher_fprintf` allocates on Windows, so a failing
  `VirtualLock` under `cipher_memory_security = ON` logs a warning, which
  allocates, which recurses until the stack is gone. Pull requests #19 and #21
  both died that way, which is what makes it a ceiling rather than a
  postponement.

- **Dependabot may not propose the `hooks` / `code_assets` 2.x migration**
  (`.github/dependabot.yml`) — it is blocked by the pinned Flutter SDK, not by
  this repository's code: `hook/build.dart` needs a zero-line diff, since hooks
  2.0.0's one breaking change (`ProtocolExtension` from interface to base class)
  touches none of the three things it uses. What fails is version solving —
  hooks ≥ 2.1.0 pulls `record_use ^1.0.0`, which needs `meta ^1.19.0`, and
  Flutter 3.38.4 pins `meta: 1.17.0` exactly. The reason to ignore rather than
  leave a red pull request open is where the damage lands: the root package
  resolves fine because it has no `flutter: sdk` dependency, so this repository's
  own CI understates it, while merging would make the published package
  unresolvable for every Flutter consumer on an SDK that pins meta below 1.19.0
  — anyone on 3.44.x or earlier. Both names are ignored together because
  `code_assets 2.0.0` requires `hooks ^2.2.0`. Lift both when the pinned Flutter
  reaches 3.47.0, the first stable that relaxes the pin to `meta: ^1.18.3`.

- **Two guards now bound what the crypto routing may do**
  (`rust/src/hybrid_crypto.rs`, `.cargo/audit.toml`,
  `.github/workflows/test-reusable.yml`,
  `.claude/skills/security-review/SKILL.md`) — both were written before the
  routing fix and confirmed red against it, so they cover the defect rather than
  the patch. `libcrux_routing_is_limited_to_xwing` enumerates every supported
  ciphersuite and requires exactly one to reach libcrux;
  `openmls_defaults_are_executable_and_nameable` requires every suite OpenMLS
  advertises by default to be one this provider can run *and* the public enum
  can name, which is the guard at the source of the drift — that list is what
  goes on the wire whenever a caller does not pin capabilities.
  `api_list_matches_provider_support` was also tightened: its second loop used
  `if let Ok(..)`, so suites the enum could not name were skipped in silence,
  which is precisely how nine of them went unnoticed. The workflow comment that
  named a single test by hand is back to the template's wording, which refers to
  whichever tests a justification cites.

- **`openmls_basic_credential` names the post-quantum feature explicitly**
  (`rust/Cargo.toml`) — it was reaching the crate only through
  `openmls/draft-ietf-mls-pq-ciphersuites`, which propagates with `?` and so
  applies only while `openmls/test-utils` keeps the optional dependency alive.
  Without it `SignatureKeyPair::new` has no ML-DSA arms and the four ML-DSA
  ciphersuites cannot build an identity at all — a coupling that had to be
  broken before `test-utils` could be dropped from the shipped binary, which
  this same release then does (see Security). Feature-only change on its own:
  `Cargo.lock` and the third-party notices are untouched by this bullet.

- **A test harness no longer resolves into the release dependency graph**
  (`rust/Cargo.toml`, `rust/Cargo.lock`, `THIRD_PARTY_NOTICES.txt`) — dropping
  `openmls/test-utils` (see Security) takes fifteen crates out of the notices,
  279 → 264: `wasm-bindgen-test` with its macro and shared crates, `minicov`,
  `openmls_test`, `async-trait`, `cast`, `itertools` 0.14, `libm`,
  `nu-ansi-term`, `oorandom`, `same-file`, `walkdir`, `winapi-util` and
  `windows-sys`. Nine of them leave `Cargo.lock` outright; the rest stay
  resolved but unreachable. `openmls_memory_storage` is not among them — it is a
  plain dependency of `openmls_rust_crypto` and `openmls_libcrux_crypto`, not a
  test-only one. Neither is `backtrace`, which flutter_rust_bridge's
  `allo-isolate` declares independently of anything openmls does; what changed
  is that openmls's own feature of that name is off.

- **The example app's post-quantum tab covers three backend paths instead of
  one** (`example/lib/demos/post_quantum_demo.dart`) — it now runs the full
  lifecycle on X-Wing (libcrux), on the ML-KEM-768 + X25519 suite with an
  ML-DSA-44 signature (RustCrypto, and the suite a routing regression breaks
  outright), and on a pure ML-KEM-768 suite, after the classical regression
  check. CI now builds the WebAssembly module and runs the crate's browser
  tests (see the template adoption above), but that suite is a single test over
  `current_time`: no gate exercises a ciphersuite, the IndexedDB store or Web
  Crypto on wasm32. This tab remains the only runtime check of those, so it has
  to be re-run by hand after any change to ciphersuites or crypto routing, and
  it is now worth more when it is.

- **The upstream-bump checklist records the feature-gate trap**
  (`.claude/skills/update-openmls/SKILL.md`) — a gated ciphersuite variant
  reports as `E0599 ... no variant named XWingKemDraft6`, which reads exactly
  like a removal and cost this bump a wrong diagnosis. The checklist now says to
  look for a new cargo feature first, and that it has to go on all five openmls
  crates rather than only on `openmls`. A second block covers the opposite
  direction — which features must stay *off* in a shipped binary, and how to
  check the built artifacts for it — so a later bump cannot quietly restore the
  backtrace described under Security.

- **`make codegen` now uses the pinned generator** (`Makefile`) —
  `FRB_CODEGEN_VERSION` pins the binary that `make setup-frb-codegen` installs,
  but `codegen` did not depend on that target and ran whatever
  `flutter_rust_bridge_codegen` happened to be on `PATH`. Regenerating with a
  different version rewrites the bindings and the `codegenVersion` they carry
  — the same drift the three pins exist to prevent, arriving through the one
  door they did not cover. Where CI already ran the two in sequence nothing
  changes: the prerequisite only reads `--version` when the pinned binary is
  already installed.

- **Adopted copier template v4.3.0 → v4.4.0** (`.copier-answers.yml`,
  `Makefile`, `hook/build.dart`, `scripts/src/check_template_updates.dart`,
  `scripts/src/update_template.dart`,
  `.github/workflows/check-template-updates.yml`,
  `.claude/skills/update-template/SKILL.md`) — `make update-template` now runs
  copier with `--skip-tasks`. A single `copier update` renders the template
  three times and ran the generation tasks (`flutter create`, `dart pub get`,
  `dart format .`, `rm -rf _templates`) in every one of them, including the
  render into this project, where a task dying between the render and copier's
  replay of the project's own diff could leave a half-updated tree that still
  reported `_commit` as bumped. The update skill's conflict check moves from
  `find -name '*.rej'` — copier converts those to inline merges and unlinks
  them, so it always came back empty and read as "no conflicts" — to
  `git status --porcelain | grep '^UU'`, and the claim that copier's conflicts
  only ever land in Markdown is corrected in the skill, in this workflow's
  comments and in the warning it writes into every conflicted pull request — a
  single real update has since left conflicts in `Makefile`, `pubspec.yaml`,
  `rust/Cargo.toml`, `rust/src/frb_generated.rs` and two Dart scripts.
  `get-version` is now declared in `.PHONY`.

- **Adopted copier template v4.4.0 → v4.5.0** (`.copier-answers.yml`,
  `.githooks/pre-commit`, `scripts/src/common.dart`,
  `scripts/src/check_template_updates.dart`, `scripts/src/check_updates.dart`,
  `test/scripts/common_test.dart`,
  `.github/workflows/check-template-updates.yml`,
  `.github/workflows/check-openmls-updates.yml`, `CONTRIBUTING.md`,
  `CLAUDE.md`, `README.md`, `.claude/skills/update-template/SKILL.md`) — four
  changes, all of them to how this repository is worked on rather than to what
  it publishes.

  **The pre-commit hook runs `make rust-check` only when the commit touches
  `rust/`.** Measured here: the three gates together take about five seconds
  with warm caches, and `cargo check` is the one that stops being five seconds
  — 1s warm against 76s from an empty `rust/target`, which `make clean`
  produces outright and which a toolchain update or a dependency bump produce
  in effect. Most commits touch no Rust at all, including both commits that
  carried the previous template adoption. The predicate compares the index
  against HEAD under `rust/`, falls back to the empty tree on a first commit,
  fails open when git cannot answer, and announces the skip rather than
  performing it silently. A staged Rust file still blocks the commit when the
  crate does not compile, and CI runs `make rust-check` and `make rust-clippy`
  on every push regardless.

  **The update checkers authenticate to the GitHub API, and say what happened
  when it refuses.** Both asked for public releases without a token, which is
  quota rather than access: anonymous requests are counted at 60/hour per
  source IP, and hosted runners share theirs — one scheduled run died on a bare
  `403` for that reason. Both now send `GITHUB_TOKEN` (or `GH_TOKEN` locally),
  the workflows pass the job's own read-only token, and a failure keeps
  GitHub's own message and the `x-ratelimit-*` headers instead of reporting the
  status code alone, which could not tell a spent quota from a missing
  repository. `githubApiGet` and `describeGithubFailure` are shared in
  `common.dart` and covered by ten new tests.

  **The template update workflow explains a pull request it could not open.**
  When the App behind `APP_ID` lacks `Workflows: Read & write`, GitHub refuses
  the commit with `Resource not accessible by integration` on `POST /git/trees`
  — naming neither the file nor the permission, and only after every blob has
  been created. A failure-only step now says so, including that `Actions` is a
  different permission and that a granted permission does nothing until the
  installation accepts it.

  **Documentation stopped promising a changelog generator that no longer
  ran.** GitHub Models was in its retirement brownout, so the AI step failed on
  every run and labelled the pull request `changelog-needed`; the setup
  instructions said otherwise in three places, and the update skill told
  whoever ran it to expect an entry. `README.md` also still described template
  updates as notification pull requests, which is what they were before the
  workflow started applying them. The v4.6.0 adoption below replaces the
  provider outright, so these notices are gone again in the same release.

- **Adopted copier template v4.5.0 → v4.6.0** (`.copier-answers.yml`, and the
  files listed below) — five changes arrive with it.

  **The AI changelog works again, against a provider this repository names.**
  GitHub Models was retired on 2026-07-30 and the step had failed on every run
  since. `AI_MODELS` now holds an ordered `provider/model` list and the first
  entry that has a key and answers wins, so the next provider change is a
  repository-variable edit rather than a template release. Anthropic, Google and
  OpenRouter are each called through their own API over `dart:io` rather than a
  `curl` subprocess, because the HTTP status decides whether the next entry is
  tried and a subprocess would put the key in process arguments. The next entry
  is tried only when a model produced **no** answer — network failure, an
  auth/rate-limit/server status, a refusal, or a response cut off at the token
  limit — never on the content of an answer, and nothing is salvaged from a
  partial one: a missing field leaves the entry unwritten and the pull request
  labelled `changelog-needed`, which is the path that already existed.

  **This repository is not configured by the adoption itself.** There is no
  default list, deliberately: with `AI_MODELS` unset nothing is called, which is
  also how a project says "no AI here". Until the variable and a provider key
  are set, update pull requests keep arriving with `changelog-needed` exactly as
  they do today. `AI_MODELS_TOKEN` is now read nowhere and can be deleted.

  **What the entry is judged against is now written down**
  (`.github/agent-prompts/changelog-scope.md`) — which crates this package
  binds, what `MlsEngine` actually exposes, and which upstream areas it never
  touches, including that this package implements its own storage rather than
  using `openmls_memory_storage`. The prompt classifies every upstream change
  against that list, and an upstream change that cannot be tied to something
  named there is invisible to this package's users. The file is written once and
  never overwritten by a template update, so it is this repository's to keep
  current.

  **The test suite no longer skips `update-openmls-*` pull requests**
  (`.github/workflows/test.yml`) — the bump whose entire payload is new native
  code was the only pull request merged without the suite, clippy, `rust-test`,
  `cargo-deny`, the MSRV check or `verify-third-party-notices` running against
  it on any platform. `make build` runs before `make test` in the reusable
  workflow and the build hook then finds `rust/target/release` without
  downloading, which is what justified the skip and now removes the need for it.
  **This had an immediate consequence:** PR #15 (openmls 0.9.0) started running
  the suite and failed. That failure was real and had been invisible — but the
  cause recorded here when this entry was written was wrong, and is corrected
  rather than left standing: `HpkeKemType::XWingKemDraft6` and the
  `MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` ciphersuite were read as
  removed upstream, and neither was. Both still exist in 0.9.0 with unchanged
  spelling and the same 0x004D code point, behind the new
  `draft-ietf-mls-pq-ciphersuites` feature. A feature-gated variant reports as
  `E0599 ... no variant named X`, which is indistinguishable from a removal
  without checking upstream — the misreading the bump checklist now warns
  about.

  **`make verify-frb-pins`, and Dependabot on `pub` and `cargo`**
  (`Makefile`, `scripts/verify_frb_pins.dart`, `.github/dependabot.yml`) — five
  files record the flutter_rust_bridge version and two of them are compared with
  `==` at runtime, so the new gate reads all five and rejects both a caret and
  the unpublishable bare form, with the reason. It reads every occurrence rather
  than the first, because the first is not always the one that counts: a
  `dependency_overrides` entry replaces the dependency outright, a second pin in
  a `[target.'cfg(…)']` section resolves per target, and make takes a later `=`
  over an earlier `?=`. It runs beside `verify-third-party-notices` on the Linux
  leg; five file reads, no build.
  Dependabot now watches the published constraints and the native crate's
  dependencies, ignoring `flutter_rust_bridge` in both because its version has
  to move in four places at once and a one-file pull request is wrong by
  construction. The upstream crates are ignored under `cargo` for a different reason: Dependabot's cargo updater does follow git refs, so without that it would open its own pull request for the same bump the update workflow exists to make — without codegen, the bindings tripwire, the CHANGELOG entry or the version badge.

  Also in this adoption: `lints` capped to one minor line because
  `make analyze ARGS="--fatal-infos"` turns any new info-level lint into a build
  failure and `pubspec.lock` is not committed (precautionary — 6.1.0 was
  measured against this repository with nothing to report); `ffigen`'s floor
  raised to `^20.1.1`; protoc added to the template-update workflow's gates
  upstream, which this repository does not render since it needs no protobuf
  compiler; and the repair and review agents, both inert until `AGENT_ENGINE`
  names one.

- **Dependabot no longer rewrites constraints it was told to leave alone** (`.github/dependabot.yml`) — `pub`'s default versioning strategy is `widen`, "extend only the upper bound to include the new version", and it applies that across the whole manifest rather than only to what it is updating. The first run here opened a pull request whose four updates were `ffigen`, `lints`, `code_assets` and `hooks` — and which also rewrote `flutter_rust_bridge` from `">=2.12.0 <2.12.1"` to `^2.12.0`. That is the one constraint in this file that must not float: it is the exact regression that broke every consumer of the published package when flutter_rust_bridge 2.13.0 landed inside that caret. `lints`, `ffigen` and `hooks` were widened past bounds set on purpose as well.

  `ignore` is no defence, and it is worth being precise about why: it stops Dependabot opening a pull request *for* a dependency, not editing that dependency's constraint while it edits the file for other reasons. `flutter_rust_bridge` was ignored and rewritten anyway. `versioning-strategy: increase-if-necessary` fixes it — a constraint that already admits the new version is left alone, so a dependency nothing is updating stays untouched. `cargo` needs none of this: on the same run it changed exactly the one crate it was bumping and left every pin alone.

  `make verify-frb-pins` caught the rewrite on all four platforms before it could merge — its first real encounter, and what it exists for.

- **The `pub` and `cargo` groups take minor and patch only** (`.github/dependabot.yml`) — grouping a major with everything else blocks the rest: one unmergeable entry takes the whole pull request down.

  It separates more than its name suggests, and the first run after the change is the evidence. Dependabot's commit trailers report a 0.x bump as `version-update:semver-minor`, but its *grouping* applies Cargo's own reading, where a 0.x minor is the breaking bump, and keeps them out of a `minor`+`patch` group anyway. The six-crate cargo group split into a group of two (`log` patch, `uuid` 1.x minor) plus one pull request each for `rand`, `sha2`, `hkdf` and `aes-gcm-siv` — the four that need a migration. Exactly the intended shape.

- **`dart-lang/setup-dart`'s problem matcher is switched off at the source** (`.github/actions/setup-fvm/action.yml`, `.github/dependabot.yml`) — 1.8.0 added a problem matcher for `dart analyze` and registers it with `::add-matcher::dart-analyzer.json`. The path resolves against the *calling* action's directory, and this repository calls setup-dart from inside its own `setup-fvm` composite action, so the runner looked under `.github/actions/setup-fvm/`, did not find it, and failed the job fourteen seconds in, before anything was built. It failed that way on all four platforms.

  The first response, within this same unreleased range, was a Dependabot `ignore` on the 1.8 line. That was the wrong tool twice over. The action is now pinned to 1.8.1 with `problem-matcher: 'false'`, which is the input the upstream issue points at, so the version is free to move again — and the ignore has been deleted, because `versions: ["1.8.x"]` never matched anything in the first place: Dependabot parses that string through `Gem::Requirement`, which has no wildcard expansion. It sat in the file looking like protection while the bot went on proposing the bump. The same reading applies to the `hooks` and `code_assets` majors, whose ignores are rewritten from `versions: ["2.x"]` to `update-types: [version-update:semver-major]` in the same pass.

  The bump was worth little here in any case: setup-dart exists in that action solely to provide a `dart` binary for `dart pub global activate fvm` on the next line, and everything that builds and tests this package comes from the FVM-pinned SDK.

## Older releases

2.0.1 and everything before it are in
[CHANGELOG-ARCHIVE.md](https://github.com/djx-y-z/openmls_dart/blob/main/CHANGELOG-ARCHIVE.md).

[gh-rrmv]: https://github.com/openmls/openmls/security/advisories/GHSA-rrmv-c79f-cf5r
[om-2116]: https://github.com/openmls/openmls/issues/2116
[frb2575]: https://github.com/fzyzcjy/flutter_rust_bridge/issues/2575
[frb3182]: https://github.com/fzyzcjy/flutter_rust_bridge/pull/3182
[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v3.2.2...HEAD
[3.2.2]: https://github.com/djx-y-z/openmls_dart/compare/v3.2.1...v3.2.2
[3.2.1]: https://github.com/djx-y-z/openmls_dart/compare/v3.2.0...v3.2.1
[3.2.0]: https://github.com/djx-y-z/openmls_dart/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/djx-y-z/openmls_dart/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/djx-y-z/openmls_dart/compare/v2.0.1...v3.0.0
