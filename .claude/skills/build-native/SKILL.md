---
name: build-native
description: Build openmls native libraries for different platforms. Use when user asks about building, compiling, or creating native libraries for iOS, Android, macOS, Linux, or Windows.
---

# Build Native Libraries

Help with building the `openmls_frb` native library for all supported platforms.

## Golden Rule

**ALWAYS use Makefile commands. Never call cargo/scripts directly.**

```bash
# CORRECT
make build ARGS="--target aarch64-apple-darwin"

# WRONG - never do this
cd rust && cargo build --release
```

## Quick Reference

| Command | What it builds | Output |
|---------|----------------|--------|
| `make build` | Current host platform (release) | `rust/target/release/` |
| `make build ARGS="--target <rust-target>"` | Specific Rust target | `rust/target/<target>/release/` |
| `make build-android` | All Android ABIs via cargo-ndk | `rust/target/<target>/release/` |
| `make build-android ARGS="--target arm64-v8a"` | One Android ABI | `rust/target/<target>/release/` |
| `make build-web` | WASM via wasm-pack | `rust/target/wasm32/` |

The library artifact is `libopenmls_frb.{dylib,so}` / `openmls_frb.dll`
(web: `openmls_frb.js` + `openmls_frb_bg.wasm`).

There is no per-platform packaging step in this repo: consumers get precompiled
binaries from the GitHub Release `openmls_frb-<version>` via `hook/build.dart`
(see `build-openmls.yml` for the CI build matrix). To make a local build
visible to the hook, create a `.skip_openmls_hook` marker (see the header of
`hook/build.dart`).

## Deployment Targets

Minimum OS versions are sourced from `.copier-answers.yml` and enforced with
`make check-targets`. CI sets them via `IPHONEOS_DEPLOYMENT_TARGET`,
`MACOSX_DEPLOYMENT_TARGET` and cargo-ndk `--platform`; `make build-android`
reads the Android minSdk via `scripts/get_android_min_sdk.dart`.

## Prerequisites

| Platform | Requirements |
|----------|--------------|
| All | Rust toolchain (rustup, cargo), FVM |
| macOS / iOS | Xcode Command Line Tools (iOS: full Xcode) |
| Android | Android NDK + `cargo-ndk` (`make setup-android`) |
| Web | `wasm-pack` (`make setup-web`) |
| Windows | Visual Studio with C++ |
| Linux | gcc/g++, cross-compilation tools for arm64 |

## Rust Targets

| Platform | Rust Target |
|----------|-------------|
| Linux x86_64 | `x86_64-unknown-linux-gnu` |
| Linux arm64 | `aarch64-unknown-linux-gnu` |
| macOS arm64 | `aarch64-apple-darwin` |
| macOS x86_64 | `x86_64-apple-darwin` |
| iOS device | `aarch64-apple-ios` |
| iOS simulator arm64 | `aarch64-apple-ios-sim` |
| iOS simulator x86_64 | `x86_64-apple-ios` |
| Android arm64 | `aarch64-linux-android` |
| Android arm | `armv7-linux-androideabi` |
| Android x86_64 | `x86_64-linux-android` |
| Windows | `x86_64-pc-windows-msvc` |
| Web | `wasm32-unknown-unknown` |

## Troubleshooting

### "cargo not found"
```bash
# Install Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### "NDK not found" (Android)
```bash
# Check current NDK
echo $ANDROID_NDK_HOME

# Common paths
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/28.2.13676358
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/28.2.13676358
```

### Build fails on Windows
- Ensure you're in "Developer PowerShell for VS"
- Or run `vcvars64.bat` first
- CI workaround: Remove Git's link.exe from PATH (conflicts with MSVC)

## Other Useful Commands

```bash
# Full setup (installs all dependencies)
make setup

# Regenerate FRB bindings after Rust API changes
make codegen

# Show current crate version
make version
```
