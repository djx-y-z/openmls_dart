# openmls - Makefile
# Cross-platform build and development commands for Flutter Rust Bridge package
#
# Usage: make <target> [ARGS="..."]
# Example: make build ARGS="--target x86_64-unknown-linux-gnu"
# Example: make analyze ARGS="--fatal-infos"
#
# On Windows CI (Git Bash), use cmd to run fvm.bat from PATH:
# Example: make build ARGS="--target x86_64-pc-windows-msvc" FVM="cmd //c fvm"

.PHONY: help setup setup-fvm setup-rust-tools setup-frb-codegen setup-android setup-web setup-fuzz codegen regen build build-android build-web test coverage analyze format format-check get clean version check-new-openmls-version check-exists-openmls-frb-release check-template-updates check-targets third-party-notices verify-third-party-notices rust-audit rust-deny rust-check rust-test rust-clippy fuzz fuzz-list fuzz-seed doc publish publish-dry-run rust-update update-changelog release-frb release setup-repo-protections

# FVM command - can be overridden to provide full path on Windows CI
FVM ?= fvm

# Pinned flutter_rust_bridge_codegen version.
# Must match the flutter_rust_bridge dependency in pubspec.yaml — a codegen
# binary of a different version produces different bindings, which makes CI
# and local codegen runs disagree.
FRB_CODEGEN_VERSION ?= 2.12.0

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
	@echo ""
	@echo "  CI / VERSION CHECKS"
	@echo "    make check-new-openmls-version  - Check for new upstream openmls version"
	@echo "                                        Example: make check-new-openmls-version ARGS=\"--update\""
	@echo "    make check-exists-openmls-frb-release - Check if FRB release exists on GitHub"
	@echo "    make check-template-updates       - Check for new copier template version"
	@echo "    make third-party-notices          - Regenerate THIRD_PARTY_NOTICES.txt from the dep graph"
	@echo "    make verify-third-party-notices   - Verify THIRD_PARTY_NOTICES.txt is up to date"
	@echo "    make check-targets                - Check deployment target consistency (iOS/macOS/Android)"
	@echo "                                        Example: make check-targets ARGS=\"--ios --set 14.0\""
	@echo "    make rust-update                  - Update Cargo.lock (cargo update)"
	@echo "    make update-changelog             - Update CHANGELOG.md with AI"
	@echo "                                        Example: make update-changelog ARGS=\"--version v1.0.0\""
	@echo ""
	@echo "  RUST QUALITY"
	@echo "    make rust-check                   - Check Rust code compiles"
	@echo "    make rust-test                    - Run Rust unit tests"
	@echo "    make rust-clippy                  - Lint Rust code with clippy (warnings = errors)"
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
	@echo "    make doc                          - Generate API documentation"
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
		cargo install cargo-audit; \
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

codegen:
	@touch .skip_openmls_hook
	@flutter_rust_bridge_codegen generate $(ARGS); ret=$$?; rm -f .skip_openmls_hook; exit $$ret

# Alias for codegen (common shorthand)
regen: codegen

# =============================================================================
# Build
# =============================================================================

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

check-targets:
	@$(FVM) dart scripts/check_deployment_targets.dart $(ARGS)

# Regenerate the third-party notice inventory for the shipped native library.
# Run after any dependency change; CI verifies the committed file matches.
third-party-notices:
	@$(FVM) dart scripts/generate_third_party_notices.dart $(ARGS)

verify-third-party-notices:
	@$(FVM) dart scripts/generate_third_party_notices.dart --check

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

coverage:
	$(FVM) dart test --coverage=coverage
	$(FVM) dart run coverage:format_coverage --check-ignore --lcov --in=coverage --out=coverage/lcov.info --report-on=lib --ignore-files '**/frb_generated*.dart'
	lcov --summary coverage/lcov.info

analyze:
	$(FVM) flutter analyze $(ARGS)

format:
	$(FVM) dart format . $(ARGS)

format-check:
	$(FVM) dart format --set-exit-if-changed . $(ARGS)

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
