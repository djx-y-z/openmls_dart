# openmls - Makefile
# Cross-platform build and development commands for Flutter Rust Bridge package
#
# Usage: make <target> [ARGS="..."]
# Example: make build ARGS="--target x86_64-unknown-linux-gnu"
# Example: make analyze ARGS="--fatal-infos"
#
# On Windows CI (Git Bash), use cmd to run fvm.bat from PATH:
# Example: make build ARGS="--target x86_64-pc-windows-msvc" FVM="cmd //c fvm"

.PHONY: help setup setup-fvm setup-rust-tools setup-frb-codegen setup-android setup-web setup-fuzz codegen regen build build-android build-ios build-web run-example-web test-web test-example test-example-ci test-example-web doctor drive-example build-example coverage-example create-consumer package-example-android package-example-ios package-example-macos verify-example-coverage verify-example-library test coverage analyze format format-check get clean version get-version check-new-openmls-version check-upstream-advisories check-exists-openmls-frb-release check-template-updates update-template check-targets check-msrv third-party-notices verify-third-party-notices verify-frb-pins verify-pub-limits verify-feature-graph verify-android-alignment verify-release-artifacts verify-library-loads actionlint rust-audit rust-deny rust-check rust-check-ios rust-test rust-clippy rust-clippy-web rust-doc rust-geiger fuzz fuzz-list fuzz-seed doc publish publish-dry-run rust-update update-changelog update-evidence release-frb release setup-repo-protections

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
	@echo "    make setup-web                    - Install web build tools (wasm-pack $(WASM_PACK_VERSION))"
	@echo "    make setup-repo-protections       - Apply GitHub rulesets + both release environments (needs gh admin)"
	@echo ""
	@echo "  BUILD & CODEGEN"
	@echo "    make codegen                      - Generate Dart bindings from Rust code"
	@echo "    make build                        - Build Rust library for current platform"
	@echo "                                        Example: make build ARGS=\"--target aarch64-apple-darwin\""
	@echo "    make build-android                - Build for Android (all ABIs)"
	@echo "                                        Example: make build-android ARGS=\"--target arm64-v8a\""
	@echo "    make build-ios                    - Build for iOS (device and both simulators)"
	@echo "                                        Example: make build-ios ARGS=\"--target aarch64-apple-ios-sim\""
	@echo "    make build-web                    - Build WASM for web platform"
	@echo "    make run-example-web              - Build WASM and run example/ in Chrome"
	@echo "                                        Example: make run-example-web ARGS=\"--web-port=5599\""
	@echo ""
	@echo "  EXAMPLE APP (the package inside a real Flutter app)"
	@echo "    make test-example                 - Run the integration tests on a device"
	@echo "                                        Example: make test-example ARGS=\"-d macos\""
	@echo "    make test-example-web             - Run them in a real browser"
	@echo "                                        Example: make test-example-web ARGS=\"--release\""
	@echo "    make drive-example                - Run them under flutter drive, for profile mode"
	@echo "                                        Example: make drive-example ARGS=\"--profile -d macos\""
	@echo "    make test-example-ci              - Either, as CI runs them: a failed test fails at once,"
	@echo "                                        a run that never got that far runs again"
	@echo "                                        Example: make test-example-ci ARGS=\"--attempts 3 -- -d <device>\""
	@echo "    make build-example                - Build the app with the tests in it, without running it"
	@echo "                                        Example: make build-example ARGS=\"apk --debug\""
	@echo "    make coverage-example             - Run them, then fail on a bridged function none of them calls"
	@echo "                                        Example: make coverage-example ARGS=\"-d macos\""
	@echo "    make create-consumer              - Make a new app that uses the package from pub.dev"
	@echo "                                        Example: make create-consumer VERSION=9.0.0"
	@echo "                                        Then:    make test-example EXAMPLE_DIR=build/consumer ARGS=\"-d macos\""
	@echo "    make package-example-android      - Build the release APK, every ABI, and check its libraries"
	@echo "    make package-example-ios          - Build for a real iPhone and for both simulators, and check the library"
	@echo "    make package-example-macos        - Build the universal app, and check both architectures are in it"
	@echo "    make verify-example-coverage      - That check alone, over the last coverage run"
	@echo "    make verify-example-library       - Check the tests ran on the library they meant to"
	@echo "                                        Example: make verify-example-library ARGS=\"--built\""
	@echo ""
	@echo "  CI / VERSION CHECKS"
	@echo "    make check-new-openmls-version  - Check for new upstream openmls version"
	@echo "                                        Example: make check-new-openmls-version ARGS=\"--update\""
	@echo "    make check-upstream-advisories    - Check openmls/openmls's published advisories against Cargo.lock"
	@echo "    make check-exists-openmls-frb-release - Check if FRB release exists on GitHub"
	@echo "    make check-template-updates       - Check for new copier template version"
	@echo "    make update-template              - Apply a copier template update"
	@echo "                                        Example: make update-template ARGS=\"--version v4.3.0\""
	@echo "                                        Answer a new question: ARGS=\"--version v4.3.0 --data key=value\""
	@echo "    make third-party-notices          - Regenerate THIRD_PARTY_NOTICES.txt from the dep graph"
	@echo "    make verify-third-party-notices   - Verify THIRD_PARTY_NOTICES.txt is up to date"
	@echo "    make verify-frb-pins              - Verify every file names the same flutter_rust_bridge version"
	@echo "    make verify-pub-limits            - Verify no file is over what pub.dev accepts at upload"
	@echo "    make verify-feature-graph         - Verify no forbidden cargo feature is enabled (GATE)"
	@echo "    make verify-android-alignment     - Verify built Android libraries are 16 KB-aligned"
	@echo "    make verify-release-artifacts     - Verify release archives hold what their names say"
	@echo "                                        Example: make verify-release-artifacts ARGS=release-archives"
	@echo "    make verify-library-loads         - Load a built native library and check the FRB runtime is in it"
	@echo "                                        Example: make verify-library-loads ARGS=rust/target/release/libopenmls_frb.dylib"
	@echo "    make actionlint                   - Lint the GitHub Actions workflows (actionlint)"
	@echo "    make check-targets                - Check deployment target consistency (iOS/macOS/Android)"
	@echo "                                        Example: make check-targets ARGS=\"--ios --set 14.0\""
	@echo "    make check-msrv                   - Check the minimum Rust version against the dependency graph"
	@echo "                                        Example: make check-msrv ARGS=\"--update\""
	@echo "    make rust-update                  - Re-resolve Cargo.lock for rust/Cargo.toml (cargo update --workspace)"
	@echo "    make update-changelog             - Update CHANGELOG.md with AI"
	@echo "                                        Example: make update-changelog ARGS=\"--version 1.0.0\""
	@echo "    make update-evidence              - Write down what an upstream update changed"
	@echo "                                        Example: make update-evidence ARGS=\"--out /tmp/evidence\""
	@echo ""
	@echo "  RUST QUALITY"
	@echo "    make rust-check                   - Check Rust code compiles"
	@echo "    make rust-check-ios               - Type-check the iOS targets"
	@echo "    make rust-test                    - Run Rust unit tests"
	@echo "    make test-web                     - Run the crate's browser tests (headless Chrome)"
	@echo "                                        Example: make test-web CHROMEDRIVER=/path/to/chromedriver"
	@echo "    make rust-clippy                  - Lint Rust code with clippy (warnings = errors)"
	@echo "    make rust-clippy-web              - The same lint over the wasm32 half of the crate"
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
	@echo "    make doctor                       - Show the toolchains and devices Flutter finds"
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

# `--locked` builds cargo-ndk from its own committed lockfile. The VERSION is
# deliberately NOT pinned here the way the Android CI jobs pin it: a local
# Android build is never the artefact that ships, and this recipe skips the
# install entirely when any cargo-ndk is already on PATH, so a pin here could
# not correct a wrong one anyway. What ships is gated on the bytes, by
# `make verify-android-alignment`.
setup-android:
	@echo "Installing Android build tools..."
	@if ! command -v cargo-ndk >/dev/null 2>&1; then \
		echo "Installing cargo-ndk..."; \
		cargo install cargo-ndk --locked; \
	else \
		echo "cargo-ndk already installed"; \
	fi
	@echo ""
	@echo "Android setup complete!"
	@echo "Make sure you have Android NDK installed via Android Studio or sdkmanager."

# wasm-pack builds the WASM module a release ships and runs wasm-opt over it,
# so it is pinned, and built from its own lock file, like cargo-ndk. This is
# the one place the version is named: every CI job that builds for the web,
# the release build included, installs it through this target. A wasm-pack of
# another version is replaced, not kept. Dependabot does not read it; it
# moves by hand. The wasm-bindgen-cli and binaryen that wasm-pack downloads
# are not verified by it: the first follows the wasm-bindgen version in
# rust/Cargo.lock, the second this version.
WASM_PACK_VERSION := 0.15.0

setup-web:
	@echo "Installing web build tools..."
	@if [ "$$(wasm-pack --version 2>/dev/null)" = "wasm-pack $(WASM_PACK_VERSION)" ]; then \
		echo "wasm-pack $(WASM_PACK_VERSION) already installed"; \
	else \
		echo "Installing wasm-pack $(WASM_PACK_VERSION)..."; \
		cargo install wasm-pack --locked --version $(WASM_PACK_VERSION); \
	fi
	rustup target add wasm32-unknown-unknown
	@echo ""
	@echo "Web setup complete!"

# Apply the committed repository rulesets (.github/rulesets/*.json) and the
# native-build environment to the GitHub repo via `gh` (one-time; run after the
# GitHub repo exists). Idempotent by ruleset name; needs `gh` as a repo admin.
#   make setup-repo-protections                  # apply (skips existing rulesets)
#   make setup-repo-protections ARGS="--update"  # overwrite existing rulesets
#   make setup-repo-protections ARGS="--dry-run" # show what would change
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

# The crate version, read the way the build hook's own parser reads it: the
# first `version =` line of rust/Cargo.toml. Both stamps below are written
# with it, so they cannot parse the file two different ways.
READ_CRATE_VERSION = grep -m1 -E '^version[[:space:]]*=' rust/Cargo.toml \
	| sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/'

# Stamp what a build just made, in the directory the build hook reads it from.
# The hook prefers a local build over the released library, so it refuses one
# whose stamp is missing or names another crate version — and an upstream update
# moves the dependencies under an unchanged crate version, so it also compares
# the copy of the lock file left beside it with rust/Cargo.lock.
#
# Each `--target` in ARGS built one directory; with none, `$(1)` lists them. An
# Android ABI name is what cargo-ndk takes, and the directory is the triple. Only
# what this run built is stamped: an older build of another target has to go on
# being refused. So nothing is stamped when the build may have gone elsewhere —
# `--target-dir`, or cargo's own variables for the directory and the target —
# since a stale build where the hook looks would then pass for this one.
stamp_build = stamp() { \
		[ -d "rust/target/$$1" ] || return 0; \
		$(READ_CRATE_VERSION) > "rust/target/$$1/.crate-version"; \
		cp rust/Cargo.lock "rust/target/$$1/.cargo-lock"; \
	}; \
	if [ -n "$${CARGO_TARGET_DIR:-}$${CARGO_BUILD_TARGET:-}$${CARGO_NDK_TARGET:-}" ]; then \
		echo "Not stamped: CARGO_TARGET_DIR, CARGO_BUILD_TARGET or CARGO_NDK_TARGET is set, so the hook would not know this build."; \
		exit 0; \
	fi; \
	stamped=; set -- $(ARGS); \
	for arg in "$$@"; do \
		case "$$arg" in \
			--target-dir|--target-dir=*) \
				echo "Not stamped: --target-dir puts the build where the hook does not look."; \
				exit 0 ;; \
		esac; \
	done; \
	while [ $$\# -gt 0 ]; do \
		target=; \
		case "$$1" in \
			--target|-t) target="$$2"; shift ;; \
			--target=*) target="$${1\#--target=}" ;; \
		esac; \
		shift; \
		case "$$target" in \
			'') continue ;; \
			arm64-v8a) target=aarch64-linux-android ;; \
			armeabi-v7a) target=armv7-linux-androideabi ;; \
			x86_64) target=x86_64-linux-android ;; \
			x86) target=i686-linux-android ;; \
		esac; \
		stamp "$$target/release"; stamped=1; \
	done; \
	if [ -z "$$stamped" ]; then for dir in $(1); do stamp "$$dir"; done; fi

# The app the targets under "The example app" below work on: the example, or the
# new app `create-consumer` makes.
EXAMPLE_DIR ?= example

# The flutter `test-example` and `drive-example` run in it: `$(FVM) flutter`,
# unless `test-example-ci` hands in the app's own (see there).
EXAMPLE_FLUTTER ?= flutter

# Forget what was cached about this package's build hook, or the build just made
# may never be used. When the hook last ran without a local build it downloaded
# the released library and declared only rust/Cargo.toml — it cannot declare a
# library that does not exist yet, since hooks_runner re-runs a hook on every
# build for a missing dependency — so nothing it watches changes now, and `dart
# test`, `dart run` and an app's next build keep loading the download. The shared
# download cache stays. The example has a cache of its own, and Flutter a stamp
# above it that skips the hook altogether; `run-example-web` says more on that.
#
# ⚠ `install_code_assets.stamp` as well, and that one is not about a local build.
# Each build mode has its own stamps, and all of them install into one directory,
# build/native_assets/<os>/. Measured on 3.38.4 (3.47.4 no longer does it): a
# simulator build, then a device build, then the simulator build again skips the
# install and copies the DEVICE's library into the simulator app. Native builds keep
# their stamps under .dart_tool/flutter_build/, `flutter run -d chrome` under build/.
#
# The hook's target is `dart_build` up to Flutter 3.44, and `build_hooks` followed
# by `link_hooks` from 3.47 (flutter_tools' native_assets.dart): a name missed
# here is a stamp that survives, and then a hook that does not run again.
#
# ⚠ And Gradle's own record of an Android build, build/app/intermediates/flutter/,
# which sits above all of that. Gradle runs Flutter's build of the Dart half, and
# with it the hook, only when the inputs it was told of or the outputs it keeps
# there have changed. The hook's results are neither, so after a build with the
# same arguments Gradle reports the task UP-TO-DATE and nothing below runs: the
# app keeps the library it was built with, and nothing says which one that was.
# `make verify-example-library` then failed a run in which every test had passed,
# a profile run under `flutter drive` repeated after the try before it was killed;
# measured on 3.38.4 with two identical `flutter build apk --profile`. With the
# outputs gone the task runs again, a few seconds' work.
forget_hook_results = rm -rf .dart_tool/hooks_runner/openmls $(EXAMPLE_DIR)/.dart_tool/hooks_runner/openmls \
	$(EXAMPLE_DIR)/build/app/intermediates/flutter; \
	rm -f $(foreach dir,$(EXAMPLE_DIR)/build $(EXAMPLE_DIR)/.dart_tool/flutter_build, \
		$(foreach stamp,dart_build build_hooks link_hooks install_code_assets,$(dir)/*/$(stamp).stamp))

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
	@$(call stamp_build,release)
	@$(forget_hook_results)
	@echo ""
	@echo "Build complete! Library at: rust/target/"

# ARGS goes AFTER `build`, and that position is load-bearing rather than
# accidental. cargo-ndk's own options are recognised anywhere on the line —
# measured against 4.1.2: `--target arm64-v8a` placed after `build` is still
# consumed by cargo-ndk, which then builds that one ABI. Cargo's options are
# not: move ARGS before `build` and `make build-android ARGS="--features x"`
# dies on `error: unexpected argument '--features' found`. This position
# accepts both kinds; the other accepts only one.
build-android:
	@echo "Building Rust library for Android..."
	@PLATFORM=$$(dart scripts/get_android_min_sdk.dart) && \
		cd rust && cargo ndk --platform $$PLATFORM build --release $(ARGS)
	@$(call stamp_build,aarch64-linux-android/release armv7-linux-androideabi/release i686-linux-android/release x86_64-linux-android/release)
	@$(forget_hook_results)
	@echo ""
	@echo "Build complete! Library at: rust/target/<arch>/release/"

# The deployment target is what the release builds with, from the same answer
# `make check-targets` holds everything else to. Rust's own default for these
# targets is older than the C code Xcode compiles expects: `___chkstk_darwin`
# and the like, unavailable at link time. IOS_TARGETS is the list `rust-check-ios`
# below also uses.
build-ios:
	@echo "Building Rust library for iOS..."
	@DEPLOYMENT_TARGET=$$(sed -n "s/^ios_min_version: *'*\([0-9.]*\)'*/\1/p" .copier-answers.yml); \
		TARGETS="$(if $(filter --target --target=%,$(ARGS)),,$(foreach t,$(IOS_TARGETS),--target $(t)))"; \
		IPHONEOS_DEPLOYMENT_TARGET=$$DEPLOYMENT_TARGET cargo build --release --manifest-path rust/Cargo.toml $$TARGETS $(ARGS)
	@$(call stamp_build,$(foreach t,$(IOS_TARGETS),$(t)/release))
	@$(forget_hook_results)
	@echo ""
	@echo "Build complete! Library at: rust/target/<triple>/release/"

build-web:
	@echo "Building WASM for web..."
	cd rust && wasm-pack build --target no-modules --release \
		--out-dir target/wasm32 --out-name openmls_frb --no-typescript
	@rm -f rust/target/wasm32/.gitignore rust/target/wasm32/package.json
# Stamp the crate version beside the module. The build hook prefers this local
# build over the released one, so it needs a way to tell WHICH crate version
# produced it — and nothing else here can say. The files change on every
# rebuild and their timestamps move on a checkout or a stash, in both
# directions, so neither content nor mtime answers it. Without the stamp a
# wasm directory left over from an earlier version is served silently, and
# `rustContentHash` does not catch that: it hashes only the bridged functions'
# names, which a patch release leaves unchanged while replacing the native
# code behind them. The same first-`version` match the hook's own parser uses.
	@$(READ_CRATE_VERSION) > rust/target/wasm32/.crate-version
# And the lock file it was made from, which the hook compares with
# rust/Cargo.lock: the dependencies move without the crate version.
	@cp rust/Cargo.lock rust/target/wasm32/.cargo-lock
# The web path of the hook declares these files only while they exist, as the
# native path does its library, so a hook that last ran without them would not
# run again for them (see forget_hook_results).
	@$(forget_hook_results)
	@echo ""
	@echo "Build complete! WASM files at: rust/target/wasm32/ (crate $$(cat rust/target/wasm32/.crate-version))"

# Run the example app in a browser against a freshly built WASM module.
#
# The order is the whole point, and each step is there because skipping it has
# a failure mode:
#
#   1. `make build-web` first, because nothing else in this repository compiles
#      wasm32 on demand — running the app without it serves whatever was built
#      last, which can be a different commit's Rust.
#   2. `rm -rf example/web/pkg` next, so no copy left by an earlier build
#      survives to be served in place of the one just compiled.
#   3. `rm -f example/build/*/dart_build.stamp` — load-bearing, not hygiene.
#      `flutter run` keys its build directory on the engine revision, the
#      entrypoint, the build mode and the output path; the TARGET PLATFORM is
#      not part of that key, so a debug run for macOS and a debug run for
#      Chrome share one directory and therefore one `dart_build` stamp.
#      Whichever ran first leaves a stamp naming ITS dependencies — a `.dylib`,
#      not the wasm — Flutter finds every one of them unchanged, logs
#      `Skipping target: dart_build`, and the build hook is never invoked at
#      all. The hook cannot declare its way out of that: the skip happens above
#      `hooks_runner`, so nothing the hook declares is ever read. Together with
#      step 2 it turns a stale `web/pkg/` into a missing one, and `init()`
#      then throws a StateError for it — flutter_rust_bridge itself would
#      wait forever for `pkg/openmls_frb.js` to fire `load`, since the dev
#      server serves the app's HTML page in its place, with a 200. A
#      stamp that does not exist cannot be stale, and an unmatched glob is
#      a no-op under `rm -f`. Flutter 3.44 and later run build hooks per
#      target platform, outside that stamp, so the step matters on 3.38 to
#      3.41 only.
#   4. `flutter run -d chrome` last, and NOT `--wasm`: that flag compiles the
#      Dart half with dart2wasm, which flutter_rust_bridge's generated decoders
#      do not support. The Rust side is a wasm module either way.
#
# Pass flutter arguments through ARGS, e.g. ARGS="--web-port=5599".
run-example-web: build-web
	@rm -rf example/web/pkg
	@rm -f example/build/*/dart_build.stamp
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
# The example app: the package inside a real Flutter app
# =============================================================================

# Run example/integration_test/ on a device. `make test` runs the library on the
# Dart VM; this runs it inside an app, so it goes through what a consumer's build
# goes through: the build hook, the platform's way of bundling a library, the
# loader. Name the device, or Flutter asks which one:
#   make test-example ARGS="-d macos"
#   make test-example ARGS="-d <simulator or emulator id>"
#
# ⚠ WHICH LIBRARY IT LOADS is the build hook's choice, the same as in a consumer's
# app, with a local build first:
#   the host          `make build`             rust/target/release/
#   Android           `make build-android`     rust/target/<triple>/release/
#   iOS               `make build-ios`         rust/target/<triple>/release/
#   the web           `make build-web`         rust/target/wasm32/
# With none of those it downloads the release of the crate version in
# rust/Cargo.toml, which is how CI tests a release. A local build from another
# crate version or lock file stops the hook (HookException) rather than being
# loaded, so the failure you get is the instruction to rebuild. One from older
# Rust sources under the same version and lock file is loaded as it is: rebuild
# after changing rust/.
#
# `flutter test` forces debug mode. `drive-example` below is for the other modes.
test-example:
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) "$(EXAMPLE_FLUTTER)" test integration_test $(ARGS)

# The same tests under `flutter drive`, which is the one way to run them in
# profile mode: AOT, what a consumer's release build is compiled to. It needs a
# driver process and a device that has that mode, and an iOS simulator does not.
#   make drive-example ARGS="--profile -d macos"
example_drive = "$(EXAMPLE_FLUTTER)" drive --driver=test_driver/integration_test.dart \
	--target=integration_test/openmls_test.dart

drive-example:
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) $(example_drive) $(ARGS)

# Either of the two above, the way CI runs them on an emulator or a simulator:
# each run is judged on what the app reported. A test that failed fails this at
# once and is never run again; a run that never got that far (the app did not
# connect, the device or the connection went away) runs again, up to --attempts.
# An app that sends nothing for 8 minutes into its tests is stopped, and fails the
# run if it was still running on a device that answered. A run with no test
# started 5 minutes after flutter said the app was built, or 20 after it began
# when flutter never said so, is stopped as one that did not finish.
# scripts/test_example_ci.dart lists the options.
#   make test-example-ci ARGS="--attempts 3 -- -d <device>"
#   make test-example-ci ARGS="--drive -- --profile -d <device>"
#
# ⚠ The app's flutter is resolved here, by fvm in the app's directory, and handed
# in. The script runs under `fvm dart`, which puts this project's pinned Flutter
# first on PATH, and fvm cannot run again under it. So an app whose .fvmrc names
# another Flutter, as `create-consumer FLUTTER_VERSION=…` writes for the newest
# one, ran on the pinned one and stopped at its first `pub get`.
test-example-ci:
	@flutter=$$(cd $(EXAMPLE_DIR) && $(if $(FVM),$(FVM) exec )sh -c 'command -v flutter') && \
		$(FVM) dart scripts/test_example_ci.dart --dir $(EXAMPLE_DIR) --flutter "$$flutter" $(ARGS)

# Build the app with the tests as its entry point, without running it. CI uses it
# to build for an emulator before the emulator starts: the first Gradle build of an
# app is the heaviest, and the two together have been measured to exhaust a runner.
#   make build-example ARGS="apk --debug --target-platform android-x64"
build-example:
	cd $(EXAMPLE_DIR) && $(FVM) flutter build $(ARGS) --target integration_test/openmls_test.dart

# Run them in a real browser. This is the only target here that executes the DART
# half of the web build against the wasm module: `make test-web` runs the crate's
# own #[wasm_bindgen_test]s, `make build-web` only compiles, and `flutter test`
# cannot run integration tests on the web at all.
#
# NOT `--wasm`, for the reason `run-example-web` gives. `--release` is the dart2js
# build a consumer ships, which is a different compiler from the debug default:
#   make test-example-web ARGS="--release"
#
# Pass a chromedriver matching the browser, as for `test-web`; it is never
# downloaded. `example/web/pkg` goes first so what is served is what the hook
# provisioned just now.
CHROMEDRIVER_PORT ?= 4444

test-example-web:
	@driver="$(or $(CHROMEDRIVER),$(shell command -v chromedriver 2>/dev/null))"; \
	if [ -z "$$driver" ]; then \
		echo "No chromedriver: pass CHROMEDRIVER=/path/to/chromedriver, or put one on PATH."; \
		exit 1; \
	fi; \
	rm -rf $(EXAMPLE_DIR)/web/pkg; \
	$(forget_hook_results); \
	"$$driver" --port=$(CHROMEDRIVER_PORT) >/dev/null 2>&1 & driver_pid=$$!; \
	trap 'kill $$driver_pid 2>/dev/null' EXIT; \
	cd $(EXAMPLE_DIR) && $(FVM) $(example_drive) -d web-server --browser-name=chrome \
		--driver-port=$(CHROMEDRIVER_PORT) $(ARGS)

# Run them while measuring, then fail on a bridged function that none of them
# called. That is what keeps "every capability of the library" true as the library
# grows: a new function in rust/src/api/ without a test here turns this red. It
# only needs running on one platform, and CI runs it on Linux x86_64.
#   make coverage-example ARGS="-d macos"
coverage-example:
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) flutter test integration_test --coverage \
		--coverage-package='^openmls$$' $(ARGS)
	@$(FVM) dart scripts/verify_example_coverage.dart $(EXAMPLE_DIR)/coverage/lcov.info

verify-example-coverage:
	@$(FVM) dart scripts/verify_example_coverage.dart $(ARGS)

# Make what a new consumer of the published package has on day one: a fresh
# `flutter create` app with today's Flutter templates, depending on the version on
# pub.dev, with the example's app and tests copied in. Then run any target above on
# it, so that what is tested is the package archive and the released binaries, and
# nothing of this checkout but the tests:
#   make create-consumer VERSION=9.0.0
#   make test-example EXAMPLE_DIR=build/consumer ARGS="-d macos"
#
# The tests are this checkout's, so they must not be newer than the version: a test
# can call what was released after it. For an older version, check its tag out
# first, as the weekly CI run does.
#
# The project is named as the example is, because the tests import it by that name.
# Under build/, which git and the published package both ignore. FVM finds .fvmrc
# from there, so it runs on the pinned Flutter; FLUTTER_VERSION gives the new app a
# .fvmrc of its own, and everything that runs in it then uses that one, `flutter
# create` included, while this repository's tooling stays on the pin:
#   make create-consumer VERSION=9.0.0 FLUTTER_VERSION=3.47.9
#
# `--sdk` rather than a descriptor: on Windows the command goes through cmd, which
# takes the JSON apart, and the descriptor's form changed between Flutter 3.38
# (`name:{...}`) and 3.47 (`name@{...}`). `--sdk` is hidden from `pub add --help`
# on both, and works on both.
CONSUMER_DIR ?= build/consumer

create-consumer:
	@[ -n "$(VERSION)" ] || { echo "Usage: make create-consumer VERSION=X.Y.Z"; exit 1; }
	@rm -rf $(CONSUMER_DIR)
	@mkdir -p $(CONSUMER_DIR)
	$(if $(FLUTTER_VERSION),$(FVM) install $(FLUTTER_VERSION))
	$(if $(FLUTTER_VERSION),@printf '{"flutter": "%s"}\n' "$(FLUTTER_VERSION)" > $(CONSUMER_DIR)/.fvmrc)
	cd $(CONSUMER_DIR) && $(FVM) flutter create --no-pub --project-name openmls_example \
		--org com.openmls --platforms=android,ios,linux,macos,windows,web .
	@rm -rf $(CONSUMER_DIR)/lib $(CONSUMER_DIR)/test
	@cp -R example/lib example/integration_test example/test_driver $(CONSUMER_DIR)/
	cd $(CONSUMER_DIR) && $(FVM) flutter pub add openmls:$(VERSION)
	cd $(CONSUMER_DIR) && $(FVM) flutter pub add dev:integration_test --sdk=flutter
	cd $(CONSUMER_DIR) && $(FVM) flutter pub add dev:flutter_driver --sdk=flutter

# Build the release app for what no hosted runner can run, and check its native
# library is in there. It proves those release binaries download, verify and
# bundle; it cannot prove they work.
#
# Android: an APK with every ABI, and each library's ELF segments 16 KB aligned,
# read from the copy inside the APK (not the APK's own zip alignment). Apple: each
# build with its architectures, and the platform read from the library's header,
# since a device and a simulator library share an architecture.
check_apple_library = library=$(1); \
	lipo "$$library" -verify_arch $(2) || { echo "$$library lacks one of: $(2)"; lipo -archs "$$library"; exit 1; }; \
	platforms=$$(vtool -show-build "$$library" | awk '/platform/ {print $$2}' | sort -u); \
	if [ "$$platforms" != "$(3)" ]; then echo "$$library is for $$platforms, not $(3)"; exit 1; fi; \
	echo "$$library: $(2), $(3)"

package-example-android:
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) flutter build apk --release
	@rm -rf $(EXAMPLE_DIR)/build/apk-libs
	@unzip -q $(EXAMPLE_DIR)/build/app/outputs/flutter-apk/app-release.apk \
		'lib/*/libopenmls_frb.so' -d $(EXAMPLE_DIR)/build/apk-libs
	@python3 scripts/verify_android_alignment.py \
		$(foreach abi,arm64-v8a armeabi-v7a x86_64,$(EXAMPLE_DIR)/build/apk-libs/lib/$(abi)/libopenmls_frb.so)

package-example-ios:
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) flutter build ios --release --no-codesign
	@$(call check_apple_library,$(EXAMPLE_DIR)/build/ios/iphoneos/Runner.app/Frameworks/openmls_frb.framework/openmls_frb,arm64,IOS)
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) flutter build ios --simulator --debug
	@$(call check_apple_library,$(EXAMPLE_DIR)/build/ios/iphonesimulator/Runner.app/Frameworks/openmls_frb.framework/openmls_frb,arm64 x86_64,IOSSIMULATOR)

package-example-macos:
	@$(forget_hook_results)
	cd $(EXAMPLE_DIR) && $(FVM) flutter build macos --release
	@$(call check_apple_library,$$(ls -d $(EXAMPLE_DIR)/build/macos/Build/Products/Release/*.app)/Contents/Frameworks/openmls_frb.framework/openmls_frb,arm64 x86_64,MACOS)

# Check that the app the tests ran in loaded the library the run says it tests.
# The hook chooses, and it can choose quietly: a run meant to test this tree that
# ended up downloading the release goes green over code the tree has replaced.
# Run it after the tests.
#   make verify-example-library ARGS="--built"
#   make verify-example-library ARGS="--released --web"
verify-example-library:
	@$(FVM) dart scripts/verify_example_library.dart --dir $(EXAMPLE_DIR) $(ARGS)

# =============================================================================
# Rust Quality
# =============================================================================

rust-check:
	cargo check --manifest-path rust/Cargo.toml

# Type-check the crate for the three iOS targets the release builds. Nothing
# before a release tag compiled iOS at all until this target: libc 0.2.190 put
# the dyld functions `backtrace` calls behind `target_os = "macos"`, every iOS
# build failed with E0425, and every pull request stayed green. `cargo check`
# catches compile errors like that one, not link errors. Needs the targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
IOS_TARGETS = aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rust-check-ios:
	@for t in $(IOS_TARGETS); do \
		echo "cargo check --locked --target $$t"; \
		cargo check --locked --manifest-path rust/Cargo.toml --target $$t || exit 1; \
	done

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

# The same lint over the OTHER half of the crate, and a second gate rather than
# a thoroughness setting.
#
# `make rust-clippy` above runs under the HOST target, and that is not a matter
# of degree: a `cfg(target_arch = "wasm32")` body is a DIFFERENT IMPLEMENTATION
# of the same function, so the host pass reads none of its lines. Without this
# target the wasm32 half of the crate is linted by nothing — not locally and
# not in CI — while the green from the host pass reads as if it were.
# `make rust-doc` already runs a second leg under wasm32 for exactly this
# reason; this is its counterpart for lints.
#
# ⚠ `cd rust`, NOT --manifest-path, for the same reason rust-doc gives below:
# cargo discovers .cargo/config.toml relative to the CWD, so invoking this from
# the repository root silently drops rust/.cargo/config.toml — the file
# carrying the wasm32 rustflags — and the lint then runs over a configuration
# the crate never builds under. Measured: the two forms differ in what they
# compile, not merely in where the paths in the output start.
#
# The wasm32 target comes from `make setup-web`.
rust-clippy-web:
	cd rust && cargo clippy --target wasm32-unknown-unknown --all-targets -- -D warnings

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

# The workflows are the one part of this repository that nothing else
# rehearses: a job is only executed by pushing it, so a typo in an expression, a
# context that does not exist, or a `needs:` naming a job somebody renamed all
# reach main and then fail on the very run that was supposed to gate them.
# actionlint reads them statically, and shells out to shellcheck for every
# `run:` block — which is where most of what it finds actually lives, so a
# missing shellcheck quietly makes this a weaker check than it looks.
#
# Suppressions live in `.github/actionlint.yaml`, not in flags here, so this
# and a bare `actionlint` report the same thing.
actionlint:
	@command -v actionlint >/dev/null 2>&1 || { \
		echo "actionlint not found. Install it (brew install actionlint) or take a"; \
		echo "release from https://github.com/rhysd/actionlint/releases — CI pins 1.7.12."; \
		exit 1; \
	}
	@command -v shellcheck >/dev/null 2>&1 || \
		echo "warning: shellcheck not found — actionlint will skip every run: block."
	@actionlint $(ARGS)

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
	cp rust/Cargo.lock rust/fuzz/Cargo.lock
	cd rust && cargo +nightly fuzz run $(ARGS)

# Generate the seed corpus (valid inputs) under rust/fuzz/corpus/<target>/.
# Extend rust/fuzz/examples/gen_corpus.rs as you add fuzz targets.
#
# Both targets give the fuzz crate the crate's own lock file first: it is not
# a member of the crate's workspace and keeps no lock of its own (rust/fuzz/
# ignores it), so it would otherwise resolve every shared dependency to its
# newest version and fuzz parsers other than the ones that ship. Cargo adds
# the fuzz-only crates to the copy.
fuzz-seed:
	cp rust/Cargo.lock rust/fuzz/Cargo.lock
	cd rust/fuzz && cargo run --release --example gen_corpus

# =============================================================================
# CI / Version Checks
# =============================================================================

check-new-openmls-version:
	@$(FVM) dart scripts/check_new_upstream_version.dart $(ARGS)

# openmls/openmls's published security advisories, held against the crates
# rust/Cargo.lock resolves: neither rust-audit (RustSec) nor Dependabot
# (GitHub's global database) is guaranteed to see them. Run daily by
# check-openmls-updates.yml. Exits 1 when one covers a locked
# version, 2 when they could not be fetched — which make reports as 2 either way.
check-upstream-advisories:
	@$(FVM) dart scripts/check_upstream_advisories.dart $(ARGS)

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

# The minimum Rust version: rust/Cargo.toml, the rust_version answer and the
# docs, against the highest floor a crate of the resolved graph declares.
# `--update` raises them all; the update workflow runs it after rust-update.
check-msrv:
	@$(FVM) dart scripts/check_msrv.dart $(ARGS)

# What an upstream update changed, in one directory: the release notes, the
# upstream range and its patches, the lockfile diff, and the range of every git
# dependency from another repository that moved. The update workflow uploads it
# with the pull request; the build repair reads it. Evidence, not a gate.
update-evidence:
	@$(FVM) dart scripts/update_evidence.dart $(ARGS)

# Regenerate the third-party notice inventory for the shipped native library.
# Run after any dependency change; CI verifies the committed file matches.
third-party-notices:
	@$(FVM) dart scripts/generate_third_party_notices.dart $(ARGS)

verify-third-party-notices:
	@$(FVM) dart scripts/generate_third_party_notices.dart --check

# Six files can record the flutter_rust_bridge version and the runtime asserts
# two of them are equal, so a disagreement ships as a package that throws on
# init. File reads only — no build, no network.
verify-frb-pins:
	@$(FVM) dart scripts/verify_frb_pins.dart $(ARGS)

# pub.dev refuses a README.md, CHANGELOG.md, LICENSE or example over 256 KiB
# and a pubspec.yaml over 128 KiB — at UPLOAD, after the tag, when the version
# is already spent. `dart pub publish --dry-run` measures none of them, which is
# why publish-dry-run runs this first. A CHANGELOG crosses the line by growing,
# so CI runs it on every push too, and warns from 200 KiB. File sizes only — no
# build, no network.
verify-pub-limits:
	@$(FVM) dart scripts/verify_pub_limits.dart $(ARGS)

# `rust/Cargo.toml` states which features THIS crate asks for; it cannot state
# which features a dependency is ultimately BUILT with. Cargo unifies features
# across the graph, so a dependency added transitively — in a version bump
# nobody here reviewed — can turn one on for a crate this manifest never
# mentions. A comment in the manifest is a statement of intent that nothing
# enforces, and this is the enforcement.
#
# ⚠ Keyed by CRATE, not a flat list of feature names: the same name is usually
# legitimate on a neighbouring crate, so a flat list is red on a healthy tree.
#
# Resolves without compiling, so it is cheap enough to gate every push.
verify-feature-graph:
	@$(FVM) dart scripts/verify_feature_graph.dart $(ARGS)

# Google Play has required an app's bundled native libraries to be 16 KB-aligned,
# for apps targeting Android 15 or later, since 1 November 2025 — and the
# alignment is supplied by cargo-ndk's linker flags, not by the NDK and not by
# anything in this source. That makes it a property of the TOOL, held by a
# version pin that nothing bumps automatically, so it is measured here on the
# built artefacts rather than assumed. Reads ELF program headers only — no
# build, no network. Run it after `make build-android`; with no ARGS it checks
# every Android library present and fails when there are none.
verify-android-alignment:
	@python3 scripts/verify_android_alignment.py $(ARGS)

# Refuse a release archive that does not hold what its name says it holds. The
# build workflow ends in a hand-written list of `tar` lines, one per platform,
# and nothing checks that each names the directory it means to — a slip there
# is invisible until a consumer downloads their platform's archive and gets
# somebody else's library.
#
# ⚠ Checking the ARCHITECTURE is not enough, which is the whole reason this
# parses headers instead of calling `file`: a Linux arm64 and an Android arm64
# `.so` share an ELF header, and a macOS, an iOS and an iOS-simulator `.dylib`
# share a Mach-O cputype. Those are exactly the pairs a copy-paste slip
# produces. It reads the libc in DT_NEEDED and the platform in
# LC_BUILD_VERSION, which do tell them apart.
#
# Takes the directory as ARGS — either release archives or the tree
# `download-artifact` unpacked. The release workflow runs it over both.
verify-release-artifacts:
	@python3 scripts/verify_release_artifacts.py --crate-name openmls_frb $(ARGS)

# Load a built native library and look up one symbol. Small, and it covers the
# failure every other check here is blind to: a library that compiles, packs,
# checksums and attests, and then does not load.
#
# `ctypes.CDLL` is the check — loading runs the library's initialisers,
# resolves its dependencies and refuses a wrong architecture. The symbol is
# `frb_init_frb_dart_api_dl`, which flutter_rust_bridge exports from its own
# runtime rather than from generated code, so a library without it is not an
# FRB library whatever else it is.
#
# ⚠ Only on a host that IS the target: a cross-compiled artefact cannot be
# loaded by the machine that built it. The release workflow runs this on the
# legs whose runner matches, and nowhere else.
verify-library-loads:
	@python3 scripts/verify_library_loads.py $(ARGS)

# Updating the lockfile changes the dependency graph, which invalidates the
# third-party notice inventory. Regenerating here keeps the two in lockstep
# both locally and in the scheduled update workflow (which calls this target),
# so nobody has to remember a second command before CI rejects the branch.
#
# `--workspace`: re-resolve what rust/Cargo.toml asks for and nothing more.
# After the update bot moves the upstream tag, that is the upstream crates and
# whatever their new versions actually require. A bare `cargo update` moved
# every crate in the lockfile besides. Measured in a generated project: 41
# registry crates over its last four upstream bumps, none of them required by
# the new tag, and twice that broke a platform no bump had touched —
# wasm-bindgen 0.2.113 under FRB 2.11.1, and libc 0.2.190 on iOS, which also
# undid the hold put there for it. The rest of the graph moves in Dependabot's
# weekly cargo pull request instead, on its own CI run
# (`.github/dependabot.yml`). A first lockfile is still built in full.
rust-update:
	@echo "Updating Cargo.lock..."
	@cd rust && cargo update --workspace
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

# ARGS reaches `dart pub get`, so the other packages in this repository can be
# resolved too — `make get ARGS="--directory=example_cli"`, which
# `make analyze ARGS="example_cli"` needs on a fresh checkout. Before ARGS was
# passed through, that call resolved the root package instead, and said
# nothing. No target depends on `get`, so no other target's ARGS reach it.
get:
	@touch .skip_openmls_hook
	@$(FVM) dart pub get --no-example $(ARGS); ret=$$?; rm -f .skip_openmls_hook; exit $$ret

clean:
	rm -rf .dart_tool build rust/target \
		example/.dart_tool example/build example/coverage example/web/pkg
	@touch .skip_openmls_hook
	@$(FVM) dart pub get --no-example; ret=$$?; rm -f .skip_openmls_hook; exit $$ret

# What Flutter makes of this machine: which toolchains it finds, and which devices.
doctor:
	$(FVM) flutter doctor -v
	$(FVM) flutter devices

version:
	@$(FVM) dart scripts/get_version.dart

# Internal target for getting version in scripts (outputs only the value)
get-version:
	@$(FVM) dart scripts/get_version.dart --field version

# =============================================================================
# Publishing
# =============================================================================

publish-dry-run: verify-pub-limits
	$(FVM) dart pub publish --dry-run

publish:
ifndef CI
	@echo ""
	@echo "ERROR: Local publishing is disabled."
	@echo ""
	@echo "This package uses automated publishing via GitHub Actions."
	@echo "To publish a new version, once the native crate is released (stage 1):"
	@echo ""
	@echo '  make release ARGS="--version X.Y.Z"'
	@echo ""
	@echo "It verifies the stage-1 release, bumps pubspec.yaml, finalizes"
	@echo "CHANGELOG.md and pushes a signed vX.Y.Z tag, which starts"
	@echo "publish.yml. Do not tag by hand: that skips those checks."
	@echo ""
	@echo "To validate the package locally, use: make publish-dry-run"
	@echo ""
	@exit 1
else
	$(FVM) dart pub publish $(ARGS)
endif
