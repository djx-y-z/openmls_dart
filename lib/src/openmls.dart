/// Main entry point for the openmls library.
///
/// Provides initialization, version information, and high-level API access.
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'platform/platform.dart' as platform;
import 'rust/frb_generated.dart';

/// Native asset ID for the openmls library.
/// Format: package:openmls/openmls
///
/// When the build hook registers a CodeAsset with this ID,
/// Dart allows loading it via DynamicLibrary.open() with this ID.
const _nativeAssetId = 'package:openmls/openmls';

/// Main API class for openmls.
///
/// Use [Openmls.init] to initialize the library before using any
/// operations.
///
/// ```dart
/// void main() async {
///   await Openmls.init();
///   // ... use openmls APIs
/// }
/// ```
///
/// ## Library Loading
///
/// The native library is loaded automatically based on the platform:
///
/// ### For Native Platforms (iOS, Android, macOS, Linux, Windows)
///
/// 1. **Custom path** (if provided via [libraryPath] parameter)
/// 2. **Build hook locations** (JIT: .dart_tool/lib/, AOT: ../lib/)
/// 3. **FRB default**: For Flutter apps with Cargokit
///
/// ### For Web
///
/// The WASM module is loaded from the `pkg/` directory automatically.
/// Custom library paths are not supported on web.
///
/// ### For Flutter apps
///
/// Cargokit automatically builds the native library or WASM module.
/// No manual setup required.
///
/// ### For pure Dart CLI apps
///
/// Option 1: Build locally
/// ```bash
/// cargo build --release --manifest-path rust/Cargo.toml
/// ```
///
/// Option 2: Run `dart pub get` to trigger the build hook (requires Dart 3.10+)
class Openmls {
  // coverage:ignore-start
  Openmls._();
  // coverage:ignore-end

  /// Track initialization per isolate (or single instance on web).
  static final Set<int> _initializedIsolates = {};

  /// Track if FRB has been initialized (global, not per-isolate).
  static bool _frbInitialized = false;

  /// Initialize the openmls library.
  ///
  /// This should be called once before using any openmls operations.
  /// It's safe to call multiple times - subsequent calls are no-ops.
  ///
  /// The [libraryPath] parameter allows specifying a custom absolute path
  /// to the native library. If not provided, the library will be searched
  /// automatically. **Note:** This parameter is ignored on web.
  ///
  /// For multi-isolate applications, call this in each isolate that
  /// uses openmls.
  static Future<void> init({String? libraryPath}) async {
    final isolateId = platform.getIsolateId();

    if (_initializedIsolates.contains(isolateId)) {
      return;
    }

    // Initialize FRB (Flutter Rust Bridge) only once
    if (!_frbInitialized) {
      final library = await _loadLibrary(libraryPath);
      await RustLib.init(externalLibrary: library);
      _frbInitialized = true;
    }

    _initializedIsolates.add(isolateId);
  }

  /// Load the native library from the best available location.
  ///
  /// Loading order:
  /// 1. Custom path (if provided via [libraryPath] parameter)
  /// 2. Build hook locations (JIT: .dart_tool/lib/, AOT: ../lib/)
  /// 3. FRB default (Flutter with Cargokit)
  static Future<ExternalLibrary> _loadLibrary(String? customPath) async {
    // coverage:ignore-start
    // On web, always use the default WASM loading
    if (platform.kIsWeb) {
      return await loadExternalLibrary(
        RustLib.kDefaultExternalLibraryLoaderConfig,
      );
    }
    // coverage:ignore-end

    // 1. Try custom path first (native only)
    if (customPath != null) {
      return platform.openLibraryFromPath(customPath); // coverage:ignore-line
    }

    // 2. Try build hook locations (Dart 3.10+ with build hook)
    // JIT mode: .dart_tool/lib/
    // AOT mode: ../lib/ relative to executable
    final nativeAssetLib = platform.tryLoadNativeAsset(_nativeAssetId);
    if (nativeAssetLib != null) {
      return nativeAssetLib;
    }

    // coverage:ignore-start
    // 3. Fall back to FRB's default loading (Flutter with Cargokit)
    return await loadExternalLibrary(
      RustLib.kDefaultExternalLibraryLoaderConfig,
    );
    // coverage:ignore-end
  }

  /// Whether the library has been initialized in the current isolate.
  static bool get isInitialized {
    final isolateId = platform.getIsolateId();
    return _initializedIsolates.contains(isolateId);
  }

  /// Ensures the library is initialized.
  ///
  /// Throws [StateError] if not initialized.
  static void ensureInitialized() {
    if (!isInitialized) {
      throw StateError(
        'Openmls not initialized. Call await Openmls.init() first.',
      );
    }
  }

  /// Clean up resources for the current isolate.
  ///
  /// By default, this only resets the isolate's initialization state.
  ///
  /// For CLI applications that are exiting, set [dispose] to `true` to
  /// also dispose the Flutter Rust Bridge runtime.
  ///
  /// **Important:** Close all [MlsEngine] instances before calling this
  /// method with `dispose: true`, as the Rust runtime will be shut down.
  ///
  /// **Note:** After `cleanup(dispose: true)`, you cannot reinitialize
  /// in the same process (FRB limitation).
  static void cleanup({bool dispose = false}) {
    final isolateId = platform.getIsolateId();
    _initializedIsolates.remove(isolateId);

    // coverage:ignore-start
    if (dispose && _initializedIsolates.isEmpty) {
      RustLib.dispose();
    }
    // coverage:ignore-end
  }
}

/// Base mixin for openmls operations.
mixin OpenmlsBase {
  /// Ensures the library is initialized.
  // coverage:ignore-start
  static void ensureInit() {
    Openmls.ensureInitialized();
  }

  // coverage:ignore-end
}
