/// Web-specific platform implementations.
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

/// Whether we're running on web.
const bool kIsWeb = true;

/// Web doesn't have isolates in the same way, use a constant.
int getIsolateId() => 0;

/// Native assets are not available on web.
ExternalLibrary? tryLoadNativeAsset(String assetId) => null;

/// Loading from path is not supported on web.
/// Throws [UnsupportedError].
ExternalLibrary openLibraryFromPath(String path) {
  throw UnsupportedError(
    'Custom library paths are not supported on web. '
    'The WASM module is loaded from the default location.',
  );
}

/// Finding library paths is not applicable on web.
String? findLibraryPath(String libraryName, String? packageRoot) => null;

/// Finding package root is not applicable on web.
String? findPackageRoot() => null;

/// Library name is not applicable on web (uses WASM module).
String getLibraryName() => 'openmls_frb.wasm';
