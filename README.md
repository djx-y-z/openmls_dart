# openmls - MLS Protocol for Dart

[![pub package](https://img.shields.io/pub/v/openmls.svg)](https://pub.dev/packages/openmls)
[![CI](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml/badge.svg)](https://github.com/djx-y-z/openmls_dart/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.10.0-brightgreen.svg)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/flutter-%3E%3D3.38.0-blue.svg)](https://flutter.dev)
[![openmls](https://img.shields.io/badge/openmls-v0.8.0-orange.svg)](https://github.com/openmls/openmls)

Dart bindings for [OpenMLS](https://github.com/openmls/openmls), providing a Rust implementation of the Messaging Layer Security (MLS) protocol ([RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)) for secure group messaging.

## Platform Support

|             | Android | iOS   | macOS  | Linux      | Windows | Web |
|-------------|---------|-------|--------|------------|---------|-----|
| **Support** | SDK 24+ | 12.0+ | 10.14+ | arm64, x64 | x64     | ✓   |
| **Arch**    | arm64, armv7, x64 | arm64 | arm64, x64 | arm64, x64 | x64 | wasm32 |

## Features

- **Flutter & CLI Support**: Works with Flutter apps and standalone Dart CLI applications
- **MLS Protocol (RFC 9420)**: Secure group messaging with forward secrecy and post-compromise security
- **Group Key Agreement**: Efficient tree-based group key agreement (TreeKEM)
- **Automatic Builds**: Native libraries downloaded automatically via build hooks
- **High Performance**: Direct Rust integration via Flutter Rust Bridge

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  openmls: ^x.x.x
```

Native libraries are downloaded automatically during build via Dart build hooks.

**No Rust required** for end users - precompiled binaries are downloaded from GitHub Releases.

## Usage

```dart
import 'package:openmls/openmls.dart';

void main() async {
  // Initialize the library
  await OpenMls.init();

  // TODO: Add MLS group messaging example
}
```

## Building from Source

### For End Users

**No setup required!** Precompiled native libraries are downloaded automatically from GitHub Releases during `flutter build`.

### For Contributors / Source Builds

If you want to build from source (or precompiled binaries are not available):

- [Flutter](https://flutter.dev/) 3.38+
- [FVM](https://fvm.app/) (optional, for version management)
- **Rust toolchain** (1.88+):
  - [rustup](https://rustup.rs/) - Rust toolchain installer
  - `cargo` - Rust package manager (installed with rustup)

### Setup

```bash
# Clone the repository
git clone https://github.com/djx-y-z/openmls_dart.git
cd openmls_dart

# Install FVM and dependencies
make setup

# Generate Dart bindings
make codegen

# Build native library
make build

# Run tests
make test

# See all available commands
make help
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│          OpenMLS (Rust crate)                    │  ← Core MLS implementation
├─────────────────────────────────────────────────┤
│       rust/src/api/*.rs (Rust wrappers)         │  ← FRB-annotated functions
├─────────────────────────────────────────────────┤
│      lib/src/rust/*.dart (FRB generated)        │  ← Auto-generated Dart API
├─────────────────────────────────────────────────┤
│           Your Dart application code            │  ← Uses the API
└─────────────────────────────────────────────────┘
```

## Acknowledgements

This library would not be possible without [OpenMLS](https://github.com/openmls/openmls), which provides the underlying Rust implementation of the MLS protocol.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and reporting vulnerabilities.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Related Projects

- [OpenMLS](https://github.com/openmls/openmls) - The underlying Rust MLS library
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) - The Messaging Layer Security (MLS) Protocol
- [Flutter Rust Bridge](https://cjycode.com/flutter_rust_bridge/) - Dart/Flutter <-> Rust binding generator
