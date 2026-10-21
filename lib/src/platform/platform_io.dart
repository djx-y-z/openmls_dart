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

/// Installs the real `Dart_PostCObject` for flutter_rust_bridge again.
///
/// Call it right after `RustLib.init`. Every Rust-to-Dart message - the
/// result of an async call, the invocation of a store callback - goes through
/// one process-wide function pointer, and flutter_rust_bridge replaces it with
/// a no-op when its process-wide count of initialized isolates drops to zero
/// (its guard against posting after `Dart_Cleanup`). `RustLib.init` installs
/// the real function BEFORE it counts the isolate. If the last other counted
/// isolate group shuts down in between, its finalizer installs the no-op after
/// the real one, and this isolate - initialized and alive - is left with it:
/// every async call from then on waits forever for an answer that was dropped,
/// while sync calls, which post nothing, keep working.
///
/// Installing it again once the isolate is counted closes that window, since
/// the count cannot reach zero while this isolate lives. What stays open is a
/// finalizer that has already taken the count to zero and not yet written the
/// no-op - a few instructions on another thread. Only flutter_rust_bridge can
/// close that one, by updating the count and the pointer under one lock.
///
/// `dart test` runs every suite as its own isolate group in one process, and
/// that is where this was measured: the first async call of a suite hung until
/// the test timed out, on every CI platform.
void reinstallDartPostCObject(ExternalLibrary library) {
  library.ffiDynamicLibrary.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('store_dart_post_cobject')(NativeApi.postCObject.cast());
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
