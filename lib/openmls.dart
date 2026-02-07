/// Dart wrapper for OpenMLS — a Rust implementation of the Messaging Layer Security (MLS) protocol (RFC 9420)
///
/// This is the main entry point for openmls.
///
/// ## Getting Started
///
/// Add this package to your `pubspec.yaml`:
///
/// ```yaml
/// dependencies:
///   openmls: ^1.0.0
/// ```
///
/// Native libraries are downloaded automatically during build via Dart Build Hooks.
///
/// ## Usage
///
/// ```dart
/// import 'package:openmls/openmls.dart';
///
/// void main() async {
///   await Openmls.init();
///   // ... use openmls APIs
/// }
/// ```
///
/// ## Platform Support
///
/// - Linux (x86_64, arm64)
/// - macOS (arm64, x86_64)
/// - Windows (x86_64)
/// - Android (arm64-v8a, armeabi-v7a, x86_64)
/// - iOS (device arm64, simulator arm64/x86_64)
/// - Web (WASM)

library;

// Core initialization
export 'src/openmls.dart';

// FRB-generated API (uncomment after running `make codegen`)
// export 'src/rust/api/greeting.dart';

// Export your custom Dart wrappers
// export 'src/api.dart';
