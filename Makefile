# openmls - Makefile
# Cross-platform build and development commands for Flutter Rust Bridge package
#
# Usage: make <target> [ARGS="..."]
# Example: make build ARGS="--target x86_64-unknown-linux-gnu"
# Example: make analyze ARGS="--fatal-infos"
#
# On Windows CI (Git Bash), use cmd to run fvm.bat from PATH:
# Example: make build ARGS="--target x86_64-pc-windows-msvc" FVM="cmd //c fvm"

.PHONY: help setup setup-fvm setup-rust-tools setup-frb-codegen setup-android setup-web setup-fuzz codegen regen build build-android build-web run-example-web test-web test coverage analyze format format-check get clean version get-version check-new-openmls-version check-exists-openmls-frb-release check-template-updates update-template check-targets third-party-notices verify-third-party-notices verify-frb-pins rust-audit rust-deny rust-check rust-test rust-clippy rust-doc rust-geiger fuzz fuzz-list fuzz-seed doc publish publish-dry-run rust-update update-changelog release-frb release setup-repo-protections

# FVM command - can be overridden to provide full path on Windows CI
FVM ?= fvm

# Pinned flutter_rust_bridge_codegen version.
# Must match the flutter_rust_bridge dependency in pubspec.yaml — a codegen
# binary of a different version produces different bindings, which makes CI
# and local codegen runs disagree.
FRB_CODEGEN_VERSION ?= 2.13.0

# Arguments are passed via ARGS variable
ARGS ?=

# Default target
.DEFAULT_GOAL := help

# =============================================================================
# Help
# =============================================================================

help:
	@echo ""
	@echo "openmls - Available commands:"
	@echo ""
	@echo "  Pass arguments via ARGS variable: make <target> ARGS=\"...\""
	@echo ""
	@echo "  SETUP"
	@echo "    make setup                        - Full setup (FVM + Rust tools)"
	@echo "    make setup-fvm                    - Install FVM and project Flutter version only"
	@echo "    make setup-rust-tools             - Install Rust tools (cargo-audit, frb codegen)"
	@echo "    make setup-frb-codegen            - Install pinned flutter_rust_bridge_codegen"
	@echo "    make setup-android                - Install Android build tools (cargo-ndk)"
	@echo "    make setup-web                    - Install web build tools (wasm-pack)"
	@echo "    make setup-repo-protections       - Apply GitHub rulesets + native-build env (one-time, needs gh admin)"
	@echo ""
	@echo "  BUILD & CODEGEN"
	@echo "    make codegen                      - Generate Dart bindings from Rust code"
	@echo "    make build                        - Build Rust library for current platform"
	@echo "                                        Example: make build ARGS=\"--target aarch64-apple-darwin\""
	@echo "    make build-android                - Build for Android (all ABIs)"
	@echo "                                        Example: make build-android ARGS=\"--target arm64-v8a\""
	@echo "    make build-web                    - Build WASM for web platform"
	@echo "    make run-example-web              - Build WASM and run example/ in Chrome"
	@echo "                                        Example: make run-example-web ARGS=\"--web-port=5599\""
	@echo ""
	@echo "  CI / VERSION CHECKS"
	@echo "    make check-new-openmls-version  - Check for new upstream openmls version"
	@echo "                                        Example: make check-new-openmls-version ARGS=\"--update\""
	@echo "    make check-exists-openmls-frb-release - Check if FRB release exists on GitHub"
	@echo "    make check-template-updates       - Check for new copier template version"
	@echo "    make update-template              - Apply a copier template update"
	@echo "                                        Example: make update-template ARGS=\"--version v4.3.0\""
	@echo "    make third-party-notices          - Regenerate THIRD_PARTY_NOTICES.txt from the dep graph"
	@echo "    make verify-third-party-notices   - Verify THIRD_PARTY_NOTICES.txt is up to date"
	@echo "    make verify-frb-pins              - Verify every file names the same flutter_rust_bridge version"
	@echo "    make check-targets                - Check deployment target consistency (iOS/macOS/Android)"
	@echo "                                        Example: make check-targets ARGS=\"--ios --set 14.0\""
	@echo "    make rust-update                  - Update Cargo.lock (cargo update)"
	@echo "    make update-changelog             - Update CHANGELOG.md with AI"
	@echo "                                        Example: make update-changelog ARGS=\"--version v1.0.0\""
	@echo ""
	@echo "  RUST QUALITY"
	@echo "    make rust-check                   - Check Rust code compiles"
	@echo "    make rust-test                    - Run Rust unit tests"
	@echo "    make test-web                     - Run the crate's browser tests (headless Chrome)"
	@echo "                                        Example: make test-web CHROMEDRIVER=/path/to/chromedriver"
	@echo "    make rust-clippy                  - Lint Rust code with clippy (warnings = errors)"
	@echo "    make rust-doc                     - Rustdoc gate over the crate (-D warnings)"
	@echo "    make rust-geiger                  - Unsafe-expression census (diagnostic, not a gate)"
	@echo "    make rust-audit                   - Audit Rust dependencies for vulnerabilities"
	@echo "    make rust-deny                    - Check advisories/licenses/sources (cargo-deny)"
	@echo ""
	@echo "  FUZZING (requires nightly Rust; run 'make setup-fuzz' once)"
	@echo "    make fuzz-list                    - List available fuzz targets"
	@echo "    make fuzz-seed                    - Generate the seed corpus (rust/fuzz/corpus/)"
	@echo "    make fuzz                         - Run a fuzz target"
	@echo "                                        Example: make fuzz ARGS=\"mls_message -- -max_total_time=60\""
	@echo ""
	@echo "  DART QUALITY"
	@echo "    make test                         - Run tests"
	@echo "                                        Example: make test ARGS=\"test/example_test.dart\""
	@echo "    make coverage                     - Run tests with coverage report"
	@echo "    make analyze                      - Run static analysis"
	@echo "                                        Example: make analyze ARGS=\"--fatal-infos\""
	@echo "    make format                       - Format Dart code"
	@echo "    make format-check                 - Check Dart code formatting"
	@echo "    make doc                          - Generate API docs (GATE: fails on unresolved refs)"
	@echo ""
	@echo "  RELEASE"
	@echo "    make release-frb                  - Release openmls_frb native crate (stage 1)"
	@echo "                                        Example: make release-frb ARGS=\"--version 5.2.0\""
	@echo "    make release                      - Release Dart package to pub.dev (stage 2)"
	@echo "                                        Example: make release ARGS=\"--version 6.1.0\""
	@echo ""
	@echo "  PUBLISHING"
	@echo "    make publish-dry-run              - Validate package before publishing"
	@echo "    make publish                      - Publish package (CI only, blocked locally)"
	@echo ""
	@echo "  UTILITIES"
	@echo "    make get                          - Get dependencies"
	@echo "    make clean                        - Clean build artifacts"
	@echo "    make version                      - Show current crate version"
	@echo "    make help                         - Show this help message"
	@echo ""

# =============================================================================
# Setup
# =============================================================================

setup:
	@if ! command -v cargo >/dev/null 2>&1; then \
		echo "ERROR: Rust not found. Install from https://rustup.rs"; \
		exit 1; \
	fi
	@$(MAKE) setup-fvm
	@$(MAKE) setup-rust-tools
	@echo ""
	@echo "Full setup complete! You can now use 'make help' to see available commands."

setup-fvm:
	@echo "Installing FVM (Flutter Version Management)..."
	dart pub global activate fvm
	@echo ""
	@echo "Installing project Flutter version..."
	$(FVM) use $$(dart scripts/get_flutter_version.dart) --force
	@echo ""
	@echo "Getting dependencies..."
	@touch .skip_openmls_hook
	@$(FVM) dart pub get --no-example; ret=$$?; rm -f .skip_openmls_hook; exit $$ret
	@echo ""
	@echo "Configuring git hooks..."
	git config core.hooksPath .githooks
	@echo ""
	@echo "FVM setup complete!"

setup-rust-tools:
	@echo "Installing Rust tools..."
	@if ! command -v cargo-audit >/dev/null 2>&1; then \
		echo "Installing cargo-audit..."; \
		cargo install cargo-audit --locked; \
	else \
		echo "cargo-audit already installed"; \
	fi
	@$(MAKE) setup-frb-codegen
	@if ! command -v cargo-deny >/dev/null 2>&1; then \
		echo "Installing cargo-deny..."; \
		cargo install cargo-deny --locked; \
	else \
		echo "cargo-deny already installed"; \
	fi
	@echo ""
	@echo "Rust tools setup complete!"

setup-frb-codegen:
	@INSTALLED="$$(flutter_rust_bridge_codegen --version 2>/dev/null | awk '{print $$NF}')"; \
	if [ "$$INSTALLED" = "$(FRB_CODEGEN_VERSION)" ]; then \
		echo "flutter_rust_bridge_codegen $(FRB_CODEGEN_VERSION) already installed"; \
	else \
		echo "Installing flutter_rust_bridge_codegen $(FRB_CODEGEN_VERSION) (found: $${INSTALLED:-none})..."; \
		cargo install flutter_rust_bridge_codegen --version $(FRB_CODEGEN_VERSION) --locked --force; \
	fi

setup-fuzz:
	@echo "Installing fuzzing tools..."
	@if ! command -v cargo-fuzz >/dev/null 2>&1; then \
		echo "Installing cargo-fuzz..."; \
		cargo install cargo-fuzz --locked; \
	else \
		echo "cargo-fuzz already installed"; \
	fi
	@echo "Installing nightly toolchain (required by cargo-fuzz)..."
	rustup toolchain install nightly --profile minimal
	@echo ""
	@echo "Fuzzing setup complete! Try: make fuzz-list"

setup-android:
	@echo "Installing Android build tools..."
	@if ! command -v cargo-ndk >/dev/null 2>&1; then \
		echo "Installing cargo-ndk..."; \
		cargo install cargo-ndk; \
	else \
		echo "cargo-ndk already installed"; \
	fi
	@echo ""
	@echo "Android setup complete!"
	@echo "Make sure you have Android NDK installed via Android Studio or sdkmanager."
setup-web:
	@echo "Installing web build tools..."
	@if ! command -v wasm-pack >/dev/null 2>&1; then \
		echo "Installing wasm-pack..."; \
		cargo install wasm-pack; \
	else \
		echo "wasm-pack already installed"; \
	fi
	rustup target add wasm32-unknown-unknown
	@echo ""
	@echo "Web setup complete!"

# Apply the committed repository rulesets (.github/rulesets/*.json) and the
# native-build environment to the GitHub repo via `gh` (one-time; run after the
# GitHub repo exists). Idempotent by ruleset name; needs `gh` as a repo admin.
#   make setup-repo-protections                  # apply (skips existing rulesets)
#   make setup-repo-protections ARGS="--update"  # overwrite existing rulesets
setup-repo-protections:
	@$(FVM) dart scripts/setup_repo_protections.dart $(ARGS)

# =============================================================================
# Code Generation
# =============================================================================

codegen: setup-frb-codegen
	@touch .skip_openmls_hook
	@flutter_rust_bridge_codegen generate $(ARGS); ret=$$?; rm -f .skip_openmls_hook; exit $$ret

# Alias for codegen (common shorthand)
regen: codegen

# =============================================================================
# Build
# =============================================================================

# ⚠ Deliberately NOT `--locked`, unlike the release workflow. A project
# generated from this template has no rust/Cargo.lock until something builds it
# for the first time — copier's tasks do not create one — and this target is
# what `test-reusable.yml` runs on every push, so `--locked` here would fail a
# new project's very first CI run on all four platforms. The reproducibility
# claim belongs where the shipped artifact is produced, and that is where the
# flag is. Once your Cargo.lock is committed, adding it here is a good idea.
build:
	@echo "Building Rust library..."
	cargo build --release --manifest-path rust/Cargo.toml $(ARGS)
	@echo ""
	@echo "Build complete! Library at: rust/target/"

build-android:
	@echo "Building Rust library for Android..."
	@PLATFORM=$$(dart scripts/get_android_min_sdk.dart) && \
		cd rust && cargo ndk --platform $$PLATFORM build --release $(ARGS)
	@echo ""
	@echo "Build complete! Library at: rust/target/<arch>/release/"
build-web:
	@echo "Building WASM for web..."
	cd rust && wasm-pack build --target no-modules --release \
		--out-dir target/wasm32 --out-name openmls_frb --no-typescript
	@rm -f rust/target/wasm32/.gitignore rust/target/wasm32/package.json
	@echo ""
	@echo "Build complete! WASM files at: rust/target/wasm32/"

# Run the example app in a browser against a freshly built WASM module.
#
# The order is the whole point, and each step is there because skipping it has
# a failure mode:
#
#   1. `make build-web` first, because nothing else in this repository compiles
#      wasm32 on demand — running the app without it serves whatever was built
#      last, which can be a different commit's Rust.
#   2. `rm -rf example/web/pkg` next. The build hook prefers a local wasm build
#      over a downloaded one and declares the built files as dependencies, so
#      it *should* refresh on its own; the wipe costs nothing and removes the
#      case where a stale copy is served and the failure looks like a Rust bug.
#   3. `flutter run -d chrome` last, and NOT `--wasm`: that flag compiles the
#      Dart half with dart2wasm, which flutter_rust_bridge's generated decoders
#      do not support. The Rust side is a wasm module either way.
#
# Pass flutter arguments through ARGS, e.g. ARGS="--web-port=5599".
run-example-web: build-web
	@rm -rf example/web/pkg
	cd example && $(FVM) flutter run -d chrome $(ARGS)

# The wasm32 test runner's own timeout defaults to 20 s, and it is raised here
# rather than when it first bites. The browser runs every test on ONE JS
# thread, so a test that blocks it — a key derivation, a password hash, any
# CPU-bound synchronous work — starves the callbacks that every other
# concurrently-driven test is waiting on: the suite is charged for its slowest
# member instead of each test being timed on its own. The resulting failure is
# actively misleading. The runner names whichever test was scheduled LAST, not
# the slow one, and then SIGKILLs the driver with every other test already
# green, so it reads as a hang in an unrelated test.
#
# Unlike CHROMEDRIVER below, this variable IS honoured from the environment, so
# `?=` lets a caller override it.
WASM_BINDGEN_TEST_TIMEOUT ?= 120
export WASM_BINDGEN_TEST_TIMEOUT

# Run the crate's #[wasm_bindgen_test] tests in a real headless browser.
#
# THE ONLY TARGET HERE THAT EXECUTES WEB CODE. `make test` is the Dart VM and
# `make build-web` only compiles, so without this every
# `cfg(target_arch = "wasm32")` branch in the crate is reachable by no check at
# all. Those branches are precisely the ones nothing else can cover: a wasm32
# body is a *different implementation* of the same function rather than the
# same code running on another host, so a green native suite says nothing about
# it. `current_time()` in rust/src/utils.rs is the scaffold's example — native
# reads the system clock, wasm32 calls into JavaScript.
#
# ⚠ Pass a chromedriver. wasm-pack looks for one on $$PATH, honours
# `--chromedriver`, and otherwise DOWNLOADS THE LATEST — an unpinned network
# fetch on every run. That, and not a version mismatch, is the reason to pin:
# a mismatched driver is not known to fail loudly, so a green run is no
# evidence the driver matched the browser. The CHROMEDRIVER *environment*
# variable is NOT honoured — wasm-pack overwrites it with its own — which is
# why this is a make variable that becomes the flag:
#   make test-web CHROMEDRIVER=/path/to/chromedriver
#
# ⚠ And that pins the DRIVER, not the BROWSER. With no `webdriver.json` and no
# WASM_BINDGEN_TEST_WEBDRIVER_JSON, the runner sends empty capabilities and
# ChromeDriver launches whatever Chrome is installed. To pin the browser, point
# WASM_BINDGEN_TEST_WEBDRIVER_JSON at a file carrying
# {"goog:chromeOptions": {"binary": "<path to the browser>"}}. The run then
# prints `Ok` instead of `Not found` under "Try find webdriver.json", which is
# the only line in the log saying a browser pin applied at all — and `Ok` alone
# only proves the file was READ, so check a deliberately bad path fails too.
#
# ⚠ `console::log_1` output is swallowed unless the run is given --nocapture,
# so a measurement printed from a test is invisible by default:
#   make test-web ARGS="-- --nocapture"
# Debug wasm is far slower than a native debug build; ARGS="--release" is the
# lever when the suite gets slow.
test-web:
	cd rust && wasm-pack test --headless --chrome \
		$(if $(CHROMEDRIVER),--chromedriver "$(CHROMEDRIVER)",) --lib $(ARGS)
# =============================================================================
# Rust Quality
# =============================================================================

rust-check:
	cargo check --manifest-path rust/Cargo.toml

# Run the crate's own `#[cfg(test)]` unit tests. These cover invariants the Dart
# suite cannot reach — notably `classical_ops_do_not_init_libcrux`, which is the
# stated justification for several advisory ignores in .cargo/audit.toml and
# rust/deny.toml. Without this in CI those justifications go unverified.
rust-test:
	cargo test --manifest-path rust/Cargo.toml $(ARGS)

# Lint hand-written Rust with clippy; warnings are errors so CI fails on any lint.
# --all-targets covers the lib, its tests, and examples of this crate.
# The separate, nightly-only fuzz crate (rust/fuzz) is linted with
# `cd rust/fuzz && cargo +nightly clippy`.
rust-clippy:
	cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings

# Rustdoc over the hand-written crate, and a GATE: it fails the build on a
# broken intra-doc link rather than reporting one.
#
# What it covers is the half `make doc` structurally cannot see: the `[...]`
# links in the parts of rust/src/ that stay in Rust — private items, `//!`
# module headers, anything not copied out to Dart — where that link syntax is
# correct style and nothing else reads it. It is NOT the guard for the shipped
# documentation. Only docstrings under rust/src/api/ are copied verbatim into
# lib/src/rust/ and published, and there the failure is the opposite one: a
# link that resolves in Rust and reaches pub.dev dead. `make doc` plus the
# plain-backtick rule in CLAUDE.md is what covers that half.
#
# ⚠ EVERY FLAG BELOW IS LOAD-BEARING. Drop one and this target reports 0 over a
# surface it never read — which is worse than not having it, because the zero
# reads as evidence.
#
# --document-private-items, because rustdoc resolves intra-doc links only in
# the items it is DOCUMENTING. A private `mod` is not documented by default, so
# without this every private module's links go unchecked while the count stays
# at 0. Note that a link to a private item is not nameable across modules even
# with this flag; plain backticks plus prose naming the file is the honest form
# there.
#
# RUSTDOCFLAGS=-D warnings, because `cargo doc` exits 0 on warnings. A
# diagnostic nobody reads and a gate that cannot fail are the same thing.
#
# --no-deps keeps the output to this crate.
#
# The wasm32 leg, because `cfg(target_arch = "wasm32")` modules are invisible to
# the host run: each leg documents a tree the other cannot compile, so one run
# checks only half the crate.
#
# ⚠ Both legs run with `cd rust`, NOT --manifest-path. Cargo discovers
# .cargo/config.toml relative to the CWD, so invoking this from the repository
# root silently drops rust/.cargo/config.toml — the file carrying the wasm32
# rustflags — and the wasm32 leg is then built without the configuration the
# crate expects.
rust-doc:
	cd rust && RUSTDOCFLAGS="-D warnings" cargo doc --no-deps \
		--document-private-items $(ARGS)
	cd rust && RUSTDOCFLAGS="-D warnings" cargo doc --no-deps \
		--document-private-items --target wasm32-unknown-unknown $(ARGS)

# cargo-geiger's census of memory-unsafe expressions across the dependency
# graph. DIAGNOSTIC ONLY — deliberately wired into no workflow, for the two
# reasons below. No setup target installs it: `cargo install cargo-geiger`.
#
# Reading the number: this crate denies unsafe in hand-written code
# (`[lints.rust] unsafe_code = "deny"`), and the FRB-generated module opts out
# at its declaration in rust/src/lib.rs. So a non-zero count for this crate
# itself is generated code, and everything below it is upstream. Compare a run
# against a baseline recorded when the graph last moved, never against 0.
#
# ⚠ Why it is not a gate as it stands:
#
#   1. IT EXITS NON-ZERO ON A CLEAN RUN. cargo-geiger 0.13 ends with
#      "error: Found N warnings" where every one is
#      "Dependency file was never scanned:" for a non-Rust file it was handed
#      anyway — READMEs, .proto, .c. Nothing to do with unsafe code. A gate
#      would have to filter that before its exit code meant anything.
#   2. The count is not this project's to hold still. The generated bridge
#      dominates it, and every `make codegen` and every FRB bump rewrites that
#      file.
#
# `$(CURDIR)` is not decoration: cargo-geiger 0.13 refuses a relative
# --manifest-path outright ("is not an absolute path"), unlike every other
# cargo subcommand this Makefile drives.
rust-geiger:
	cargo geiger --manifest-path $(CURDIR)/rust/Cargo.toml $(ARGS)

rust-audit:
	cargo audit --file rust/Cargo.lock

rust-deny:
	cargo deny --manifest-path rust/Cargo.toml check $(ARGS)

# =============================================================================
# Fuzzing (cargo-fuzz + libFuzzer, requires nightly - run 'make setup-fuzz')
# =============================================================================

# List the available libFuzzer targets.
fuzz-list:
	cd rust && cargo +nightly fuzz list

# Run a fuzz target. Pass the target name (and libFuzzer flags) via ARGS.
#   make fuzz ARGS="mls_message"
#   make fuzz ARGS="mls_message -- -max_total_time=120"
fuzz:
	@if [ -z "$(ARGS)" ]; then \
		echo "Usage: make fuzz ARGS=\"<target> [-- <libfuzzer-flags>]\""; \
		echo "Available targets:"; \
		cd rust && cargo +nightly fuzz list; \
		exit 1; \
	fi
	cd rust && cargo +nightly fuzz run $(ARGS)

# Generate the seed corpus (valid inputs) under rust/fuzz/corpus/<target>/.
# Extend rust/fuzz/examples/gen_corpus.rs as you add fuzz targets.
fuzz-seed:
	cd rust/fuzz && cargo run --release --example gen_corpus

# =============================================================================
# CI / Version Checks
# =============================================================================

check-new-openmls-version:
	@$(FVM) dart scripts/check_new_upstream_version.dart $(ARGS)

check-exists-openmls-frb-release:
	@$(FVM) dart scripts/check_exists_frb_release.dart $(ARGS)

check-template-updates:
	@$(FVM) dart scripts/check_template_updates.dart $(ARGS)

# Applies a template update: runs copier, reports what it could not merge, and
# records the adoption in the CHANGELOG. Needs `copier` on PATH (see
# CONTRIBUTING) and, for the CHANGELOG entry, AI_MODELS plus a key for each
# provider it names; without them the update still applies.
update-template:
	@$(FVM) dart scripts/update_template.dart $(ARGS)

check-targets:
	@$(FVM) dart scripts/check_deployment_targets.dart $(ARGS)

# Regenerate the third-party notice inventory for the shipped native library.
# Run after any dependency change; CI verifies the committed file matches.
third-party-notices:
	@$(FVM) dart scripts/generate_third_party_notices.dart $(ARGS)

verify-third-party-notices:
	@$(FVM) dart scripts/generate_third_party_notices.dart --check

# Five files record the flutter_rust_bridge version and the runtime asserts two
# of them are equal, so a disagreement ships as a package that throws on init.
# File reads only — no build, no network.
verify-frb-pins:
	@$(FVM) dart scripts/verify_frb_pins.dart $(ARGS)

# Updating the lockfile changes the dependency graph, which invalidates the
# third-party notice inventory. Regenerating here keeps the two in lockstep
# both locally and in the scheduled update workflow (which calls this target),
# so nobody has to remember a second command before CI rejects the branch.
rust-update:
	@echo "Updating Cargo.lock..."
	@cd rust && cargo update
	@echo ""
	@echo "Regenerating third-party notices for the new dependency graph..."
	@$(MAKE) third-party-notices
	@echo ""
	@echo "Cargo.lock and THIRD_PARTY_NOTICES.txt updated!"

update-changelog:
	@$(FVM) dart scripts/update_changelog.dart $(ARGS)

# =============================================================================
# Release
# =============================================================================

# Stage 1: release the openmls_frb native crate. Bumps rust/Cargo.toml,
# stamps the CHANGELOG highlight, signs a commit + `openmls_frb-<version>`
# tag, and pushes (triggers the native build). You enter your signing
# passphrase interactively during the command.
#   Example: make release-frb ARGS="--version 5.2.0"
release-frb:
	@$(FVM) dart scripts/release_frb.dart $(ARGS)

# Stage 2: release the Dart package to pub.dev. Verifies the stage-1 native
# binary exists, validates with a publish dry-run (clean pre-bump tree), bumps
# pubspec.yaml, finalizes the CHANGELOG, then signs a commit + `vX.Y.Z` tag and
# pushes (triggers publish.yml). You enter your signing passphrase interactively
# during the command.
#   Example: make release ARGS="--version 6.1.0"
release:
	@$(FVM) dart scripts/release.dart $(ARGS)

# =============================================================================
# Dart Quality
# =============================================================================

test:
	$(FVM) dart test $(ARGS)

# The number this prints is coverage of the code somebody in this repository
# WROTE. Everything under lib/src/rust/ is emitted by `make codegen` — that is
# `dart_output` in flutter_rust_bridge.yaml — and is excluded, not just the
# frb_generated* files: the rest of that directory is the same generator's
# output one layer up, and what goes uncovered in it is almost all `hashCode`
# and `operator ==` on value classes. Including it lets a codegen run move the
# badge with nobody having written a line, which is noise a coverage gate is
# supposed to not have.
#
# `--ignore-files` is an addMultiOption, so repeat it (or comma-join it) for
# more than one glob. Do NOT "normalise" the second glob to
# `**/lib/src/rust/**`: a glob starting with `**` cannot match an absolute path
# (glob's DoubleStarNode is canMatchAbsolute = false), so it is tested only
# against the CWD-relative path, in which nothing precedes `lib` — it silently
# matches nothing and the ignore quietly stops working. This form is anchored to
# the repository root, which is where make runs it.
coverage:
	$(FVM) dart test --coverage=coverage
	$(FVM) dart run coverage:format_coverage --check-ignore --lcov --in=coverage --out=coverage/lcov.info --report-on=lib --ignore-files '**/frb_generated*.dart' --ignore-files 'lib/src/rust/**'
	lcov --summary coverage/lcov.info

analyze:
	$(FVM) flutter analyze $(ARGS)

format:
	$(FVM) dart format . $(ARGS)

# `--output=none` because this one is the *check*. Without it `dart format`
# writes the reformatted files and *then* exits non-zero, so the gate edits the
# tree it was asked to inspect: the pre-commit hook aborts the commit and leaves
# behind a modification the committer never made, and the template-update
# workflow silently repairs its own pull request while reporting a failure the
# merged branch cannot reproduce. `make format` is the one that writes.
format-check:
	$(FVM) dart format --output=none --set-exit-if-changed . $(ARGS)

# A GATE, not just a generator: dartdoc_options.yaml promotes
# `unresolved-doc-reference` to an error, so this exits non-zero on a docstring
# that names a symbol dartdoc cannot resolve. That file carries the reasoning
# and the one thing the gate cannot see.
doc:
	@touch .skip_openmls_hook
	@rm -rf doc; $(FVM) dart doc $(ARGS); ret=$$?; rm -f .skip_openmls_hook; exit $$ret
	@echo ""
	@echo "Documentation generated in doc/api/"
	@echo "Open doc/api/index.html to view locally"

# =============================================================================
# Utilities
# =============================================================================

get:
	@touch .skip_openmls_hook
	@$(FVM) dart pub get --no-example; ret=$$?; rm -f .skip_openmls_hook; exit $$ret

clean:
	rm -rf .dart_tool build rust/target
	@touch .skip_openmls_hook
	@$(FVM) dart pub get --no-example; ret=$$?; rm -f .skip_openmls_hook; exit $$ret

version:
	@$(FVM) dart scripts/get_version.dart

# Internal target for getting version in scripts (outputs only the value)
get-version:
	@$(FVM) dart scripts/get_version.dart --field version

# =============================================================================
# Publishing
# =============================================================================

publish-dry-run:
	$(FVM) dart pub publish --dry-run

publish:
ifndef CI
	@echo ""
	@echo "ERROR: Local publishing is disabled."
	@echo ""
	@echo "This package uses automated publishing via GitHub Actions."
	@echo "To publish a new version:"
	@echo ""
	@echo "  1. Update version in pubspec.yaml"
	@echo "  2. Update CHANGELOG.md"
	@echo "  3. Commit and push changes"
	@echo "  4. Create and push a tag: git tag v0.1.0 && git push origin v0.1.0"
	@echo "  5. GitHub Actions will automatically publish to pub.dev"
	@echo ""
	@echo "To validate the package locally, use: make publish-dry-run"
	@echo ""
	@exit 1
else
	$(FVM) dart pub publish $(ARGS)
endif
