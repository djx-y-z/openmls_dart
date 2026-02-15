---
name: build-native
description: Build openmls native libraries for different platforms. Use when user asks about building, compiling, or creating native libraries for iOS, Android, macOS, Linux, or Windows.
---

# Build Native Libraries

Help with building openmls native libraries for all supported platforms.

## Golden Rule

**ALWAYS use Makefile commands. Never call scripts directly.**

```bash
# CORRECT
make build ARGS="macos"

# WRONG - never do this
fvm dart scripts/build.dart macos
```

## Quick Reference

| Platform | Command | Output |
|----------|---------|--------|
| macOS | `make build ARGS="macos"` | `bin/macos/` |
| Linux | `make build ARGS="linux"` | `bin/linux/` |
| Windows | `make build ARGS="windows"` | `bin/windows/` |
| iOS | `make build ARGS="ios"` | `ios/Frameworks/` or `ios/Libraries/` |
| Android | `make build ARGS="android"` | `android/src/main/jniLibs/` |
| All | `make build ARGS="all"` | All platforms |
| List | `make build ARGS="list"` | Show available platforms |

## Platform-Specific Options

### macOS

```bash
# Universal binary (arm64 + x86_64) - default
make build ARGS="macos"

# Specific architecture
make build ARGS="macos --arch arm64"
make build ARGS="macos --arch x86_64"
```

### iOS

```bash
# Full XCFramework (device + simulators) - default
make build ARGS="ios"

# Specific targets
make build ARGS="ios --target device"
make build ARGS="ios --target simulator"
make build ARGS="ios --target simulator-arm64"
make build ARGS="ios --target simulator-x86_64"
```

### Android

```bash
# All ABIs - default
make build ARGS="android"

# Specific ABI
make build ARGS="android --abi arm64-v8a"
make build ARGS="android --abi armeabi-v7a"
make build ARGS="android --abi x86_64"
```

**Android NDK Setup:**
```bash
export ANDROID_NDK_HOME=/path/to/ndk/26.3.11579264
# Or install via Android Studio SDK Manager
```

### Windows

```bash
make build ARGS="windows"
```

**Requirements:** Run from "Developer PowerShell for VS" or after `vcvars64.bat`

## Prerequisites

| Platform | Requirements |
|----------|--------------|
| All | Rust toolchain (rustup, cargo), FVM |
| Linux | gcc/g++, cross-compilation tools for arm64 |
| macOS | Xcode Command Line Tools |
| iOS | Xcode (full) |
| Android | Android NDK |
| Windows | Visual Studio with C++ |

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

## Troubleshooting

### "cargo not found"
```bash
# Install Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### "cbindgen not found"
```bash
cargo install cbindgen
```

### "protoc not found"
```bash
# macOS
brew install protobuf

# Linux
sudo apt install protobuf-compiler

# Windows
choco install protoc
```

### "NDK not found" (Android)
```bash
# Check current NDK
echo $ANDROID_NDK_HOME

# Common paths
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/26.3.11579264
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/26.3.11579264
```

### Build fails on Windows
- Ensure you're in "Developer PowerShell for VS"
- Or run `vcvars64.bat` first
- CI workaround: Remove Git's link.exe from PATH (conflicts with MSVC)

## Other Useful Commands

```bash
# Full setup (installs all dependencies)
make setup

# Just FVM/Flutter setup
make setup-fvm

# Build dependencies only (Rust, protoc)
make setup-build

# Regenerate FFI bindings after native library update
make codegen

# Show current openmls version
make version
```
