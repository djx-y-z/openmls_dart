/// Web-specific platform implementations.
library;

import 'dart:js_interop';

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

/// Nothing to count on web: flutter_rust_bridge keeps neither a post function
/// nor an isolate count there, and its init steps for both are no-ops.
void countIsolateInLibrary(ExternalLibrary library) {}

/// Throws a [StateError] when the WASM module's loader script,
/// `<moduleRoot>.js`, is not served — where flutter_rust_bridge would wait
/// forever.
///
/// flutter_rust_bridge loads that script through a `<script>` tag and waits for
/// its `load` event, with no error path and no timeout. A missing module never
/// fires it: a 404 does not, and neither does the HTML page a development
/// server sends in its place with a 200. `RustLib.init` then never completes
/// and reports nothing, which is how an empty `web/pkg/` looks to the
/// application. The usual cause is a `flutter run -d chrome` on Flutter
/// 3.38 to 3.41 that skipped the build hook because a run for another platform
/// left its `dart_build` stamp behind.
///
/// Only a definite answer throws: a response that is not a success, or one
/// that is HTML. When the request itself fails — a Content Security Policy
/// that does not allow `fetch`, say — the script tag may still load, so this
/// stays out of the way and flutter_rust_bridge's loader runs as before.
Future<void> ensureWasmModuleServed(String moduleRoot) async {
  final url = '$moduleRoot.js';
  final _Response response;
  try {
    response = await _fetch(url.toJS).toDart;
  } catch (_) {
    return;
  }
  final contentType = response.headers.get('content-type'.toJS)?.toDart;
  if (response.ok && !(contentType ?? '').contains('text/html')) return;
  throw StateError(
    '$url is not served (HTTP ${response.status}, '
    '${contentType ?? 'no content type'}), so the WASM module cannot load and '
    'init() would never complete. The build hook copies the module into '
    'web/pkg/. If `flutter run -d chrome` skipped the hook — on Flutter 3.38 '
    'to 3.41 a run for another platform makes it skip — run `flutter build '
    'web` once, or delete build/*/dart_build.stamp, and run again.',
  );
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external _Headers get headers;
}

extension type _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}

/// Finding library paths is not applicable on web.
String? findLibraryPath(String libraryName, String? packageRoot) => null;

/// Finding package root is not applicable on web.
String? findPackageRoot() => null;

/// Library name is not applicable on web (uses WASM module).
String getLibraryName() => 'openmls_frb.wasm';
