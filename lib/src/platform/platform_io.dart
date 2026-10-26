/// IO-specific platform implementations for native platforms.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

/// Whether we're running on web.
const bool kIsWeb = false;

/// Get a unique identifier for the current isolate.
int getIsolateId() => Isolate.current.hashCode;

/// Try to load library via native assets build hook.
///
/// Note: DynamicLibrary.open(assetId) with 'package:' URIs doesn't work
/// in Dart - it tries to open the URI as a literal file path. Only
/// `@Native(assetId:)` externals resolve through the asset mapping, and
/// flutter_rust_bridge needs an [ExternalLibrary] handle, so we resolve the
/// actual file path ourselves - see [nativeAssetSearchPaths].
// ignore: avoid_unused_constructor_parameters
ExternalLibrary? tryLoadNativeAsset(String assetId) {
  // The assetId parameter is kept for API compatibility but not used.
  // We know where the build hook puts the library.

  for (final path in nativeAssetSearchPaths(getLibraryName())) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      return ExternalLibrary.open(file.absolute.path);
    } catch (_) {
      // Keep probing: a candidate that cannot be opened at all - corrupt, or
      // built for another architecture - must not stop the search. This does
      // not cover a merely *stale* library: dlopen binds lazily, so an
      // out-of-date build opens fine and only fails later, on a missing
      // symbol.
    }
  }

  return null;
}

/// Where each toolchain installs the `CodeAsset` the build hook registered,
/// in probe order.
///
/// [libraryName] is the platform-specific file name from [getLibraryName].
/// The relative entries are resolved against the current directory, which is
/// the package root for every toolchain listed below.
List<String> nativeAssetSearchPaths(String libraryName) {
  final paths = <String>[
    // 1. `dart run` / `dart test` (JIT): the SDK copies bundled code assets
    //    here and maps them in .dart_tool/native_assets.yaml.
    '.dart_tool/lib/$libraryName',
  ];

  // 2. `dart build cli` (AOT): the library is bundled in lib/ next to the
  //    executable. This is the only candidate that is not relative to the
  //    working directory, so it is probed before the one below: a compiled
  //    application must not be made to load whatever happens to sit in the
  //    directory it was launched from.
  try {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    paths.add('$executableDir/../lib/$libraryName');
  } catch (_) {
    // An embedder without a resolvable executable path must not take the
    // other candidates down with it.
  }

  // 3. `flutter test`: flutter_tools installs the hooked library under
  //    build/native_assets/<os>/ and hands flutter_tester a
  //    build/unit_test_assets/NativeAssetsManifest.json pointing at it. It
  //    never creates .dart_tool/lib/, and on macOS and Linux nothing on
  //    flutter_tester's dlopen search path covers that directory - so without
  //    this entry a Flutter package's own unit tests cannot load the library
  //    the hook just provisioned for them. Windows already resolved it:
  //    flutter_tools prepends the same directory to the tester's PATH, which
  //    is where Windows looks for a DLL. `build` is flutter_tools'
  //    default build directory; a project that moved it with
  //    `flutter config --build-dir` falls through to the FRB loader.
  paths.add('build/native_assets/${Platform.operatingSystem}/$libraryName');

  return paths;
}

/// Load library from a file path.
// coverage:ignore-start
ExternalLibrary openLibraryFromPath(String path) {
  return ExternalLibrary.open(path);
}
// coverage:ignore-end

/// Counts this isolate in [library]'s own count of live isolates. Call it
/// before `RustLib.init`.
///
/// Every Rust-to-Dart message - the result of an async call, the invocation of
/// a store callback - goes through one process-wide function pointer per
/// native library, and flutter_rust_bridge replaces it with a no-op once that
/// library's count of live isolates drops to zero (its guard against posting
/// after `Dart_Cleanup`). An isolate left out of the count is therefore left
/// with the no-op as soon as the last counted isolate shuts down: every async
/// call from then on waits forever for an answer that was dropped, while sync
/// calls, which post nothing, keep working. flutter_rust_bridge 2.13.0 leaves
/// an isolate out in two ways, and counting it here first closes both:
///
/// - **Another FRB library was initialized first in this isolate.** The
///   watcher that counts an isolate is one per isolate in flutter_rust_bridge's
///   Dart code, shared by every FRB library, while each native library keeps a
///   count of its own. `RustLib.init` therefore counts the isolate only in
///   whichever library initialized first, and a worker isolate that uses only
///   this one and exits takes its count to zero while this isolate still uses
///   it. Deterministic, no timing involved.
/// - **An isolate shut down during `RustLib.init`.** It installs the real
///   function before it counts the isolate, so the last other counted isolate
///   can install the no-op in between. Counted first, this isolate keeps the
///   count above zero for as long as it lives. What stays open is a finalizer
///   that has already taken the count to zero and not yet written the no-op -
///   a few instructions on another thread, which only a lock inside
///   flutter_rust_bridge can close.
///
/// Where this library is the first, `RustLib.init` counts the isolate a second
/// time. That is harmless: each count is undone by its own finalizer when the
/// isolate shuts down.
///
/// `frb_create_shutdown_callback` is flutter_rust_bridge's internal symbol, not
/// its API. A release that renames it makes the lookup, and so `init`, fail
/// loudly rather than hang; this goes once flutter_rust_bridge counts an
/// isolate in every library it initializes.
void countIsolateInLibrary(ExternalLibrary library) {
  _isolateCount ??= _IsolateCount(
    library.ffiDynamicLibrary.lookupFunction<
      Pointer<NativeFinalizerFunction> Function(),
      Pointer<NativeFinalizerFunction> Function()
    >('frb_create_shutdown_callback')(),
  );
}

/// Nothing to check on native platforms, which load no WASM module.
// coverage:ignore-start
Future<void> ensureWasmModuleServed(String moduleRoot) async {}
// coverage:ignore-end

/// This isolate's entry in the library's count; see [countIsolateInLibrary].
_IsolateCount? _isolateCount;

/// Keeps the isolate counted for as long as it lives: the native finalizer
/// undoes the count when the isolate shuts down, as flutter_rust_bridge's own
/// watcher does.
final class _IsolateCount implements Finalizable {
  _IsolateCount(Pointer<NativeFinalizerFunction> callback)
    : _finalizer = NativeFinalizer(callback) {
    _finalizer.attach(this, Pointer.fromAddress(0));
  }

  final NativeFinalizer _finalizer;
}

/// Get the platform-specific library name.
String getLibraryName() {
  if (Platform.isMacOS) {
    return 'libopenmls_frb.dylib';
  }
  // coverage:ignore-start
  if (Platform.isLinux) {
    return 'libopenmls_frb.so';
  }
  if (Platform.isWindows) {
    return 'openmls_frb.dll';
  }
  if (Platform.isAndroid) {
    return 'libopenmls_frb.so';
  }
  if (Platform.isIOS) {
    return 'libopenmls_frb.dylib';
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  // coverage:ignore-end
}
