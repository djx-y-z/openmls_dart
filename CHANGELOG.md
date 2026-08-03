## [2.0.1] - 2026-08-03

### For Users

#### ✨ Highlights

- **openmls_frb v2.0.1** — Rust FFI bindings

#### Security

- **Ratchet trees and key packages now decode on the panic-free path** —
  joining from a Welcome or an external commit decodes the sender's
  `ratchetTreeBytes`, and every add-member entry point decodes peer key
  packages. Both went through openmls' `tls_deserialize_exact_bytes`, whose
  hand-written `DeserializeBytes` impls slice the input at the *re-serialized*
  length and index out of bounds when that exceeds the bytes actually consumed.
  `RatchetTreeIn` and `KeyPackageIn` reach those impls through the `Extension`
  and `UnmergedLeaves` fields nested in their leaf and parent nodes — the same
  shape behind the `MlsMessageIn` parsing fix in 2.0.0, which covered MLS
  messages but not these two types. They now use the same `Read`-based decoder.
  Defense in depth: no input is known that reaches the panic through these
  types. Both decoders run the same validation and differ only in the cursor
  arithmetic that follows, so on anything a conforming implementation emits they
  agree exactly. They can diverge only where that arithmetic was already wrong:
  openmls does not require an extension's payload to be fully consumed, so a
  payload carrying trailing bytes left the old path resuming from the wrong
  offset. Such input now parses correctly instead of being misread, and still
  has to pass the usual key-package and leaf-node validation afterwards.

### For Contributors

#### Fixed

- **Template update notifications had stopped working, silently and
  invisibly** (`.github/workflows/check-template-updates.yml`) — the workflow
  opened a pull request whose payload was its *description*: the version table,
  the template's changelog for the range, and manual update instructions. Its
  diff was meant to be empty. But `create-pull-request` opens nothing when
  there is no diff and exits silently — stated in its README and guarded by
  `if (result.hasDiffWithBase)` in the SHA this project pins — so those pull
  requests only ever existed because something made the tree dirty. That
  was `.fvmrc`, rewritten by `fvm install` on every run: every notification
  ever opened here (#1, #7, #8, #10) carried exactly one file, `.fvmrc`, at
  +3/-3, and nothing else. Fixing that drift in template v4.2.0 removed the
  accidental payload, so the very next template release would have produced a
  green job, a step summary reading "a notification PR has been created", and
  no pull request — detectable only as the absence of something nobody was
  watching for, which is the same shape that hid the FVM cache bug for months.
  The workflow now has a real payload, and the absence is checked rather than
  assumed: a run that found an update and did not open a pull request fails and
  says not to read it as "nothing to do".

- **A mistyped signing passphrase no longer aborts a release**
  (`scripts/src/release_common.dart`, `scripts/src/release.dart`,
  `scripts/src/release_frb.dart`) — git signs a commit or a tag by shelling out
  to `ssh-keygen -Y sign` (or `gpg`), and both give up after a *single* wrong
  passphrase rather than re-prompting. One typo therefore aborted the release
  wherever it happened, and the position that hurts is between the commit and
  the tag: the version bump is committed, no tag exists, and re-running the
  command fails its own "must be greater than the current version" precondition
  — leaving reverting the commit or tagging and pushing by hand as the only ways
  out. Both stages now route every signing and push step through
  `runInheritRetry`, which prints the failure and runs the step again, so the
  passphrase prompt simply comes back the way `ssh` and `sudo` behave — no
  question to answer. **Ctrl-C is the way out**, and it works: with
  `inheritStdio` the interrupt reaches the whole foreground group, verified at
  the passphrase prompt itself. The loop is uncapped, because a cap would
  reinstate the very failure it exists to prevent, so the two things bounding it
  carry the weight. **A non-interactive stdin throws on the first failure**, CI
  behaviour unchanged: nobody is there to retype anything or to interrupt, so a
  structurally broken step would otherwise spin forever. That test is
  `stdin.echoMode` and not `stdin.hasTerminal`, which reports `terminal` for any
  character device and so calls a run redirected from `/dev/null` interactive.
  **From the third consecutive failure the loop paces itself** at 2s and says
  so; the first retries stay immediate, so a typo is never slowed, while a step
  failing in milliseconds cannot scroll past faster than it can be read.

- **An interrupted release is resumed by re-running the same command**
  (`scripts/src/release_common.dart`, `scripts/src/release.dart`,
  `scripts/src/release_frb.dart`) — the retry above covers a typo, but not a
  Ctrl-C or a closed terminal, both of which strand the release in the same
  half-finished state. Both stages now recognise it and continue
  from the tag (or push) step, skipping the bump and the CHANGELOG edit so
  nothing is applied twice. Because a false positive would tag and push a commit
  that is not the release commit, detection requires *all* of: a clean working
  tree, the version file already reading exactly the requested version, and
  `HEAD`'s subject equal to the exact subject the release writes — built from
  the same expression that builds the commit message, so the two cannot drift.
  A leftover tag is accepted only when it is this release's tag *and* points at
  `HEAD`; the same name on any other commit is refused, as is a tag already on
  origin. Declining the confirmation prompt on a fresh run still reverts the
  edits; on a resumed run it leaves the commit in place and says so. Interrupting
  *before* the commit is the one case nothing can report at the time — Ctrl-C
  kills the script mid-step — so the next run's "working tree is not clean"
  recognises when the only modified paths are the release's own files and names
  the single `git restore` that discards them.

#### Added

- **Template updates are applied automatically, not just announced**
  (`scripts/update_template.dart`, `scripts/src/update_template.dart`,
  `make update-template`, `.github/workflows/check-template-updates.yml`) — the
  scheduled check now runs `copier update` itself and opens a pull request
  carrying the result, the way the dependency update workflow already does.
  Everything it needs comes from `.copier-answers.yml`, so the new scripts name
  neither this project nor its upstream library and can move into the template
  unchanged. Copier is pinned (9.11.1) for the reason the actions are pinned by
  SHA: this runs unattended, and a release that changed how copier merges would
  arrive as a conflict-shaped diff rather than a clean failure.
  Two outcomes are reported separately, because they are independent and both
  are quiet. A **conflict** leaves both sides in the file; the pull request
  becomes a draft, lists the files and says why nothing else caught it — the
  format, Rust and analysis gates read only Dart and Rust, and every conflict
  copier has produced in this project so far has been in Markdown, which passes
  all three intact. **`_commit` failing to land** is the other: copier can
  apply every file and still leave `.copier-answers.yml` on the old version,
  which merges as an un-updated project and re-opens the same pull request
  forever. That one fails the job — after the pull request exists, so the work
  is kept. They do not imply each other: this release's own update landed
  `_commit` while `CONTRIBUTING.md` was still conflicted.
  The three checks the pre-commit hook runs are executed and reported in the
  body, never enforced — a template update that breaks a gate is precisely the
  one a human most needs to see. The CHANGELOG entry is written by AI from the
  template's changelog *and* the diff that actually landed, since a template
  release describes changes for every project generated from it and most of it
  can arrive here as a no-op. It is filed under `### For Contributors` →
  `#### Changed`, where every prior adoption lives, and the pull request asks a
  reviewer to move it if the release changes shipped behaviour.
  One dependency is worth naming: copier refuses to update a dirty destination,
  untracked files included, so the `.fvmrc` drift fix is not merely related to
  this automation — without it, `fvm install` would leave the tree dirty and
  every automated update would refuse to run.

- **`test/scripts/update_template_test.dart`** — covers the two pure decisions
  the automation makes. `parseUnmergedPaths` collapses the three conflict
  stages `git ls-files -u` prints into one path and keeps paths containing
  spaces intact; `hasConflictMarkers` is anchored at line start so this
  repository's own documentation of how to grep for conflicts does not register
  as one. `insertContributorChangelogEntry` is covered over every shape the
  file can be in: an existing subsection, a missing one, `#### Changed
  (Breaking)` which must never receive the entry, a missing `### For
  Contributors`, a missing `## [Unreleased]` — and, in every case, that nothing
  is written into the released section above.

- **`test/scripts/release_common_test.dart`** — covers `isResumableRelease`,
  the one predicate in the release scripts whose false positive is
  unrecoverable, over each condition that must individually block a resume; and
  `onlyTheseFilesDirty`, which decides whether the not-clean message may name a
  `git restore` — it declines on an untracked path and on a rename rather than
  suggest a command that would not work, or would discard something else.

- **`wire_decode` fuzz target** — fuzzes the decoder the group-join and
  add-member APIs use, over `MlsMessageIn`, `RatchetTreeIn` and `KeyPackageIn`.
  The ratchet-tree and key-package paths were not covered by any target before.

#### Changed

- **copier template adopted: v4.2.0 → v4.3.0** — a single change, and it repairs
  something 4.2.0 shipped broken. Interrupting a release before its commit
  leaves only the release's own files modified, and 4.2.0 added a message that
  recognises that state and names the one `git restore` which discards them. It
  never fired. The status was read through `git()`, which trims its output;
  `git status --porcelain` has two positional status columns, so an unstaged
  modification is `' M path'`, and trimming ate the leading space of the *first*
  line and shifted that path by one character. `onlyTheseFilesDirty` then
  matched nothing and rejected the whole status, so every interrupted release
  got the generic "working tree is not clean" instead — in exactly the case the
  hint was written for, since a release edits its files without staging them.
  Both stages now read the status through a `gitStatus()` that strips only
  trailing newlines, and a test pins the raw and trimmed shapes against each
  other so a future trim cannot pass unnoticed. Found while writing a release
  script for the template repository itself, which had inherited the same shape.
  This is also the first update applied by the automation added above rather
  than by hand.

- **The panic-free decoder moved out of `api/engine.rs`** — `from_exact_bytes`
  now lives in `rust/src/wire_decode.rs` and is generic over the decoded type,
  so one helper covers all four call-site types and the fuzz crate can drive the
  real decoder. The alternative, giving `rust/fuzz` its own `openmls`
  dependency, would have left a second upstream tag that
  `make check-new-openmls-version` does not bump.

- **copier template adopted: v4.1.0 → v4.2.0** — the release-script half of this
  version was written here and upstreamed, so it arrives byte-identical and
  lands as a no-op; it is the retry and resume work documented above. What the
  adoption actually changes is the development environment.
  **The pre-commit hook is executable at last** — it was committed mode 644, and
  git skips a non-executable hook without saying anything, so nothing it checks
  ever ran. It is 755 now, and copier carries the bit through on an update, not
  only on a fresh render. Its content carried a second failure that could only
  surface once it started running: it announced every step-1 failure as a
  formatting problem, so a hook invoked from an IDE or GUI git client — which
  inherits a minimal PATH where `make`, `fvm` and `cargo` are all missing — told
  you to run `make format` when the real problem was PATH. It now appends the
  usual install locations and names the missing tool instead of blaming
  whichever check ran first.
  **`.fvmrc` and `.vscode/settings.json` no longer drift on every
  `make codegen`** — `flutter_rust_bridge_codegen` shells out to `fvm install`
  twice per run, and `fvm install` rewrites both files unless they already match
  its own output byte for byte, so every codegen left two modified files
  unrelated to the generated bindings, and in CI they rode along into the
  automated update PRs. `.fvmrc` is now committed in fvm's own serialization —
  its key order and no trailing newline — with `"updateVscodeSettings": false`,
  which is what stops the second file being touched; `.gitattributes` marks it
  `-text`, because a Windows checkout under the default `core.autocrlf=true`
  would otherwise land CRLF and break the byte-match invariant while git still
  reported the tree clean; and `.vscode/settings.json` is now committed rather
  than generated, since with fvm no longer writing it a machine that lacks the
  privileges for fvm's own symlink would leave `dart.flutterSdkPath` unset. It
  points at `.fvm/flutter_sdk`, the version-agnostic symlink, so a Flutter bump
  does not need to edit it. Verified here: `fvm install` now leaves both files
  byte-identical.
  **`setup_repo_protections.dart` also sets `delete_branch_on_merge`** — the
  script applied rulesets and the `native-build` environment but never touched
  repo settings, so every merged branch stayed forever, and the dependency and
  template update workflows open one per upstream version several times a week.
  Adopting the script does not change the setting; it takes effect the next time
  `make setup-repo-protections` runs against GitHub.

## [2.0.0] - 2026-07-30

### For Users

#### ✨ Highlights

- **Concurrent work on one group no longer loses writes** — every engine
  operation runs under an engine-wide lock, and a database file admits a single
  engine at a time **(breaking)**. Overlapping calls used to load the same
  snapshot and the later write-back dropped the other's changes: a merged
  commit, an epoch advance or a ratchet step could disappear, desynchronizing
  the group and leaving messages undecryptable.
- **The storage layer stops leaving MLS plaintext behind** — undefined behavior
  removed from the snapshot provider, SQLCipher wipes its own working buffers,
  and the copies the wrapper itself kept (the write-back diff, the hex
  encryption key, overwritten and deleted entries) are zeroized. Database files
  are created owner-only and `deleteGroup` is atomic.
- **The package ships `THIRD_PARTY_NOTICES.txt`** — the licence texts the
  statically linked native library must carry with it, generated from the
  resolved dependency graph across all released targets and verified
  byte-for-byte in CI.
- **openmls** — unchanged this release (openmls-v0.8.1)
- **openmls_frb v2.0.0** — Rust FFI bindings

#### Changed (Breaking)

- **Only one engine may hold a database file** — the SQLCipher connection now
  takes an exclusive lock at open. A second `MlsEngine` on the same path —
  another instance, isolate, or process — fails with *"Database is already open
  by another connection or process"* instead of quietly running its own
  load → operate → save cycle over the same rows and overwriting the first
  engine's group state. `close()` releases the lock, and an overlapping opener
  waits out a five-second timeout first, so handing the file over during
  teardown still works.
  On Unix the lock is held partly by a new file next to the database,
  `<db_path>.lock`, because SQLite's own locks are POSIX advisory locks and
  POSIX drops every one a process holds on a file as soon as that process
  closes *any* descriptor for it — so one unrelated read of the database from
  elsewhere in an app (a backup copy, an integrity check, a crash reporter)
  silently released the exclusive lock while the engine was still running, with
  no error, letting another process in. The lock file is created empty and
  `0600` and is never deleted; it holds no data, so it needs no special
  handling in backups, but deleting it while an engine is running lets a second
  engine open the same database. `":memory:"` databases and Windows do not get
  one.
  **Action required — only if your app opens the MLS database from more than
  one place** (a background isolate, a share extension, a second engine
  instance): route them through a single engine, or give each its own file.
  One engine kept open for the lifetime of the app needs no changes and no
  lifecycle handling. `close()` is what hands the file from one engine to the
  next; a hot restart during development or a killed process releases the lock
  on its own, so the engine that follows opens without waiting out that
  timeout.
- **A `file:` URI as `dbPath` is now rejected** — `create()` fails instead of
  opening a database that silently gets neither owner-only permissions nor the
  single-writer lock file above, because the path a URI resolves to cannot be
  recovered without parsing its query parameters.
  **Action required — only if you pass a `file:` URI:** pass the plain path
  instead. Plain paths and `":memory:"` are unaffected.

#### Changed

- **The package ships `THIRD_PARTY_NOTICES.txt`** — the prebuilt native library
  is statically linked against its Rust dependency tree, and MIT, BSD and
  Apache-2.0 all require those notices to travel with a binary distribution,
  including an application that embeds the library. Flutter's `LicenseRegistry`
  does not cover them: it aggregates `LICENSE` files of pub packages, and Rust
  crates are not pub packages. The file sits at the package root and inside
  every native release archive, and is generated from the resolved dependency
  graph across all released targets — build edges included, because that is how
  vendored native code reaches the binary: the bundled OpenSSL arrives as a
  build-dependency of `openssl-sys` and would otherwise go unattributed
  (264 crates, 152 shipped licence texts). Licences a crate keeps beside
  vendored code are collected too — SQLCipher's, the Dart SDK headers', the
  Unicode tables' — as are those a git dependency keeps at its repository root
  rather than in the member directory, which is where every upstream MLS crate
  keeps its own. Where a crate ships no licence file at all, the canonical text
  of the licence it declares is supplied in its place, so the file delivers the
  licences rather than merely naming them. It is deliberately **not** declared
  under `flutter: assets:` — a package-declared asset is bundled into every
  consuming application whether or not it is used. README documents the two
  lines needed to surface the notices at runtime for apps that want them.

- **Durability settings are explicit** — connections are opened with
  `journal_mode = DELETE`, verified, so a database left in WAL mode is
  converted instead of silently keeping a side file that a crash or a
  file-level backup can drop, and with `synchronous = FULL`. `fullfsync` is
  deliberately left off: on Apple platforms it also flushes the drive's own
  write cache, measured at 16 ms per MLS operation against 318 µs without it —
  paid on every message sent and received. SECURITY.md records the trade-off.

#### Security

- **Serialized concurrent operations on an engine** — every engine method loads
  a snapshot of the stored group state, lets OpenMLS mutate it, then writes the
  diff back, but nothing held that span together: two overlapping calls loaded
  the same base snapshot and the later write-back dropped the other's changes.
  A merged commit, an epoch advance, a stored proposal or a ratchet step could
  silently disappear, desynchronizing the group and leaving messages
  undecryptable. Each operation now runs under an engine-wide async lock —
  async because the span contains `.await` points, and because the same
  interleaving happens on WASM's single thread with no threads involved at all.
  This was a lost update, not key reuse: MLS gives every message a fresh random
  `reuse_guard`, so two sends off one snapshot still got different nonces.
- **SQLCipher now wipes its own memory** — connections set
  `cipher_memory_security = ON`, verified on open, so SQLCipher zeroes its
  working buffers when freeing them and asks the OS to keep them out of swap.
  Those buffers hold MLS plaintext while it is being encrypted — the residue
  the wrapper's own zeroization cannot reach. Measured cost: +20% per operation
  (~62 µs).
- **Wiped the storage layer's remaining plaintext copies** — the diff handed to
  the database cloned every changed value out of the snapshot and dropped those
  clones unwiped; they are zeroized once written. The encryption key's hex form
  was built with a `format!` per byte, leaving 32 small allocations of key
  material behind; it is now built into a single `Zeroizing` buffer and wiped
  as soon as the key pragma has run.
- **`deleteGroup` is atomic** — it wrote the group's final state and then
  purged the group's rows in two transactions; a crash in between left rows of
  a deleted group behind. Both happen in one transaction now, on native and on
  WASM.
- **Database files are created owner-only** — on Unix the file is pre-created
  with mode `0600` rather than inheriting the process umask (typically
  world-readable `0644` on desktops), and an existing file is tightened on
  open. SQLite gives the journal file the same mode.
- **Documented the anti-rollback requirement** — encryption at rest does not
  protect freshness: restoring an older copy of the database replays MLS state
  that was already spent, and the 32-bit `reuse_guard` that makes a single
  rollback merely a rejected message erodes across a large or repeated one.
  SECURITY.md now asks deployments to place the database on rollback-protected
  storage (hardware monotonic counter, TPM 2.0 NV, Android StrongBox), notes
  that sealing the key in hardware protects confidentiality rather than
  freshness, and records that iOS exposes no such counter to apps.
- **Removed undefined behavior from the snapshot storage provider** — the
  `StorageProvider` implementation reached its snapshot through 35 `&self` →
  `&mut self` pointer casts guarded by `#[allow(invalid_reference_casting)]`.
  That cast is undefined behavior regardless of threading: `&self` carries LLVM's
  `noalias`, so a release build (`lto = true`, `opt-level = "z"`) is entitled to
  cache or reorder reads across those writes. Replaced with proper interior
  mutability (`parking_lot::Mutex`), which lets the module drop its
  `#![allow(unsafe_code)]` escape hatch — the crate now denies `unsafe_code`
  everywhere except the generated FRB bridge.
- **Zeroize storage values on overwrite and delete** — replacing or removing a
  snapshot entry previously dropped the old value without wiping it, leaving
  plaintext MLS secrets in freed heap memory for the rest of the operation.

#### Fixed

- **Stopped leaking snapshot allocations on every MLS operation** —
  `into_updates()` ended with `std::mem::forget(self)`, so both `HashMap`
  backing tables were never freed. The `forget` was unnecessary: after both maps
  are drained, the `Drop` impl is a no-op.
- **Build hook no longer re-runs on every build** — the hook declared the
  `.skip_openmls_hook` marker as a build dependency unconditionally, including
  when the marker does not exist (the normal case for every consumer).
  `hooks_runner` treats a declared-but-missing file as modified during the
  build, forcing a redundant second hook pass on each build. The marker is now
  declared only while it exists, which still invalidates the skipped result once
  the marker is removed.

### For Contributors

#### Fixed

- **Repaired the scheduled openmls update check** — the upstream tag guard
  adopted with copier template v3.0.0 hardcoded `^v?\d+\.\d+\.\d+$`, which
  rejects this repo's own `openmls-v` tag prefix, so every run failed with
  `Refusing unexpected upstream tag_name format`. The workflow's blanket
  `|| true` hid that behind a green run. The pattern is now derived from the
  configured tag prefix. No upstream release was actually missed —
  `openmls-v0.8.1` is still the latest — but the next one would have been.
- **The CI Flutter cache never saved anything** — `setup-fvm` cached `~/.fvm`,
  but fvm keeps installed SDKs in `~/fvm/versions`; `~/.fvm` is the per-project
  directory it symlinks inside a checkout, not the global cache. That path
  exists on no runner, and a missing path is not an error to `actions/cache` —
  it warns in the post step and reports success — so every job on all four
  platforms reinstalled the SDK from scratch (`fvm install` measured at 71 s on
  Linux, inside a 163 s setup step on Windows) while the step stayed green and
  the repository held no `fvm-*` cache entry at all. The key now also carries
  `runner.arch`, because Linux x86_64 and Linux ARM64 both report
  `runner.os == 'Linux'` and were producing one byte-identical key: with saving
  repaired but the key unchanged, one leg would have restored the other
  architecture's `bin/cache/dart-sdk`, which Flutter keeps rather than
  redownloads — its revision stamp matches — and then fails to execute.
  `restore-keys` is gone, since a near-miss restored the previous SDK and then
  installed the new one beside it, growing the entry by a full SDK on every
  Flutter bump. Three changes keep it from drifting again. fvm itself is pinned
  (`dart pub global activate fvm 4.1.2` instead of whatever is latest that day),
  since this action hardcodes where fvm stores SDKs and an unannounced major
  that relocated them would break every job at once. `FVM_CACHE_PATH` is set
  explicitly rather than inherited, so the cached path is a contract instead of
  a guess. And a step after `fvm install` asserts the directory is populated —
  a failing job pointing at the action, rather than another silent warning;
  annotate-and-continue is precisely the mode that hid this for months, and
  nothing irreversible sits behind the check, which runs before the release
  archives, the tag and the pub.dev publish. It also prints the SDK size
  (2.5 GB per version uncompressed), because the 10 GB repository cache limit is
  shared with the Rust caches and evicted LRU across all of them.
- **CI was blind to changes in its own workflows and actions** — the path
  filters named `test.yml` and `test-reusable.yml` but not
  `.github/actions/**`, so a PR touching a composite action ran no tests at
  all, and the job additionally skipped every PR opened by a bot. Dependabot's
  grouped action bumps were therefore merged unverified — run `30289222353`
  completed as `skipped` in one second — which is precisely the class of PR
  that changes what CI executes. The filters now carry `.github/**` on both
  push and pull_request, and the skip is narrowed to `update-openmls-*`
  branches, the update PRs that move `native_version` ahead of the released
  binaries. A `pull_request` run resolves reusable workflows and composite
  actions from the merge ref, so the PR's own versions are what execute.
- **A native-update entry lands at the top of `[Unreleased]`, not below
  `### For Contributors`** — `insertChangelogEntry` created its `### For Users`
  block at the point where the `[Unreleased]` section *ends*, so whenever the
  accumulated changes were CI or tooling only — the section then holds
  `### For Contributors` and nothing else, which is its normal shape between
  feature work — the user-facing highlight was filed underneath them, the
  reverse of the order every released section uses. It also emitted a second
  `### For Users` heading when the section already had one that ran to the end
  of `[Unreleased]` with no `#### ✨ Highlights` / `#### Changed` under it. The
  insertion point is now the top of the section, and an existing
  `### For Users` is extended rather than duplicated.
- **The notice inventory no longer depends on the machine that generated it** —
  `cargo tree --target <triple>` filters *normal* dependencies by that triple
  but resolves *build*-dependencies for the **host**, so the inventory recorded
  the build graph of whoever ran the generator. It surfaced in libsignal_dart,
  where `prost-build` → `tempfile` → `rustix` picks `errno` on a macOS host and
  `linux-raw-sys` on a Linux one: one crate swapped for the other, the crate
  count unchanged, and CI rejected a file that was correct on the machine that
  wrote it. This package was not affected between macOS and Linux, but it is the
  same latent bug — a host-independent sweep records crates no macOS or Linux
  run ever saw, among them `winapi`, which reaches the graph through `ansi_term`
  inside a **proc-macro** crate. Proc-macro subtrees are host-compiled just like
  build scripts, so the host dependence is not confined to build edges and no
  per-target query escapes it. The crate set is therefore taken from
  `cargo tree --target all`, the only query cargo offers that applies no
  platform filtering at all; the per-target sweep is kept because it is the one
  thing that fails when a declared release target stops resolving. The result
  over-attributes deliberately: the extra entries are build tooling and
  platform-gated crates a given build never links — `winapi` here arrives only
  through a host-compiled proc-macro — but a file that lists them on every
  machine is worth more than a narrower one that changes with the machine, since
  the byte-exact CI check is only viable if the output is reproducible. The
  inventory grows from 237 to 264 crates. `--check` also prints the
  first differing line and the lines unique to each side now: the failure it
  reports is normally read from a CI log, and "the contents differ" left the
  reader to bisect a 400 KB file by hand
- **`make check-new-openmls-version ARGS="--update"` now moves the
  `openmls_libcrux_crypto` pin** — the tag-rewrite list in the generated checker
  is built from the `upstream_crates` template answer, and that answer named
  `openmls_memory_storage`, a crate this package has never depended on (upstream
  dropped it along with the blob-based storage API), while omitting
  `openmls_libcrux_crypto`, which the experimental X-Wing suite does depend on.
  Its rewrite pattern therefore matched nothing and libcrux kept its old tag: the
  next upstream bump would have pinned four MLS crates to the new tag and one to
  the previous one. That resolves rather than fails — cargo will build two
  revisions of the same git repository side by side — so it would have surfaced
  as an X-Wing-only breakage or a silently doubled dependency tree rather than as
  a build error. Corrected in `.copier-answers.yml` rather than in the generated
  file, so the next `copier update` keeps it.

#### Added

- **CI verifies the declared MSRV** — `rust-version = "1.89"` in
  `rust/Cargo.toml` is a promise to anyone building the native library from
  source, and nothing checked it: the first dependency or language feature to
  raise the real floor would have broken that build silently, with the failure
  landing on a contributor instead of here. A new `msrv` job reads the version
  out of the manifest — rather than repeating it, so the job cannot drift from
  the claim it checks — installs exactly that toolchain and runs `make
  rust-check`. Verified locally against 1.89.0 before the job was added; the
  reusable `setup-rust` action gained a `toolchain` input (default `stable`) to
  make it possible.
- **`make rust-test` and a CI step that runs it** — the crate's unit tests were
  never executed in CI, including `classical_ops_do_not_init_libcrux`, which
  several advisory ignores in `.cargo/audit.toml` and `rust/deny.toml` cite as
  their justification.
- **Third-party notice generator** (`make third-party-notices`,
  `make verify-third-party-notices`) — unions `cargo tree --locked --edges
  normal,build` across all twelve released targets, resolves each crate's SPDX
  expression and licence texts via `cargo metadata`, and pools identical texts
  by reference (the Apache-2.0 text alone appears in over a hundred crates;
  pooling takes the file from 1.9 MB to under 500 KB). `--locked` is what keeps
  the output machine-independent: without it a stale `Cargo.lock` lets cargo
  silently re-resolve the graph, so the same commit could generate different
  inventories. Output is otherwise deterministic — crates sorted, texts sorted,
  no timestamps — so CI can diff it byte-for-byte and fail when a dependency
  change leaves the committed file stale. The check also runs in
  `build-openmls.yml` before the build matrix starts, since a hand-pushed tag
  skips the release script's own gate and the archives it produces embed the
  file.
- **Regression tests for upstream tag validation** —
  `test/scripts/check_updates_test.dart` covers the configured prefix, shell
  metacharacters, newline injection (including a bare trailing newline), path
  traversal and non-canonical version segments.
- **Storage hardening tests** — `test/concurrency_test.dart` drives overlapping
  calls on one engine (they fail against the pre-fix build with a consumed
  ratchet secret and a dropped proposal), `test/security/encrypted_db_test.dart`
  covers encryption at rest, wrong-key fail-closed and the single-writer
  refusal, and `encrypted_db.rs` gained unit tests pinning the raw-key pragma
  shape, the connection pragmas that must be in force, and the `0600` file mode.

#### Changed

- **Minimum supported Rust version is now 1.89** (was 1.88) — `std::fs::File::try_lock`,
  which stabilised there, holds the single-writer lock file. The alternative,
  `libc::flock`, is an `unsafe fn`, and the crate denies unsafe code outside the
  two modules that cannot avoid it. This affects only building from source: the
  published package downloads a prebuilt native library, so nothing changes for
  an app that consumes it.
- **Update workflows detect a crashed checker by what it wrote, not by its exit
  code** — the checkers exit 0 when up to date, 1 when an update is available
  and 2 on failure, but the workflows ran them under `|| true`, making a crashed
  checker indistinguishable from "no updates available". Discriminating on the
  exit code cannot work here, and an earlier revision of this change assumed it
  could: the checkers are invoked through `make`, and GNU make collapses any
  non-zero recipe status into its own exit 2 (verified: a recipe exiting 1 makes
  `make` exit 2), so an `exit_code > 1` guard fires on the ordinary "update
  available" path and would have failed both workflows on exactly the event they
  exist to serve — no update PR and no template notification would ever be
  opened again. It stayed green only because no update came up while it was in
  place. The gate is the artefact instead: the checker writes `needs_update=` to
  its outputs file *before* signalling, and writes nothing at all when it
  throws, so a missing `needs_update=` line means it failed, and the step fails
  with an `::error::` that tells the reader not to interpret it as "up to date".
  Manual `target_version` input is also validated in the workflow shell, before
  it is interpolated into `ARGS`.
- **Test workflow now triggers on `scripts/`, `hook/` and `Makefile` changes** —
  edits to the build hook, tooling scripts and the Makefile previously ran no
  tests at all. Workflow-file paths are now also watched on pull requests, not
  only on pushes. `THIRD_PARTY_NOTICES.txt` and `.gitattributes` are watched
  too: `make verify-third-party-notices` runs in this workflow, so the notices
  file is the artefact being checked and `.gitattributes` decides which bytes a
  checkout materialises for it. Without them the one commit that can break — or
  fix — that check was also the one commit that did not run it, letting a stale
  inventory reach `main` unverified and surface only in the release preflight.
- **GitHub Actions moved to their current majors** — `actions/checkout` v4→v7,
  `actions/upload-artifact` v4→v7, `actions/download-artifact` v4→v8,
  `actions/cache` v4→v6, `actions/create-github-app-token` v2→v3,
  `android-actions/setup-android` v3.2.2→v4.0.1 and
  `schneegans/dynamic-badges-action` v1.7.0→v1.9.0. Mostly the Node 20→24
  runtime migration, which needs no change on GitHub-hosted runners. Two are
  worth knowing about: `download-artifact` v8 now *fails* a run on an artifact
  digest mismatch instead of logging a warning, which is a welcome hardening of
  the job that packages the native archives consumers download; and
  `checkout` v7 refuses to check out a fork PR under `pull_request_target` /
  `workflow_run`, which does not affect this repo because no checkout passes an
  explicit `ref`.
- **Dependabot branches are exempt from the branch rulesets** — `Signing commit`
  applies `non_fast_forward` to `~ALL` branches with no bypass actors, so
  Dependabot, which refreshes an open PR by force-pushing a rewritten commit,
  could never rebase one onto a moved `main`; its first scheduled run gave up
  with "because the branch … is protected it was unable to do so", leaving the
  PR frozen at the day it was opened. `refs/heads/dependabot/**/*` is now
  excluded from that ruleset and from `Delete branches` (which blocked
  `@dependabot recreate` and branch cleanup for the same reason). Nothing is
  weakened: Dependabot signs its commits regardless of the rule, and `main`
  keeps both its pull-request gate and `required_signatures`. The trailing `/*`
  is load-bearing — these are `fnmatch` patterns in pathname mode, so a bare
  `**` stops at the first `/` and would miss the two- and three-segment names
  Dependabot actually generates.
- **copier template adopted: v3.0.3 → v4.0.0** — the major carries a single
  contract change, that every project generate and commit
  `THIRD_PARTY_NOTICES.txt` before its next CI run, and this package already
  satisfies it: the notice tooling was written here and upstreamed into the
  template, so it arrives byte-identical and most of the release lands as a
  no-op. What does change: `validateUpstreamTag` names the input it rejected,
  because an API `tag_name`, a `--version` argument and the pin recorded in
  `rust/Cargo.toml` fail for different reasons and want different fixes;
  `insertChangelogEntry` matches `#### Changed` exactly, where a prefix match
  previously filed the native-library bump under `#### Changed (Breaking)` as
  well, and it creates a missing subsection in the documented order rather than
  at the end of the block; the fuzz workflow reads its targets from the
  `[[bin]]` entries of `rust/fuzz/Cargo.toml` and fans them out one job per
  target, so a crash in one target no longer skips the rest; the build hook
  declares a local native build as a dependency, so `make clean` no longer
  leaves `dart test` pointed at a cached asset that is gone; and the LICENSE
  copyright year is a stored answer (`copyright_year: 2026`) instead of the year
  the file happens to be rendered in, so the notice keeps naming the year of
  first publication.
  Two parts of v4.0.0 are deliberately not adopted. The `freezed_annotation` /
  `freezed` / `build_runner` dependencies exist so that a *freshly generated*
  project's first codegen succeeds against an unknown API surface; this
  package's FRB surface has no data-carrying enums — no generated `sealed class`,
  no `@freezed` — and `freezed_annotation` sits in `dependencies`, so every
  consumer would download a package that nothing here imports. And the
  `frb-patterns` skill's new sections on write durability and non-failable
  `DartFn` callbacks describe the callback-storage architecture this package left
  behind: it has no Dart callbacks at all, storage is Rust-owned in
  `SnapshotStorageProvider` over `EncryptedDb`, so adopting them would document a
  pattern that does not exist here.

## [1.4.2] - 2026-07-21

### For Users

#### ✨ Highlights

- **openmls** — unchanged this release (openmls-v0.8.1)
- **openmls_frb v1.5.2** — Rust FFI bindings

#### Security

- **Hardened MLS message parsing against malformed input** — incoming MLS
  messages (`mlsMessageExtractGroupId` / `mlsMessageExtractEpoch` /
  `mlsMessageContentType`, plus Welcome / GroupInfo / process-message decoding)
  are now decoded via the `Read`-based path and reject trailing bytes
  explicitly, so a malformed message returns an error instead of aborting the
  process. Reported upstream; this local guard will be removed once we depend on
  a fixed openmls release.
- **Triaged new libcrux advisories in the X-Wing PQ dependency tree
  (RUSTSEC-2026-0207/-0208/-0209/-0210/-0211/-0212)** — these advisories were
  published against libcrux crates that reach our tree only transitively via the
  experimental X-Wing ciphersuite (pinned by openmls-v0.8.1, so not fixable via
  `cargo update`). Five are structurally unreachable (the SHA3 ones explicitly
  exclude ML-KEM; the AES-GCM ones are dead code — the only X-Wing suite is
  ChaCha20Poly1305); the sixth (-0212, libcrux-secrets constant-time swap on
  aarch64) is an accepted availability-only risk (CVSS `VC:N/VI:N/VA:H` — a wrong
  ML-KEM result makes an X-Wing operation fail, never a key leak). Per-advisory
  reachability analysis is documented inline in `.cargo/audit.toml` /
  `rust/deny.toml`; all clear on the next upstream OpenMLS bump. Classical
  (non-PQ) ciphersuites are unaffected.

#### Fixed

- **Web build hook now refreshes stale WASM on upgrade** — the web build hook
  records the provisioned crate version in `web/pkg/.wasm-version` and
  re-downloads when it changes, instead of skipping whenever the two WASM files
  merely exist. Previously, upgrading the package kept the prior version's WASM
  in the app's `web/pkg/` (it survives `flutter clean`), so on web any FRB entry
  calling Dart store callbacks could panic with an argument-count mismatch
  (`called Option::unwrap() on a None value`) once the wire signature changed
  between versions. The download cache is now version-keyed (`web/<version>/`),
  WASM files are copied unconditionally (the old mtime guard skipped a
  fresh-but-older source on downgrade), and `rust/Cargo.toml` is a declared
  web-build dependency so a version bump re-runs the hook. Native platforms were
  unaffected.

### For Contributors

#### Changed

- **Adopt copier template v2.5.1 → v2.5.2** — source of the web build hook fix
  above.
- **Adopt copier template v2.5.2 → v3.0.3** — release-process and dev-tooling
  changes only; no change to the published package's runtime behavior.
  - **Two-stage release flow** (v3.0.0) — the native `openmls_frb` crate and the
    Dart package now release independently: `make release-frb` bumps, tags
    (`openmls_frb-X.Y.Z`) and builds the native binary, then `make release`
    verifies that binary exists and publishes the Dart package (`vX.Y.Z`). Adds
    `scripts/release.dart` / `scripts/release_frb.dart` and the
    `release-frb-crate` skill; the flow is documented in CLAUDE.md.
  - **Repository protections** (v3.0.0) — GitHub rulesets (`.github/rulesets/`)
    restricting who may push `main` and create release tags, a signed-commit
    rule, a `setup_repo_protections.dart` helper, and a Dependabot config.
  - **Removed vestigial Windows Flutter-plugin scaffolding** (v3.0.0) —
    `windows/CMakeLists.txt` and the generated plugin registrant; this is a
    pure-Dart FRB package (native libraries load via the build hook), so the
    scaffolding was unused.
  - **Release-tooling fixes** (v3.0.1 → v3.0.3) — the pub.dev dry-run now runs on
    the clean pre-bump tree (a bumped-but-uncommitted tree tripped
    `pub publish --dry-run`'s exit-65-on-warning), and `make release` no longer
    leaves an empty `## [Unreleased]` heading behind.

## [1.4.1] - 2026-07-14

### For Users

#### Highlights

- **Hardened release binary & fail-closed supply chain** — the shipped native
  library is now compiled with `overflow-checks` and `unsafe_code = "deny"`, and
  the download hook refuses to load a binary whose SHA256 checksum cannot be
  verified.
- **openmls** — unchanged this release (openmls-v0.8.1)
- **openmls_frb v1.5.0 → v1.5.1** — Rust FFI bindings (release binary rebuilt
  with `overflow-checks`; no API or behavior change in normal use)

#### Security

- **Hardened release binary** — the wrapper crate is now compiled with
  `overflow-checks` (integer overflow panics instead of wrapping silently) and
  `unsafe_code = "deny"` on all hand-written Rust. The few modules that
  legitimately need `unsafe` (the interior-mutability storage shim and the WASM
  `WasmCryptoKey` `Send + Sync` impl) opt in explicitly; the FRB-generated
  bridge is exempt.
- **Fail-closed download verification** — the native-library build hook now
  **aborts** if the SHA256 checksums cannot be fetched or lack an entry for the
  archive, instead of loading an unverified binary. An
  `OPENMLS_ALLOW_UNVERIFIED_DOWNLOAD=1` escape hatch is provided for older
  releases published without a checksums file.

### For Contributors

#### Added

- **cargo-deny** (`rust/deny.toml`, `make rust-deny`, CI `deny` job) — enforces
  RustSec advisories, an allowed-license list, and a source allow-list.
  Remediated RUSTSEC-2026-0204 (`crossbeam-epoch` 0.9.18 → 0.9.20); six
  unremediable/inapplicable advisories are ignored with inline justifications
  (the three libcrux crypto advisories mirror `.cargo/audit.toml`).
- **cargo-fuzz harness** (`rust/fuzz/`, `Fuzz` workflow, `make fuzz*`) with two
  targets over untrusted wire bytes — `mls_message` (MLS protocol-message
  parsers) and `credential` (`MlsCredential::deserialize`) — plus a seed-corpus
  generator (`make fuzz-seed`).
- **Rust clippy in CI** (`make rust-clippy`, `-D warnings`) and a pinned FRB
  codegen installer (`make setup-frb-codegen`) so CI and local codegen produce
  identical bindings.
- Download-cache tests (`test/hook/build_hook_test.dart`).

#### Changed

- Adopt copier template v2.4.0 → v2.5.1
  - Fixed the download cache key (crate version + full platform variant) so iOS
    device and simulator builds no longer poison each other's cache on
    Apple-silicon hosts
  - Update scripts: `check_updates.dart --update` now bumps the wrapper crate
    version, `update_changelog.dart` classifies update severity and accepts
    `--from`, and the update workflow skips regeneration when an open PR for the
    same version already exists
  - Fixed pre-existing clippy findings (`CryptoError` Copy deref;
    `too_many_arguments` on external-commit APIs)

## [1.4.0] - 2026-06-06

### For Users

#### Highlights

- **openmls_frb v1.4.0 → v1.5.0** — experimental X-Wing post-quantum ciphersuite (hybrid ML-KEM-768 + X25519)

#### Added

- **Experimental post-quantum ciphersuite**: `MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519` —
  hybrid X-Wing KEM (ML-KEM-768 + X25519, draft-connolly-cfrg-xwing-kem-06) for
  harvest-now-decrypt-later protection. HPKE operations for this suite are delegated
  to the formally verified libcrux ML-KEM implementation (`openmls_libcrux_crypto`,
  same upstream `openmls-v0.8.1` pin); all classical ciphersuites continue to run
  unchanged on RustCrypto. The libcrux provider is initialized lazily — classical
  suites never depend on it. See the README "Post-Quantum Support (Experimental)"
  section for important limitations (no IANA codepoint, limited interoperability,
  future migration to the official IETF suite).

#### Security

- `cargo audit` reports three RustSec advisories introduced into the dependency
  tree by `openmls_libcrux_crypto` (RUSTSEC-2026-0124, RUSTSEC-2026-0075,
  RUSTSEC-2026-0073). Analysis: all are DoS-class (panic) or structurally
  unreachable through this library's call paths — signatures always run on
  RustCrypto (0075 path never invoked; libcrux's KEM/HPKE code does not link
  ed25519), HPKE buffers are exact-size library-allocated (0124 trigger
  impossible), and the standalone `mac()` (0073) is never called. Fixes are
  blocked on upstream semver pins; tracked until the next upstream OpenMLS
  release. Each advisory is ignored in `.cargo/audit.toml` with its
  reachability justification inline — remove those entries when bumping the
  upstream pin. The non-libcrux routing these justifications depend on is
  enforced by the `classical_ops_do_not_init_libcrux` Rust test.

#### Documentation

- Document `flutter build web --wasm` (dart2wasm) limitation in README — Rust returns fail with `Type 'JSValue' is not a subtype of type 'List<dynamic>'` under dart2wasm. Upstream limitation in `flutter_rust_bridge` ([#2575](https://github.com/fzyzcjy/flutter_rust_bridge/issues/2575)), affects every FRB-based Dart package. Standard `flutter build web` (dart2js) target continues to work. ([#5](https://github.com/djx-y-z/openmls_dart/issues/5))

## [1.3.0] - 2026-04-01

### For Users

#### Highlights

- **openmls_frb v1.3.0 → v1.4.0** — update flutter_rust_bridge to v2.12.0

#### Changed

- Update `flutter_rust_bridge` from v2.11.1 to v2.12.0 — fixes codegen/runtime version mismatch when consumers resolve FRB 2.12.x ([#4](https://github.com/djx-y-z/openmls_dart/issues/4))

## [1.2.0] - 2026-02-18

### For Users

#### Highlights

- **openmls_frb v1.2.0 → v1.3.0** — database migration system with schema versioning

#### Added

- `MlsEngine.schemaVersion()` — returns the current database schema version (useful for diagnostics and debugging)

### For Contributors

#### Added

- Database migration system with automatic schema versioning and downgrade detection
  - Native (SQLCipher): each migration runs in its own SQL transaction with version written atomically
  - WASM (IndexedDB): two-phase approach — structural changes via IDB versioning, data migrations via encrypted metadata key
  - Downgrade detection: clear error if DB was created by a newer library version
  - Separate version counters: `LATEST_SCHEMA_VERSION` (data format, both platforms) and `IDB_STRUCTURAL_VERSION` (IDB object stores, WASM only)
- `/add-db-migration` Claude skill — step-by-step guide for adding new migrations
- Storage Architecture section in CLAUDE.md — snapshot pattern, scalability, security properties, Wire comparison
- DB migration reminder in openmls update workflow PR checklist

#### Fixed

- Fix WASM build failure caused by `idb` 0.6.5 API changes in `encrypted_db.rs` (`VersionChangeEvent::old_version()` now returns `Result<u32>`, `Uint8Array::into()` requires explicit type)

#### Changed

- Adopt copier template v2.3.1 → v2.4.0
  - Added coverage badge support in README (shields.io endpoint via GitHub Gist)
  - Added Rust dependency caching (`Swatinem/rust-cache@v2`) in CI setup-rust action — dramatically speeds up Windows builds (~10 min OpenSSL compile cached)
  - Added Strawberry Perl configuration for Windows CI to fix OpenSSL build (MSYS2 Perl from Git Bash is incompatible)
  - Added `IPHONEOS_DEPLOYMENT_TARGET` env var for iOS CI builds — fixes linker errors when vendored C code is compiled with newer Xcode
  - Added `make check-targets` command and `scripts/check_deployment_targets.dart` for checking deployment target consistency (iOS/macOS/Android) across all project files
  - Added "Setting up Coverage Badge" and "Setting up pub.dev Publishing" sections to CONTRIBUTING.md
  - Replaced `dart run scripts/` with `dart scripts/` in Makefile commands, removing `.skip_openmls_hook` workaround (scripts only use `dart:` imports, so `dart run` build hooks are unnecessary)
  - Fixed WASM build hook: local builds now take priority over cached/downloaded files, avoiding stale content hash mismatches
  - Removed `flutter:` version constraint from `pubspec.yaml` environment (pure Dart packages don't need it)
  - README: compact horizontal platform table, added "Developing Rust API", "Building Native Libraries", and "CI / Version Management" sections

## [1.1.0] - 2026-02-15

### For Users

#### Highlights

- **openmls_frb v1.0.0 → v1.2.0** — Rust FFI bindings with engine close/reopen support and openmls v0.8.1

#### Added

- `MlsEngine.close()` and `MlsEngine.isClosed()` — allow closing the engine (wiping the encryption key from RAM and closing the DB connection) when the app goes to background or the screen is locked. After close, all operations fail with "MlsEngine is closed". Close is idempotent

#### Changed

- Update openmls native library to v0.8.1 ([release notes](https://github.com/openmls/openmls/releases/tag/openmls-v0.8.1))
  - Relaxed WASM size limit to improve compatibility
  - Exposed `full_leaves` and `parents` in TreeSync for tree traversal
  - Updated libcrux and hpke-rs dependencies

#### Fixed

- README: Correct iOS minimum version from 12.0 to 13.0 and macOS from 10.14 to 10.15 in platform support table

### For Contributors

#### Added

- `make check-targets`: Unified deployment target consistency checker for iOS, macOS, and Android — verifies all project files (podspec, CI workflow, Xcode project, plist, build.gradle, README) match `.copier-answers.yml`. Supports `--update` to fix mismatches and `--set <version>` to change a platform target everywhere in one command

#### Changed

- CI: Add Rust dependency caching (`Swatinem/rust-cache`) to speed up builds, especially Windows where vendored OpenSSL compilation took ~10 minutes

## [1.0.1] - 2026-02-11

### Added

- Coverage badge

## [1.0.0] - 2026-02-11

### Added

- **MLS Protocol (RFC 9420)**: Full group key agreement with forward secrecy and post-compromise security
- **MlsEngine**: Rust-owned encrypted database with 61 API functions (58 async + 3 sync):
  - Group creation, join (Welcome, external commit), leave
  - Member management (add, remove, swap)
  - Encrypted messaging with additional authenticated data (AAD)
  - Proposals (add, remove, self-update with custom leaf node parameters, PSK, custom, group context extensions)
  - Commit handling (pending, flexible, merge/clear)
  - State queries (members, epoch, extensions, configuration, epoch authenticator, ratchet tree, group info, secrets)
  - Key package creation with options (lifetime, last-resort)
  - Storage cleanup (delete group, delete key package, remove pending proposal)
  - Basic and X.509 credential support (optional credential bytes on all creation functions)
  - 3 sync message utilities (extract group ID, epoch, content type)
- **Encrypted storage**: All MLS state encrypted at rest
  - Native: SQLCipher (AES-256 transparent full-database encryption)
  - Web: IndexedDB + AES-256-GCM per-value encryption via Web Crypto API
- **SecureBytes**: Wrapper for sensitive byte data with automatic zeroing on disposal
- **SecureUint8List**: Extension with `zeroize()` method for manual zeroing of `Uint8List`
- Cross-platform support: Android, iOS, macOS, Linux, Windows, Web (WASM)
- Automatic native library download via Dart Build Hooks
- SHA256 checksum verification for supply chain security
- Based on [OpenMLS](https://github.com/openmls/openmls) v0.8.0

### Security

- All cryptographic operations run in Rust (OpenMLS with RustCrypto backend)
- Memory safety via Rust's ownership model
- No `unsafe` code in the wrapper layer
- **Web Crypto API on WASM**: Encryption key imported as non-extractable `CryptoKey` via `crypto.subtle.importKey()` — raw key bytes zeroized from WASM memory immediately after import. Defensive error handling (no `unwrap()`) in encrypt/decrypt paths
- `SerializableSigner` derives `ZeroizeOnDrop` — private key bytes zeroed on drop
- Eliminated clone-then-zeroize pattern in `from_raw()` and `serialize_signer()` — private keys moved, not copied
- `signer_from_bytes()` zeroizes input bytes on all code paths, including deserialization errors
- X.509 `x509()` documents that application layer must validate certificate chains
- SECURITY.md: sensitive API table, known limitations, web deployment recommendations, vulnerability reporting via GitHub Security Advisories

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/djx-y-z/openmls_dart/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.2...v2.0.0
[1.4.2]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/djx-y-z/openmls_dart/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/djx-y-z/openmls_dart/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/djx-y-z/openmls_dart/releases/tag/v1.0.0
