# openmls - Claude Code Configuration

## Important Rules

**ALWAYS use Makefile commands.** Never call scripts or cargo directly. The Makefile is the single entry point for all operations.

```bash
# Correct - pass arguments via ARGS variable
make build ARGS="--target aarch64-apple-darwin"
make codegen
make test
make analyze ARGS="--fatal-infos"

# Wrong - never do this
cargo build --release
flutter_rust_bridge_codegen generate
make build --target aarch64-apple-darwin  # make interprets --target as its own flag!
```

## Available Makefile Commands

### Setup
```bash
make setup                        # Full setup (FVM + Rust tools)
make setup-fvm                    # Install FVM + Flutter only
make setup-rust-tools             # Install Rust tools (cargo-audit, cargo-deny, frb_codegen)
make setup-web                    # Install web build tools (wasm-pack)
make setup-android                # Install Android build tools (cargo-ndk)
```

### Code Generation
```bash
make codegen                      # Generate Dart bindings from Rust code
```

**Note:** `make codegen` automatically creates a `.skip_openmls_hook` marker file to prevent Build Hooks from downloading libraries during codegen. The marker is automatically removed after completion.

### Build
```bash
make build                              # Build for current platform (always release)
make build ARGS="--target <target>"     # Build for specific Rust target
make build-android                      # Build for Android (all ABIs)
make build-android ARGS="--target arm64-v8a"  # Build for specific Android ABI
make verify-android-alignment           # Check the built .so files are 16 KB-aligned
make build-ios                          # Build for iOS (device + both simulators)
make build-ios ARGS="--target aarch64-apple-ios-sim"  # Build for one iOS target
make build-web                          # Build WASM for web (stamps .crate-version)
```

`ARGS` reaches `build-android` **after** the `build` word, and that is
deliberate: cargo-ndk's own options (`--target arm64-v8a`) are recognised
anywhere on the line, cargo's are not, so this position takes both kinds and the
other one takes only cargo-ndk's.

⚠ **The 16 KB alignment of the Android libraries comes from `cargo-ndk`, not
from the NDK.** cargo-ndk passes `-Wl,-z,max-page-size=16384`; artefacts built
with r26 and r28 measure `p_align=0x4000` alike. Google Play has required it of
an app's bundled native libraries, for apps targeting Android 15 or later, since
1 November 2025 — so a cargo-ndk that stopped passing the flag would not break
anything here, it would make **consumers'** apps unpublishable. The version is
therefore pinned by hand in every job that runs it (`build-openmls.yml`,
`test-reusable.yml` and `integration-reusable.yml`, together — a gate on a
different tool than the release is not a gate, and a test of a library built
differently is a test of that one), and `make verify-android-alignment` measures
the result rather than trusting the pin. The first two run it.

⚠ **The Apple libraries are linked with `-headerpad_max_install_names`, by
`rust/build.rs`.** `dart run`, `dart test` and `flutter test` copy the dylib into
the consuming project and rewrite its install name to the copy's absolute path;
without the flag the header has room for a path of about 180 characters, and the
rewrite fails beyond it ("larger updated load commands do not fit"). A build
script and not `rust/.cargo/config.toml`, because `make build` runs cargo from
the repository root, where that file is not read — the trap the wasm32 lint
below works around with `cd rust` — and a `RUSTFLAGS` in the environment would
replace it. `make verify-release-artifacts` refuses a Mach-O library with room
for fewer than 1,024 characters, so a lost flag fails the release rather than a
consumer's build.

⚠ **`make build-web` stamps `rust/target/wasm32/.crate-version`, and the build
hook REFUSES a local WASM build whose stamp is missing or disagrees with
`rust/Cargo.toml`** — `HookException` and a stopped build, not a silent
substitution. The local build still takes priority over the released module; it
just has to prove which crate produced it.

The stamp exists because nothing else can answer that question. `rustContentHash`
cannot: it hashes only the names of the bridged functions, and a patch release
is precisely the case where those names stay the same while the native code
behind them moves. Timestamps cannot either — a checkout or a stash moves them
in both directions with the content unchanged.

⚠ **A `rust/target/wasm32/` built before this stamp existed carries none and is
rejected.** That is the intended answer rather than a regression, and it is what
the first web build after adopting this looks like: run `make build-web`, or
delete the directory to use the released module instead.

⚠ **`make build` stamps the host library the same way, in
`rust/target/release/.crate-version`, and the hook refuses a local library
whose stamp is missing or disagrees** — the same `HookException`, for the same
reason: a library left over from an earlier crate loads silently, and once the
way values cross the bridge has moved, its calls fail in ways nothing names. A
library built before the stamp existed, or by a bare `cargo build`, is refused:
run `make build`, or delete `rust/target/release/` to use the released library.
So after `make release-frb` bumps the crate, `make test` needs a `make build`
first.

⚠ **A cross build is read too, under the same rules:** a target other than the
host reads `rust/target/<triple>/release/`, and `make build-android`,
`make build-ios` and `make build ARGS="--target <triple>"` stamp that directory.
It is what lets a pull request run its own Rust on an emulator or a simulator:
without it those targets could only load the last release, so a test there would
pass over code the pull request had replaced. The flip side is the same refusal:
a cross build from a `cargo` line, or one left over from before the stamp, stops
the app's build until you rebuild it or delete it. The host's own triple is the
exception: the host reads `rust/target/release/` alone, so a `--target` build for
it is stamped and never read — build the host with a plain `make build`. A consumer
never reaches any of this, `rust/target/` not being in the published package.

⚠ **Each stamp comes with `.cargo-lock`, a copy of the `rust/Cargo.lock` the
build was made from, and the hook refuses a local build whose copy differs from
the lock file in the tree.** An upstream update moves the dependencies while the
crate version stays put — the crate moves at release time — so a build made
before the update used to pass the version check and run the previous upstream
code. After any change to the lock file, build again; a build from before the
copy existed is refused the same way. `make build` also drops the hook's cached
result for this package, `.dart_tool/hooks_runner/openmls/`: when the
hook last ran without a host build here, it downloaded the released library and
declared only `rust/Cargo.toml`, so `dart test` kept loading that download after
the build. It drops the example's too, and Flutter's stamps above it — the hook's
target, `dart_build` to Flutter 3.44 and `build_hooks` with `link_hooks` from
3.47, and `install_code_assets`, which on 3.38 can put the last device build's
library into a simulator app.

### Web

```bash
make test-web                     # Browser suite: headless Chrome, real DOM APIs
make test-web CHROMEDRIVER=/path/to/chromedriver   # pin the driver (see below)
make test-web ARGS="--release"    # release profile, when the suite gets slow
make test-web ARGS="-- --nocapture"                # show console::log output
```

`make test-web` is the **only** check here that EXECUTES web code. `make test`
is the Dart VM and `make build-web` only compiles, so without it every
`cfg(target_arch = "wasm32")` branch in the crate is covered by nothing — and
those branches are exactly the ones nothing else can reach, because a wasm32
body is a *different implementation* of the same function rather than the same
code on another host.

⚠ **Pin chromedriver.** wasm-pack looks for one on `$PATH`, honours
`--chromedriver`, and otherwise DOWNLOADS THE LATEST — an unpinned network
fetch on every run. The `CHROMEDRIVER` **environment variable is not honoured**
— wasm-pack overwrites it with its own — hence the make variable, which becomes
the flag. CI resolves the runner image's preinstalled driver and fails closed if
there is none.

⚠ **That pins the DRIVER and not the BROWSER, and a green run is no evidence
otherwise.** With no `webdriver.json` and no `WASM_BINDGEN_TEST_WEBDRIVER_JSON`,
the test runner sends empty capabilities and ChromeDriver launches whatever
Chrome is installed. To pin it, point that variable at a file carrying
`{"goog:chromeOptions": {"binary": "<browser path>"}}`; the run then prints `Ok`
instead of `Not found` under "Try find webdriver.json". `Ok` alone only proves
the file was READ — check that a deliberately bad path fails, or the pin may be
parsed and dropped.

⚠ **A mismatched driver does not necessarily fail loudly**, so "it went green"
does not mean the driver matched the browser.

⚠ **`WASM_BINDGEN_TEST_TIMEOUT` is raised to 120 s in the Makefile.** The
browser runs every test on one JS thread, so a test that blocks it starves the
callbacks every concurrently-driven test is waiting on. The failure that
produces names whichever test was scheduled LAST rather than the slow one, so it
reads as a hang somewhere unrelated.

```bash
make run-example-web              # build-web, then run example/ in Chrome
make run-example-web ARGS="--web-port=5599"        # flags reach flutter run
```

⚠ **`make run-example-web` deletes `example/build/*/dart_build.stamp`, and that
step is load-bearing.** `flutter run` keys its build directory on the engine
revision, the entrypoint, the build mode and the output path — the target
platform is **not** in that key — so a debug run for macOS and a debug run for
Chrome share one `dart_build` stamp. Whichever ran first makes the other skip
the build hook outright (`Skipping target: dart_build`, visible under
`--verbose`), and `example/web/pkg/` is then never provisioned: `init()`
throws a `StateError` naming the missing `pkg/openmls_frb.js`. It checks
for the module first because flutter_rust_bridge's loader waits for the
`load` event of that script with no error path or timeout, so a missing
module (a 404, or the app's HTML page the dev server serves in its place
with a 200) would leave the call pending. The hook cannot
declare its way out of it — the skip happens above `hooks_runner`, where
nothing it declares is read. This is Flutter 3.38 to 3.41 only: from 3.44
`flutter run` runs build hooks per target platform, outside that stamp.
Consumers of the published package on those versions hit the same thing; the
README's *Known Limitations* names the escapes.

### The example app (the package in a real Flutter app)

```bash
make test-example ARGS="-d macos"            # Integration tests on a device
make test-example-web                        # ...in a real browser (debug, DDC)
make test-example-web ARGS="--release"       # ...what a consumer ships (dart2js)
make drive-example ARGS="--profile -d macos" # ...in AOT, under flutter drive
make test-example-ci ARGS="--attempts 3 -- -d <device>"  # As CI runs them: see below
make coverage-example ARGS="-d macos"        # ...then fail on a bridged function none calls
make verify-example-coverage                 # That check alone, over the last run
make verify-example-library ARGS="--built"   # Check the run loaded the library it meant to
make create-consumer VERSION=9.0.0           # A new app that uses the package from pub.dev
make test-example EXAMPLE_DIR=build/consumer ARGS="-d macos"  # ...and any target on it
make package-example-android                 # Release APK: all ABIs bundled, ELF 16 KB aligned
make package-example-ios                     # iPhone and simulators: each library in its app
make package-example-macos                   # Universal app: both architectures in it
```

`make test` runs the library on the Dart VM. This runs it inside an app, so it goes
through what a consumer's build goes through: the build hook, the platform's way of
bundling a native library, the loader, the wasm module with the Dart half compiled
for the web, and the library actually executing on that platform's architecture.
The tests are `example/integration_test/`, one entry point (each test file is its
own build, install and launch on a device) with the families under `capabilities/`.

**The tests are this project's; the harness is the template's.** The entry point
`example/integration_test/openmls_test.dart`, `capabilities/` and the
coverage policy `scripts/src/example_coverage_policy.dart` were written once, as a
start, and no template update touches them again. `support/harness.dart` and
`test_driver/integration_test.dart` stay under the template's management: they
are the app's half of what `make test-example-ci` judges a run by, and change with
the host's half.

**Which library it loads is the hook's choice, so build first:** `make build` for
the host, `make build-android` / `make build-ios` for a device, `make build-web` for
the browser. With none of those it downloads the release of the crate version in
`rust/Cargo.toml`, which is how CI tests a release.

⚠ **A new bridged function needs a test here, or `make coverage-example` fails.**
That is what keeps "every capability of the library" true as the library grows: it
is measured, from the coverage of the running app, over every `crateApi*` function
in `lib/src/rust/frb_generated.dart`. The ones not called on purpose are listed
with a reason in `scripts/src/example_coverage_policy.dart`, which also holds the
hand-written lines to a floor, because a new class over already-covered bridged
functions moves nothing else it can see.

⚠ **Declare a test with `capability(...)`, not `test(...)`, and do not initialize in
`setUpAll`.** Under `flutter drive`, the only way to run this on the web, the host
reads `testWidgets` outcomes only: a plain `test` can fail with the run green, and a
`setUpAll` that throws leaves no tests and no failure, which reads as success.
`capability` runs the package's initialization first, inside its own limit: the
entry point hands it over through `declareCapabilities`, which also declares the
watchdog's self-test first and, last, the test that hands the count of what ran
to `test_driver/integration_test.dart`, whose absence fails the run.

⚠ **`pump` and `pumpAndSettle` can hang the app test forever.** A live test draws
only when pumped, `pump` waits for a frame, and an app told it is hidden draws none:
a desktop window covered by another one is enough. Wait with `scheduleForcedFrame`
in a loop with a deadline instead, under
`LiveTestWidgetsFlutterBindingFramePolicy.fullyLive`.

⚠ **Opaque arguments can be taken by value.** A bridged function that takes an
opaque type by value, not by reference, disposes the Dart object it is given, and
the next use throws `DroppableDisposedException`. Pass a clone or use it last.

**CI:** `integration.yml` runs `integration-reusable.yml` on pull requests and
pushes to main that change what it reads (from the tree; the paths are in
`integration.yml`), after the native build of a release tag (on the
released binaries), and weekly (from pub.dev, on the newest Flutter, with the
tests of that version's tag; a version whose tag has none is not run).
`make release` will not tag before
the run on the released binaries has passed, and `publish.yml` runs it as a gate
before its upload and twice more after it. What no hosted runner can execute —
Android on ARM, an iOS device, x86_64 on anything Apple — is only checked to
bundle. None of these are required checks: add them once they have proved stable
(`.github/rulesets/README.md`).

⚠ **The emulator and simulator steps are the flaky part, never the package, so CI
judges each run on what the app reported** (`make test-example-ci`, in
`scripts/src/example_run.dart`). Measured on the branch that added them, in a
project generated from this template: an iOS simulator's first boot can leave the
app unconnected (4 runs in 18), and the API 36 image with 16 KB pages failed 4 runs
in 14, four different ways. A test that failed
fails the job at once and is never run again, and so does an app that crashed, read
from Android's crash log or from the report macOS writes for a simulator's app: a
test that fails now and then turns the run red instead of passing on a retry.
macOS can write that report after its run was judged, so the reports are read once
more after the last run, back to the first one's start; one written after the step
has ended is still missed. Only
a run that never got that far runs again — the app never connected or never
started the tests, the device or the connection went away — three times in all,
the third on a rebooted simulator, or each on a new emulator; each leaves a
warning on the run. `flutter test --file-reporter json:` is what tells them apart:
a test that failed in the app has an error event of its own, one the app never
finished has none. The script reads that file while the run goes and writes the
failure down at once, because CI stops a try at its time limit without asking it:
read only at the end, a try stopped after a test had failed would count as one
that never finished, and run again. Under `flutter drive` the driver prints a line
when the app answers, so keep `writeResponseOnFailure` in
`test_driver/integration_test.dart`. The 3-minute limit inside each capability is
a test's failure too: a slow emulator can turn one red, and that is the side to
err on.

⚠ **A run that has not started a test 5 minutes after the app was built did not
finish, and is ended there** (`launchLimit`, from the line flutter prints, `Xcode
build done.` or `✓ Built build/…`; `startLimit`, 20 minutes from the run's start,
when that line never comes). Measured over 204 runs in CI: the first test came 3
to 13 seconds after that line on an emulator and 10 to 95 on a simulator, and the
17 runs that never got there stood still after it — iOS apps that never
connected until flutter gave up 12 minutes on, installs that hung until the
step's limit, once for 54 minutes. A first run on a fresh simulator takes up to 9
minutes to its first test, nearly all of it the build, which is why the limit
counts from the build's end.

⚠ **A hang in the app fails the run after 8 minutes, and the watchdog behind it is
the host's, not the app's.** Both of a test's own limits, the 3 minutes and the
6-minute backstop, are timers of the app's isolate, and a call that blocks the
isolate keeps either from firing; so does the driver's 20 minutes under `flutter
drive`, which the app enforces too (the host only prints a warning). So `make
test-example-ci` reads the run as it goes — the JSON under `flutter test`, the
line the app prints as each test starts under `flutter drive` — and a run that has
not moved for `stallLimit`, 8 minutes, once its tests have started, has stopped.
It asks the device: the app still running on a device that answers is `failed`,
written down before anything else and never run again; with the app or the
device gone, the run did not finish. Then the app's threads go to the log —
`sample` for a simulator, `debuggerd -b` through `su` on an emulator, since
neither image CI uses gives `debuggerd` to the shell — and it ends the app, and
flutter with it. Without this, an Android hang was retried as an emulator's
fault, and one that came now and then ended green. A connection to the app that
died without a word, the device and the app still up, would read as a hang too:
none was seen in 226 tries, and the threads in the log tell the two apart (a
heartbeat from the app is the next step if one ever is). ⚠ Once the app is
stopped, `flutter test`'s own reporter ticks ✅ every test left, the ones that
never ran included, then says "No tests were found" (exit 79): read the
annotation, which is the verdict. To see it work, `gh workflow run
integration.yml --ref <branch> -f hang=true` adds a test that blocks the app: the
Android and iOS jobs are to fail on it, saying the app sent nothing for 8 minutes
(API 24 under `flutter drive`, the others under `flutter test`). The run is titled
`Watchdog self-test: …`, which `make release` never counts. Run it again after a
Flutter update.

⚠ **For Android, check the runner image before anything else.** GitHub has served
two ubuntu-26.04 images at once, measured in a project generated from this
template: `20261025.179` (145 GB disk, `/tmp` on it) and `20261018.50` (72 GB,
`/tmp` in a 7.7 GB tmpfs). Both Android jobs that landed on the older one failed.
API 36 failed with "No space left on device" while unpacking its system image,
which went through that `/tmp`. API 24 failed with an install that hung in both
tries. That job had 14 GB free on the disk and an empty `/tmp`, so it was not
short of space, and no cause was found. On the newer images, one Android job in 32
failed: API 36, with the emulator gone offline. The job prints its image first,
and temporary files go to the disk. A cause bound to the runner fails every try on
it, so re-run the job instead.


### Rust Quality
```bash
make rust-check                   # Check Rust code compiles
make rust-clippy                  # Lint Rust code with clippy (warnings = errors)
make rust-clippy-web              # The same lint over the wasm32 half (GATE)
make rust-doc                     # Rustdoc GATE: intra-doc links, -D warnings
make rust-geiger                  # Unsafe-expression census (DIAGNOSTIC, not gated)
make rust-audit                   # Audit Rust dependencies for vulnerabilities
make rust-deny                    # Check advisories/licenses/sources (cargo-deny)
```

### Fuzzing
```bash
make setup-fuzz                   # One-time: install nightly + cargo-fuzz
make fuzz-list                    # List available fuzz targets
make fuzz-seed                    # Generate seed corpus (extend rust/fuzz/examples/gen_corpus.rs)
make fuzz ARGS="mls_message -- -max_total_time=60"  # Run a fuzz target
```

### Dart Quality
```bash
make test                                # Run all tests
make test ARGS="test/example_test.dart"  # Run specific test file
make coverage                            # Run tests with coverage report
make analyze                             # Run static analysis
make analyze ARGS="--fatal-infos"        # Strict analysis
make format                              # Format Dart code
make format-check                        # Check formatting without changes
make doc                                 # Generate documentation (FAILS on unresolved doc refs)
```

**`make doc` is a gate, not just a generator.** `dartdoc_options.yaml` promotes
`unresolved-doc-reference` to an error, so the target exits non-zero when a
docstring references a symbol dartdoc cannot resolve, and CI runs it. This
matters because `lib/src/rust/` is generated from the Rust docstrings in
`rust/src/api/`: a Rust intra-doc reference (``[`Type::method`]``) is copied
verbatim and reaches pub.dev as a dead link. Write references to the Dart
surface in **plain backticks with the Dart camelCase name**.

⚠ The gate cannot see a *wrong* name: plain backticks resolve nothing, so they
never warn. It proves every `[...]` reference points at a real symbol, not that
the prose names the right one.

`make rust-doc` is the counterpart for the Rust side — the intra-doc links in
the parts of `rust/src/` that stay in Rust, which `make doc` cannot see. It is
also a gate (`RUSTDOCFLAGS=-D warnings`), and CI runs it.

**`make rust-clippy` is host-only, and `make rust-clippy-web` is the other
half.** Not a thoroughness setting: a `cfg(target_arch = "wasm32")` body is a
different implementation of the same function, so the host pass reads none of
its lines while reporting green over the file that contains them. CI runs both.

⚠ The wasm32 leg uses `cd rust`, not `--manifest-path`. Cargo finds
`.cargo/config.toml` relative to the CWD, so invoking it from the repository
root drops the wasm32 rustflags and lints a configuration the crate never
builds under — measured as a different compile, not merely different paths in
the output.


`dartdoc_options.yaml` is `.pubignore`d on purpose — pub.dev runs dartdoc itself
and would honour the same promotion, which could break documentation generation
for an already-published version.

### Utilities
```bash
make get                          # Get dependencies
make clean                        # Clean build artifacts (including rust/target)
make version                      # Show current crate version
make rust-update                  # Update Cargo.lock + regenerate notices
make third-party-notices          # Regenerate THIRD_PARTY_NOTICES.txt
make verify-third-party-notices   # Check it matches the dependency graph
make verify-frb-pins              # Check every file names the same FRB version
make verify-pub-limits            # Check no file is over what pub.dev accepts at upload
make verify-feature-graph         # Check no forbidden cargo feature is enabled (GATE)
make verify-android-alignment     # Check built Android libraries are 16 KB-aligned
make verify-release-artifacts ARGS=<dir>  # Check release archives hold what their names say
make actionlint                   # Lint the GitHub Actions workflows
make check-new-openmls-version  # Check for new upstream openmls version
make check-upstream-advisories    # Check openmls/openmls's published advisories against Cargo.lock
make check-new-openmls-version ARGS="--update"  # Apply update
make check-template-updates       # Check for copier template updates
make update-template ARGS="--version vX.Y.Z"  # Apply a template update (runs copier)
make update-template ARGS="--version vX.Y.Z --data key=value"  # ...answering a question it adds
make check-targets                # Check deployment targets (iOS/macOS/Android)
make check-targets ARGS="--ios --set 14.0"  # Set iOS target everywhere
make check-msrv                   # Check the minimum Rust version against the graph
make check-msrv ARGS="--update"   # Raise it everywhere it is stated
make update-evidence ARGS="--out /tmp/evidence"  # What an upstream update changed
make update-changelog ARGS="--version X.Y.Z"  # Update CHANGELOG with AI
make help                         # Show all available commands
```

## Project Overview

Dart Flutter Rust Bridge wrapper for openmls.

### Key Features
- Flutter Rust Bridge integration for type-safe FFI
- Pre-built native libraries for all platforms
- Automated builds via GitHub Actions
- Web/WASM support

### Upstream Repository
- **openmls**: https://github.com/openmls/openmls

## Project Structure

```
openmls/
├── lib/                            # Dart library code
│   └── src/rust/                   # FRB-generated Dart bindings
├── rust/                           # Rust crate
│   ├── Cargo.toml                  # Rust dependencies + version
│   └── src/
│       ├── lib.rs                  # Crate entry point
│       ├── frb_generated.rs        # FRB-generated Rust code
│       └── api/                    # Your Rust API modules
├── scripts/                        # Utility scripts (use via Makefile!)
├── hook/                           # Dart Build Hook for library download
├── test/                           # Tests
├── Makefile                        # Entry point for all commands
├── pubspec.yaml                    # Package config
├── flutter_rust_bridge.yaml        # FRB configuration
└── .github/workflows/              # CI/CD workflows
```

## Development Workflow

### 1. Implement Rust API

Add your Rust functions in `rust/src/api/`:

```rust
// rust/src/api/greeting.rs
pub fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}
```

Register the module in `rust/src/api/mod.rs`:

```rust
pub mod greeting;
```

### 2. Generate Dart Bindings

```bash
make codegen
```

This generates Dart code in `lib/src/rust/`.

### 3. Build Native Library

```bash
# For current platform
make build

# For specific target
make build ARGS="--target aarch64-apple-darwin"
```

### 4. Run Tests

```bash
make test
```

### 5. Check it in a real app

```bash
make test-example ARGS="-d macos"   # needs `make build` first
```

A new function in `rust/src/api/` also needs a test in
`example/integration_test/capabilities/`; `make coverage-example` fails without it.

## Release Flow (two stages)

Releasing is **two independent stages**, each with its own command and tag. The
`openmls_frb` native crate (`rust/Cargo.toml` version) and the `openmls`
Dart package (`pubspec.yaml` version) are versioned and released separately.

- **Automated openmls update PRs do NOT bump the `openmls_frb`
  crate version and do NOT build binaries** — they only update the dependency +
  CHANGELOG. Updates accumulate on `main` (CI builds from source and tests them).
- **The native build is triggered by pushing a `openmls_frb-<version>` tag**
  (created by `make release-frb`), not by pushing to `main`. The tag must equal the
  `rust/Cargo.toml` crate version (the workflow validates this).
- **Stage 1 must finish before stage 2** — the published Dart package's build hook
  downloads the precompiled `openmls_frb-<crate>` binary, so it must already
  exist before you tag the pub.dev release.

### Stage 1 — release the native crate

```bash
# From a clean, up-to-date main. You enter your signing passphrase during the
# command (commit + tag are signed; the terminal is inherited).
make release-frb ARGS="--version X.Y.Z"            # bump + commit + tag + push
make release-frb ARGS="--version X.Y.Z --no-push"  # local only
```

Bumps `rust/Cargo.toml`, stamps the CHANGELOG highlight, signs a commit + tag
`openmls_frb-X.Y.Z`, and pushes — which triggers the native build workflow.
Choose `X.Y.Z` by SemVer of the FFI surface (a non-empty `lib/src/rust/` codegen
diff since the last frb release means the wire signature moved).

### Stage 2 — release the Dart package

```bash
# After the stage-1 native build has finished. Same interactive signing flow.
make release ARGS="--version X.Y.Z"   # verify frb binary + bump + finalize
                                      # CHANGELOG + dry-run + signed commit/tag/push
```

Verifies the stage-1 `openmls_frb-<crate>` release exists and that the
integration tests passed on it (below), runs
`make publish-dry-run` (on the clean, pre-bump tree), bumps `pubspec.yaml`,
finalizes the CHANGELOG (`[Unreleased]` → `[X.Y.Z]` + compare links; no empty
`[Unreleased]` is left behind), measures the result against pub.dev's upload
limits (`make verify-pub-limits` — the dry-run does not check them, and pub.dev
refuses the upload only after the tag), then signs a commit + tag `vX.Y.Z` and
pushes — `publish.yml` publishes to pub.dev.

`make release` refuses until the integration tests have passed on the stage-1
binary. It accepts two kinds of run:

- **The run `integration.yml` starts after the native build.** It is found by its
  title, `Released binaries of openmls_frb-<crate>`, because GitHub records
  `main`'s head as the commit of a `workflow_run`, not the tag's. Its `resolve`
  job tests only when a tag of that name is at the commit the build ran on. The
  build runs by hand on any ref and checks the crate version only for a tag, so a
  branch named like one gets the title and no test job, which counts as no run.
- **A run started by hand on the released binaries at `HEAD`**
  (`gh workflow run integration.yml -f library=release`). This is the way through
  for a crate built before the workflow existed.

A newer run decides over an older one, and a run still going makes it wait. A run
that tested nothing does not count. `--skip-integration-check` skips this check
(`scripts/src/release_integration.dart`).

**Between the stages, `Integration Tests` runs on the released binary, and
`make release` waits for it.** `integration.yml` starts by itself when the native
build of a `openmls_frb-*` tag succeeds. It runs the package in a real app on
every platform, through the hook's download path, checksums included.
`publish.yml` runs the same tests again before it uploads, but only after the tag,
and a failure there leaves a tag pushed with no version on pub.dev. The two can
still disagree, because commits after stage 1 can change the Dart side and the
tests, and only `publish.yml` runs those against the binary. After the upload it
makes a new app that depends on what went up, on the pinned Flutter and on the
newest, so a problem a consumer would hit shows up as that run going red. That
last part cannot stop the release; retracting is a decision.

Repository rulesets restrict who can create the `openmls_frb-*` / `v*` release
tags, and a required-reviewer `native-build` environment gates the native publish.
See `.github/rulesets/README.md`.

## Native Library Version

Two different versions live here and neither is in `pubspec.yaml`:

- **The upstream openmls version** is the crates.io version
  `rust/Cargo.toml` pins `openmls` to — exactly, `"=0.9.2"`, on both
  declarations of it (the second is the `wasm32` target table). The other four
  openmls crates are at the requirement that release itself declares,
  recorded in `upstream_crate_versions` in `.copier-answers.yml`. That is what
  `make check-new-openmls-version` reads and updates, and it finds
  new releases on crates.io — not through GitHub Releases or tags, which an
  upstream may name or publish however it likes.
- **The native crate version** is `[package] version` in `rust/Cargo.toml`.
  `hook/build.dart` parses it (`_readVersion`) and downloads
  `openmls_frb-<version>` from GitHub Releases, so the archive's copy of
  `rust/Cargo.toml` is what decides which binary a consumer gets. It is also
  why stage 1 has to finish before stage 2.

To check/update the version:
```bash
make check-new-openmls-version              # Check for updates
make check-new-openmls-version ARGS="--update"  # Apply update
make rust-update                    # Update Cargo.lock after version bump
make update-changelog ARGS="--version 1.0.0"  # Generate AI changelog entry
```

### AI-Powered Changelog

`make update-changelog` (and the CHANGELOG entry `make update-template` writes)
hand the release notes to an AI model. **Which** model is configuration, not
code: `AI_MODELS` holds an ordered, comma-separated list of `provider/model`
entries and the first one that has a key and answers wins.

**There is no default list.** With `AI_MODELS` unset nothing is called and the
entry is simply not written — a model that writes into this repository's
CHANGELOG is one somebody named, not one the template picked. Keys without a
list is a misconfiguration rather than an opt-out, so that case warns loudly
instead of going quiet.

```bash
AI_MODELS=anthropic/claude-opus-5 ANTHROPIC_API_KEY=xxx \
  make update-changelog ARGS="--version 1.0.0"

# Pick a different model, or a different order, without touching the code
AI_MODELS=google/gemini-3.5-flash-lite ANTHROPIC_API_KEY=… GEMINI_API_KEY=… \
  make update-changelog ARGS="--version 1.0.0"
```

| Variable | Purpose |
|----------|---------|
| `AI_MODELS` | Ordered `provider/model` list, highest priority first. **Required** — there is no default; unset means no model is called. |
| `ANTHROPIC_API_KEY` | Key for `anthropic/…` entries ([console](https://console.anthropic.com/settings/keys)). |
| `GEMINI_API_KEY` | Key for `google/…` entries ([AI Studio](https://aistudio.google.com/apikey)). |
| `OPENROUTER_API_KEY` | Key for `openrouter/…` entries ([keys](https://openrouter.ai/keys)). |
| `AI_EFFORT` | How hard the model is asked to think: `low`, `medium` (default), `high`, `xhigh`, `max`. Ignored by providers that have no such knob. |

An entry whose key is unset is skipped silently — that is how the list says
"use this if it is available". A malformed entry or an unknown provider is
warned about loudly, because it is a typo, not a choice.

Keys are read from the environment and go out in one request header each
(`x-api-key`, `x-goog-api-key`, `Authorization`). They are never put in a URL,
in process arguments, or in the prompt, and nothing logs them — the priority
line prints model ids and variable *names* only. Provider error bodies are
quoted into logs and pull-request output, so the key is stripped from those
before they are reported.

`openrouter` is an aggregator, so its model half is itself a `vendor/model`
pair — an entry reads `openrouter/anthropic/claude-opus-5`. It buys one key for
many models (swapping model costs neither code nor a new secret), at the price
of a third party on the path and a weaker schema guarantee: structured-output
support is per model **and** per backing provider, and `strict` is enforced
exactly by some and treated as guidance by others. A model that cannot do
structured outputs is rejected outright rather than silently downgraded.

The next entry is tried only when a model produced **no** answer: a network
failure, an auth/rate-limit/server status, a refusal, or a response cut off at
the token limit. Never on the *content* of an answer — switching providers
because an entry read poorly would make the CHANGELOG silently inconsistent.

In CI these are step-scoped: `AI_MODELS` as a repository/organization
**variable**, the keys as **secrets**. The pull request body names the model
that wrote the entry.

If no model answers, nothing is guessed: the entry is left unwritten, the run
says why, and the pull request is labelled `changelog-needed`.

The same run decides whether the update could be merged unread — `mergeEligibilityFrom`
in `scripts/src/update_changelog.dart` — and the pull request says so under
*Merge without review?*. It is a report: nothing merges on it yet. The rule is
strict on purpose: in the crates this package builds only quoted version
strings may move, so a protocol constant never passes.

### What the entry is judged against

`.github/agent-prompts/changelog-scope.md` holds this project's own statement of
what it binds and exposes, and the prompt classifies every upstream change
against it: anything that cannot be tied to something named there is invisible
to this package's users and must not be presented as a feature of it. The
template writes that file once and never overwrites it, so keeping it current is
this project's job — a stale list is how somebody else's release notes end up
described as our features.

## Supported Platforms

| Platform | Rust Target | Library |
|----------|------------|---------|
| Linux x86_64 | x86_64-unknown-linux-gnu | libopenmls_frb.so |
| Linux arm64 | aarch64-unknown-linux-gnu | libopenmls_frb.so |
| macOS arm64 | aarch64-apple-darwin | libopenmls_frb.dylib |
| macOS x86_64 | x86_64-apple-darwin | libopenmls_frb.dylib |
| Windows x86_64 | x86_64-pc-windows-msvc | openmls_frb.dll |
| iOS device | aarch64-apple-ios | libopenmls_frb.dylib |
| iOS simulator arm64 | aarch64-apple-ios-sim | libopenmls_frb.dylib |
| iOS simulator x86_64 | x86_64-apple-ios | libopenmls_frb.dylib |
| Android arm64 | aarch64-linux-android | libopenmls_frb.so |
| Android arm32 | armv7-linux-androideabi | libopenmls_frb.so |
| Android x86_64 | x86_64-linux-android | libopenmls_frb.so |
| Web (WASM) | wasm32-unknown-unknown | openmls_frb.wasm |


## Security Considerations

> **Important:** See [SECURITY.md](SECURITY.md) for full security policy and best practices.

### Supply Chain Security
- All native libraries are built from source in GitHub Actions
- SHA256 checksums verify downloaded libraries
- Pin to specific upstream releases
- Tools that shape or inspect the shipped binary are pinned by version, and by
  checksum where CI downloads them (`cargo-ndk`, `wasm-pack`, `actionlint`). None of
  these pins is moved by Dependabot — it does not read `cargo install` or
  `curl` lines, nor a make variable — so they move by hand. wasm-pack's is
  `WASM_PACK_VERSION` in the `Makefile`, the one place it is named: every job
  that builds for the web installs it through `make setup-web`, built from its
  own lock file
- Runner images are named by version too: every Ubuntu job runs on
  `ubuntu-26.04` (`ubuntu-26.04-arm` for arm64), every macOS job on
  `macos-26` and every Windows job on `windows-2025-vs2026`, never on a
  `-latest` label, which GitHub moves to a new image without a commit. The
  next image is a change of its own, to every job on that system at once, and
  for Linux the release build is the one to measure first: its image sets the
  oldest glibc a consumer needs
  (`build-openmls.yml`)
- openmls/openmls's own security advisories are read daily
  (`make check-upstream-advisories`, a job of `check-openmls-updates.yml`)
  and held against the crates `rust/Cargo.lock` resolves. `make rust-audit`
  reads RustSec and Dependabot reads GitHub's global database, and an advisory
  an upstream publishes only in its own repository reaches neither until
  someone files it there. A covered version, a range the check cannot read and
  a fetch that failed all turn the run red; drafts are never asked for

### Code Review Checklist
1. No hardcoded keys or secrets
2. Memory properly freed after use
3. Sensitive data zeroed before freeing
4. No timing side-channels

## Storage Architecture

This project uses a **snapshot pattern** for MLS storage (vs Wire's 18+ entity tables with direct SQL per method).

### How it works

```
1. load_for_group(gid)  → DB query → Vec<(key, value)> → HashMap (initial + current clone)
2. OpenMLS operates      → reads/writes on `current` HashMap
3. commit(provider)      → diff(initial, current) → upserts + deletes → DB write
4. Drop                  → zeroize() all values in both HashMaps → memory freed
```

**No data is held in memory between API calls.** Only the `EncryptedDb` handle persists.

### Key files

| File | Purpose |
|------|---------|
| `rust/src/snapshot_storage.rs` | SnapshotStorageProvider (HashMap-based StorageProvider impl) |
| `rust/src/encrypted_db.rs` | EncryptedDb (SQLCipher native, IDB+AES-GCM WASM) |
| `rust/src/api/engine.rs` | MlsEngine (load → operate → commit cycle) |
| `rust/src/hybrid_crypto.rs` | HybridCrypto (RustCrypto for classical suites; X-Wing PQ KEM → libcrux, lazy init) |

### Native vs WASM loading

- **Native (SQLCipher)**: Loads only target group's data + global data (key packages, signature keypairs). Other groups' data is NOT loaded.
- **WASM (IndexedDB)**: Loads ALL entries (IDB has no WHERE clause). Same user/key trust boundary — no security impact.

### Scalability

The ratchet tree is the only entry scaling with members (~500 bytes per member). A 10,000-member group = ~10 MB peak memory during a single operation. MLS protocol itself (O(N) commit processing) is the bottleneck, not our storage pattern. For groups >50K members, MLS RFC recommends fan-out (subgroups).

### Security properties

- Plaintext in memory only during single-digit milliseconds per operation
- Both HashMaps zeroized on Drop (`snapshot_storage.rs`)
- Security profile identical to Wire's direct-DB approach (both must hold plaintext while OpenMLS operates)

### Why snapshot over Wire's multi-table approach

1. **Only MLS** — no need for separate protocol tables (Wire also has Proteus + E2EI)
2. **Decouples DB schema from OpenMLS internals** — far fewer migrations needed on upgrades
3. **MLS data is small** — full group load is negligible for realistic group sizes
4. **Simpler code** — one table, one load, one diff, one save

### Database migrations

Schema version tracked in `LATEST_SCHEMA_VERSION` constant (`encrypted_db.rs`). Migrations run automatically on `EncryptedDb::open()`. Use the `/add-db-migration` skill when changing storage schema or data format.

## Feature Graph Gate

> The mechanism comes from the copier template: `make verify-feature-graph`,
> its scripts and CI step, with the rules rendered from this project's
> `forbidden_features` answer. The policy is this project's — this section says
> why those rules, and `test/scripts/feature_graph_policy_test.dart`, which the
> template never renders, holds the evidence for them.

`rust/Cargo.toml` states which features this crate *asks* for. It cannot state
which features `openmls` is ultimately **built** with, because cargo unifies
features across the graph: a dependency arriving transitively, in a version
bump nobody here reviewed, can enable one for a crate this manifest never
mentions. A comment in the manifest is a statement of intent that nothing
enforces, so the check reads `cargo tree` instead of the manifest text.

### What must not ship

`openmls` must carry neither `test-utils` nor `backtrace`. Upstream's
`[features]` table has `test-utils = [..., "backtrace"]` **and**
`backtrace = ["dep:backtrace"]`, so the second is reachable on its own —
forbidding only `test-utils` would miss the shorter path. With either enabled,
`LibraryError::custom()` formats a symbolized Rust backtrace — build-machine
paths, symbol names, crate layout — into an error that travels the **ordinary**
error channel out to the Dart caller. No panic required.

### Why the rules are keyed by crate

⚠ A flat list of feature *names* would be red on a healthy tree, twice over:

| crate | feature | why it is fine |
|-------|---------|----------------|
| `openmls_basic_credential` | `test-utils` | deliberate — it is what makes `SignatureKeyPair::private()` reachable, and that crate's `test-utils` implies no backtrace |
| `allo-isolate` | `backtrace` | someone else's — it arrives under `flutter_rust_bridge` and forms no path into openmls's error channel |

The `backtrace` **crate** is permanently in the release graph
(`flutter_rust_bridge → allo-isolate → backtrace`). Both crates sit in the test
fixture so the rule cannot be flattened later without a test going red.

### Design notes

- **Absence is a failure, not a pass.** A crate named in the rules but missing
  from the graph fails the check — a rule matching nothing prints the same
  "clean" as a rule matching something clean, so a renamed or dropped
  dependency cannot silently retire it.
- `--edges normal` (what ends up inside the shipped library), `--target all`
  (a clean union means every target is clean), `--locked` (a property of the
  revision, not of the machine).
- ⚠ **`--manifest-path`, not `cd rust`** — the opposite of what
  `make rust-clippy-web` requires. Safe here because `rust/.cargo/config.toml`
  carries rustflags alone and rustflags never reach resolution: this command
  resolves without compiling. Measured — both invocations emit identical
  output. If that file ever gains `[build] target` or a source replacement,
  measure again.
- It runs **inside** the already-required Linux x86_64 test job, so it adds no
  required status context and needs no ruleset change.

Guard against regression, not a fix: the graph is clean on native, wasm32 and
`--target all`.

## FVM (Flutter Version Management)

This project uses FVM for consistent Flutter/Dart versions.

**Version:** Flutter 3.38.4

FVM is automatically installed by `make setup`.

## Windows Users

On Windows, install `make` first:
- Chocolatey: `choco install make`
- Scoop: `scoop install make`
- Or use Git Bash / WSL

## Changelog Format

Each release is a `## [X.Y.Z] - YYYY-MM-DD` heading split into **audience-scoped**
sections. Keep this structure so entries stay consistent across releases.

```markdown
## [X.Y.Z] - YYYY-MM-DD

### For Users

#### ✨ Highlights

- **<headline>** — short description (mark breaking ones **(breaking)**)
- **openmls vX.Y.Z** — ... (state "unchanged this release" if it didn't move)
- **openmls_frb vX.Y.Z** — Rust FFI bindings

#### Added

- **<summary>** — new public API or capability a consumer can call

#### Changed (Breaking)

- **<summary>** — what broke. Include an **Action required:** note.

#### Changed

- **<summary>** — non-breaking behavior/API change

#### Security

- **<summary>** — security-relevant, user-observable change

#### Fixed

- **<summary>** — bug fix

#### Documentation

- **<summary>** — documentation a consumer reads (README, API docstrings, SECURITY.md)

### For Contributors

#### Added

- **<summary>** — internal tooling only (fuzzing, cargo-deny, scripts, …)

#### Changed

- **<summary>** — CI / lints / build config / template adoption
```

Rules:
- **`### For Users`** = anything a consumer of the published package can observe
  (public API, runtime behavior, the native binary, the build hook). A change is
  "For Users" even if it feels internal when a consumer sees it at build/run time
  (e.g. `overflow-checks` in the shipped binary).
- **`### For Contributors`** = changes that do NOT affect the published package's
  behavior (CI, dev tooling, lints, fuzzing, cargo-deny, build scripts, template
  adoption).
- Every bullet starts with a **bold summary** + em-dash, then the detail.
- Omit any section/subsection with no entries. Order subsections as shown
  (Highlights → Added → Changed (Breaking) → Changed → Security → Fixed →
  Documentation). The order is the list, not a subset of it: `update_changelog`
  anchors on the first `#### ` under `### For Users`, so a subsection filed out
  of order moves where later entries land.
- Released sections are immutable; edit the top pending version until release.

## Publishing Checklist

Releasing itself is **"Release Flow (two stages)"** above — `make release-frb`,
then `make release`. Do not bump versions, tag or push by hand: each script
requires a clean tree, bumps the right file, finalizes the CHANGELOG, and
creates a **signed** tag (`git tag -s`). Do not count on the
`Protect release tags` ruleset to refuse an unsigned one: only Admin may create
a tag at all, and Admin bypasses it (`always`), its `required_signatures` rule
included.

What to have green before starting stage 1:

```bash
make analyze ARGS="--fatal-infos"
make format-check
make test
make rust-test
make rust-clippy
make rust-clippy-web            # blocking: the wasm32 half, which the above cannot see
make doc                        # blocking: unresolved doc references
make rust-doc                   # blocking: intra-doc links, host + wasm32
make test-web                   # the crate's wasm32 tests, in a real browser
make rust-audit
make rust-deny
make verify-frb-pins
make verify-third-party-notices
make actionlint                 # workflows: static + shellcheck (CI runs it too)
make publish-dry-run            # size limits first; then exits 65 on ANY warning, a dirty tree included
```

Push first and let CI go green. `make release-frb` only *warns* when local main
is ahead of origin and then pushes those commits together with the release tag
— so commits CI has never seen would reach origin at the same moment the tag
starts the native build.

## Claude Skills

Claude Code skills available in this project (invoke with `/<skill>` or used automatically by Claude):

| Skill | Description |
|-------|-------------|
| `add-db-migration` | Add a new database migration to EncryptedDb (schema/data format changes) |
| `build-native` | Build the native libraries for a given platform |
| `frb-patterns` | Flutter Rust Bridge patterns and conventions for this project |
| `release-frb-crate` | Release a new `openmls_frb` native crate (stage 1) |
| `release-package` | Prepare a new version for publication to pub.dev (stage 2) |
| `security-review` | Review changes for security issues and secure API usage |
| `update-openmls` | Update the upstream openmls version |
| `update-template` | Update copier template to latest version |
