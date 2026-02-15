# openmls - Makefile
# Cross-platform build and development commands for Flutter Rust Bridge package
#
# Usage: make <target> [ARGS="..."]
# Example: make build ARGS="--target x86_64-unknown-linux-gnu"
# Example: make analyze ARGS="--fatal-infos"
#
# On Windows CI (Git Bash), use cmd to run fvm.bat from PATH:
# Example: make build ARGS="--target x86_64-pc-windows-msvc" FVM="cmd //c fvm"

.PHONY: help setup setup-fvm setup-rust-tools setup-android setup-web codegen regen build build-android build-web test coverage analyze format format-check get clean version check-new-openmls-version check-exists-openmls-frb-release check-template-updates check-targets rust-audit rust-check doc publish publish-dry-run rust-update update-changelog

# FVM command - can be overridden to provide full path on Windows CI
FVM ?= fvm

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
	@echo "    make setup-android                - Install Android build tools (cargo-ndk)"
	@echo "    make setup-web                    - Install web build tools (wasm-pack)"
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
	@echo "    make check-targets                - Check deployment target consistency (iOS/macOS/Android)"
	@echo "                                        Example: make check-targets ARGS=\"--ios --set 14.0\""
	@echo "    make rust-update                  - Update Cargo.lock (cargo update)"
	@echo "    make update-changelog             - Update CHANGELOG.md with AI"
	@echo "                                        Example: make update-changelog ARGS=\"--version v1.0.0\""
	@echo ""
	@echo "  RUST QUALITY"
	@echo "    make rust-check                   - Check Rust code compiles"
	@echo "    make rust-audit                   - Audit Rust dependencies for vulnerabilities"
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
	@if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then \
		echo "Installing flutter_rust_bridge_codegen..."; \
		cargo install flutter_rust_bridge_codegen; \
	else \
		echo "flutter_rust_bridge_codegen already installed"; \
	fi
	@echo ""
	@echo "Rust tools setup complete!"

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

rust-audit:
	cargo audit --file rust/Cargo.lock

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

rust-update:
	@echo "Updating Cargo.lock..."
	@cd rust && cargo update
	@echo ""
	@echo "Cargo.lock updated!"

update-changelog:
	@$(FVM) dart scripts/update_changelog.dart $(ARGS)

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
