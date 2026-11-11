/// Build hook for downloading and bundling openmls native libraries.
///
/// This hook is automatically invoked by the Dart/Flutter build system
/// when building applications that depend on the openmls package.
///
/// The hook downloads pre-built native libraries from GitHub Releases
/// based on the target platform and architecture.
///
/// Every download is checked against the SHA256 the release publishes, and
/// there is no way to skip the check. Nothing could reach the hook to switch it
/// off in any case: Dart's and Flutter's hook runners give a hook only a fixed
/// list of environment variables (`HOME`, `PATH`, `TMPDIR` and a few more).
///
/// ## How it works
///
/// ### Native platforms (iOS, Android, macOS, Linux, Windows)
/// 1. Hook downloads the appropriate `openmls_frb` binary for the target
/// 2. Registers it as a CodeAsset with asset ID `package:openmls/openmls`
/// 3. Dart runtime bundles and loads the asset automatically
///
/// ### Web platform
/// 1. Hook detects web build (no code_assets config)
/// 2. Downloads WASM files to `<app_root>/web/pkg/`
/// 3. FRB loads WASM at runtime from that location
///
/// ## For development
///
/// A locally built library is picked up automatically — no marker needed. The
/// hook prefers a `rust/target/` build over downloading, as long as the build
/// is stamped with the current crate version and lock file:
/// ```bash
/// # This machine → rust/target/release/lib<crate>.<ext>
/// make build
///
/// # A device, a simulator or an emulator → rust/target/<triple>/release/
/// make build-android ARGS="--target arm64-v8a"
/// make build-ios ARGS="--target aarch64-apple-ios-sim"
///
/// # Web/WASM → rust/target/wasm32/
/// make build-web
/// ```
///
/// `.skip_openmls_hook` is an INTERNAL escape used by the Makefile while it
/// wraps pub-get/codegen/doc: when present the hook returns immediately and
/// registers NO native asset. It is not the way to select a local build.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

/// Package name for asset registration.
const _packageName = 'openmls';

/// Asset ID used for looking up the library at runtime.
/// Note: This is just the name part; CodeAsset combines it with package
/// to form the full ID: package:openmls/openmls
const _assetId = 'openmls';

/// GitHub repository for downloading releases.
const _githubRepo = 'djx-y-z/openmls_dart';

/// Rust crate name (used for library filenames and release tags).
const _crateName = 'openmls_frb';

/// WASM files for web platform.
const _wasmFiles = ['openmls_frb.js', 'openmls_frb_bg.wasm'];

/// Marker file recording which package version provisioned `web/pkg/`.
/// Lets the web build hook detect a version upgrade and refresh the WASM
/// instead of serving a stale copy left behind by a previous version.
const _wasmVersionMarkerName = '.wasm-version';

/// Sentinel written to the marker when `web/pkg/` came from a local dev build,
/// so a later switch back to released binaries always forces a refresh.
const _localWasmMarker = 'local-dev';

/// Name of the stamp `make build` writes beside the host library in
/// `rust/target/release/`, `make build-web` beside the module in
/// `rust/target/wasm32/`, and `make build-android`, `make build-ios` and
/// `make build ARGS="--target <triple>"` beside a cross build in
/// `rust/target/<triple>/release/`, recording the crate version each was built
/// from.
///
/// It exists because nothing else can answer the question. A local build
/// directory is a build artefact: its files change whenever
/// anyone rebuilds, and their timestamps move on a checkout, a stash or a
/// no-op rebuild, in both directions — so neither content nor mtime says which
/// crate version they came from.
const localBuildStampName = '.crate-version';

/// Whether a local build may be used for [version], in place of the released
/// one.
///
/// [stamped] is the trimmed contents of [localBuildStampName], or null when
/// the file is absent — which is the case for every directory built before
/// its stamp existed, and is deliberately treated as a mismatch.
///
/// ⚠ `rustContentHash` does NOT cover this. That check hashes only the
/// *names* of the bridged functions, and those can stay the same across a
/// release that moves the vendored native code underneath them, which is
/// exactly what a patch release looks like. So the one value that already
/// crosses the Dart-to-binary boundary is blind to a stale local build by
/// construction, and a version stamp is the check that is not.
///
/// Pure so it is testable without a build tree.
bool localBuildMatchesCrate({
  required String? stamped,
  required String version,
}) => stamped != null && stamped.trim() == version;

/// Reads [localBuildStampName] from a local build directory, or null.
String? readLocalBuildStamp(Directory buildDir) {
  final file = File('${buildDir.path}/$localBuildStampName');
  if (!file.existsSync()) return null;
  return file.readAsStringSync().trim();
}

/// Name of the copy of `rust/Cargo.lock` that the make targets above leave
/// beside their stamps: the dependency graph the build was made from.
///
/// The version stamp cannot tell two builds of one crate version apart, and an
/// upstream update moves the dependencies without moving the crate version,
/// which moves at release time. A local build from before such an update passes
/// the version check and runs the previous upstream code. Comparing the lock
/// file the build was made from with the one in the tree catches that. It is a
/// copy rather than a hash so that the Makefile needs no hashing tool — they
/// differ from one platform to the next — and the comparison stays exact.
const localBuildLockName = '.cargo-lock';

/// Whether a local build was made from the lock file the tree has now.
///
/// [built] is the copy in [localBuildLockName] and [current] is
/// `rust/Cargo.lock`, each null when absent. A build without the copy predates
/// it and is treated as a mismatch, exactly as a missing version stamp is.
///
/// Pure so it is testable without a build tree.
bool localBuildMatchesLock({
  required String? built,
  required String? current,
}) => built != null && current != null && built == current;

/// Reads [file] as text, or null when it is absent.
String? readIfPresent(File file) =>
    file.existsSync() ? file.readAsStringSync() : null;

/// Marker written into a version-keyed download cache directory as the LAST
/// step of a successful download+verify+extract. Its absence means the cache
/// entry is incomplete (e.g. an interrupted extraction left a truncated file),
/// so the entry must be re-provisioned rather than reused unverified.
const _cacheCompleteMarker = '.download-complete';

/// Entry point for the build hook.
void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageRoot = input.packageRoot;

    // Check for skip marker file (used during library building via `make build`)
    // This avoids chicken-and-egg problem when building native libraries
    final skipMarkerUri = packageRoot.resolve('.skip_openmls_hook');
    final skipFile = File.fromUri(skipMarkerUri);

    if (skipFile.existsSync()) {
      // Declare the marker only while it exists. Declaring a missing file makes
      // hooks_runner treat it as "modified during build" on every invocation,
      // forcing a redundant hook pass on every build for every consumer. Once
      // the Makefile removes an existing marker, this dependency becomes
      // missing and invalidates the skipped result as intended.
      output.dependencies.add(skipMarkerUri);
      return;
    }

    // Handle web builds (buildCodeAssets is false for web platform)
    if (!input.config.buildCodeAssets) {
      // Web builds don't produce CodeAssets - they copy WASM files to web/pkg/.

      // Declare rust/Cargo.toml as a dependency so a crate-version bump forces
      // the hook to re-run (the version-marker check inside then refreshes
      // web/pkg/). Without this the build system can reuse a cached hook result
      // and keep serving the previous version's WASM after an upgrade.
      output.dependencies.add(packageRoot.resolve('rust/Cargo.toml'));
      await _handleWebBuild(input, output, packageRoot);
      return;
    }

    final codeConfig = input.config.code;
    final targetOS = codeConfig.targetOS;
    final targetArch = codeConfig.targetArchitecture;
    final iosSdk = targetOS == OS.iOS ? codeConfig.iOS.targetSdk : null;

    // Read version from rust/Cargo.toml
    final version = await _readVersion(packageRoot);

    // Check for local build first (development mode)
    // This allows developers to use locally built libraries without downloading
    final localDir = localBuildDirectory(
      targetOS: targetOS,
      targetArchitecture: targetArch,
      iosSdk: iosSdk,
      hostOS: OS.current,
      hostArchitecture: Architecture.current,
    );
    final localFile = localDir == null
        ? null
        : packageRoot.resolve('$localDir${_getLibraryFileName(targetOS)}');
    final localLib = localFile != null && File.fromUri(localFile).existsSync()
        ? localFile
        : null;
    if (localLib != null) {
      // A local build wins over the released one, so it must be shown to
      // belong to THIS crate version, exactly as the local WASM build must.
      // Nothing else would notice: a library left over from an earlier crate
      // loads, and when the way values cross the bridge has moved since, the
      // calls fail in ways no check names — every error a `TypeError`, say.
      final buildDir = Directory.fromUri(localLib.resolve('.'));
      final stamped = readLocalBuildStamp(buildDir);
      if (!localBuildMatchesCrate(stamped: stamped, version: version)) {
        throw HookException(
          'The local build ${localLib.toFilePath()} was produced by '
          '${stamped == null ? 'an unknown crate version' : 'crate $stamped'}, '
          'but rust/Cargo.toml is at $version. It takes priority over the '
          'released library, so loading it would run the wrong code. '
          'Run ${_rebuildCommand(localDir!, targetOS)} to rebuild it, or '
          'delete ${buildDir.path} to use the released library instead.',
        );
      }
      // The crate version does not move with the dependencies, so the same
      // version stamp is no proof of the same code: compare the lock file too.
      final lockUri = packageRoot.resolve('rust/Cargo.lock');
      final builtLock = readIfPresent(
        File('${buildDir.path}/$localBuildLockName'),
      );
      if (!localBuildMatchesLock(
        built: builtLock,
        current: readIfPresent(File.fromUri(lockUri)),
      )) {
        throw HookException(
          'The local build ${localLib.toFilePath()} was made from '
          '${builtLock == null ? 'an unrecorded rust/Cargo.lock' : 'another rust/Cargo.lock than the tree has now'}: '
          'its dependencies may have moved while the crate version stayed at '
          '$version. It takes priority over the released library, so loading '
          'it could run the wrong code. Run '
          '${_rebuildCommand(localDir!, targetOS)} to rebuild it, or delete '
          '${buildDir.path} to use the released library instead.',
        );
      }
      // ignore: avoid_print
      print(
        'Using local $targetOS-$targetArch build: ${localLib.toFilePath()}',
      );
      output.assets.code.add(
        CodeAsset(
          package: _packageName,
          name: _assetId,
          linkMode: DynamicLoadingBundled(),
          file: localLib,
        ),
      );
      // Declare the library itself, not only the manifest. It was taken
      // above because it exists right now, so this follows the same
      // declare-only-while-it-exists rule as the skip marker above. Without it
      // the build system keeps a cached result pointing at this path:
      // rebuilding the crate without touching Cargo.toml keeps serving the
      // previous binary, and removing the build (`make clean`) makes the next
      // `dart test` / `dart run` fail outright — hooks_runner reuses the cached
      // asset and the SDK aborts copying a file that is no longer there.
      output.dependencies
        ..add(packageRoot.resolve('rust/Cargo.toml'))
        ..add(lockUri)
        ..add(localLib)
        ..add(buildDir.uri.resolve(localBuildStampName))
        ..add(buildDir.uri.resolve(localBuildLockName));
      return;
    }

    // For native platforms, download from GitHub Releases and bundle with the app
    final assetInfo = _resolveAssetInfo(
      targetOS: targetOS,
      targetArch: targetArch,
      iosSdk: iosSdk,
      version: version,
    );

    // Output directory for cached downloads
    final archSubdir = downloadCacheSubdir(
      version: version,
      targetOS: targetOS,
      targetArchitecture: targetArch,
      iosSdk: iosSdk,
    );
    final cacheDir = input.outputDirectoryShared.resolve('$archSubdir/');
    final libFile = File.fromUri(cacheDir.resolve(assetInfo.fileName));

    // Download unless the cache entry is COMPLETE. Existence alone is not
    // enough: an interrupted extraction can leave a truncated library that
    // would then be reused (and registered) forever. The completeness marker is
    // written only after a fully verified extraction, so a missing marker
    // re-provisions and heals the entry.
    if (!_isCacheComplete(cacheDir) || !libFile.existsSync()) {
      final baseUrl =
          'https://github.com/$_githubRepo/releases/download/$_crateName-$version';

      // SECURITY: resolve the expected SHA256 before fetching the binary.
      // Fail-closed — if a trusted checksum cannot be obtained the build
      // aborts, so a failed or interfered checksum fetch cannot downgrade to
      // running an unverified native library.
      final expectedChecksum = await resolveExpectedChecksum(
        baseUrl,
        version,
        assetInfo.archiveFileName,
      );

      await _downloadAndExtract(
        assetInfo.downloadUrl,
        cacheDir,
        assetInfo.archiveFileName,
        assetInfo.fileName,
        expectedChecksum: expectedChecksum,
      );
    }

    // Verify file exists after download
    if (!libFile.existsSync()) {
      throw HookException(
        'Failed to download openmls library for $targetOS-$targetArch. '
        'File not found: ${libFile.path}',
      );
    }

    // Register native asset (Flutter converts .dylib to Framework for iOS)
    output.assets.code.add(
      CodeAsset(
        package: _packageName,
        name: _assetId,
        linkMode: DynamicLoadingBundled(),
        file: libFile.uri,
      ),
    );

    // Add dependency on Cargo.toml for cache invalidation
    output.dependencies.add(packageRoot.resolve('rust/Cargo.toml'));
  });
}

/// Reads the crate version from rust/Cargo.toml.
Future<String> _readVersion(Uri packageRoot) async {
  final cargoFile = File.fromUri(packageRoot.resolve('rust/Cargo.toml'));
  if (!cargoFile.existsSync()) {
    throw HookException('rust/Cargo.toml not found at ${cargoFile.path}');
  }

  final content = await cargoFile.readAsString();

  // Extract version from [package] section
  final versionMatch = RegExp(
    r'^version\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(content);

  if (versionMatch == null) {
    throw HookException('version not found in rust/Cargo.toml');
  }

  return versionMatch.group(1)!.trim();
}

// =============================================================================
// Web Build Support
// =============================================================================

/// Checks if all required WASM files exist in a directory.
bool _wasmFilesExist(Directory dir) {
  if (!dir.existsSync()) return false;

  for (final fileName in _wasmFiles) {
    final file = File('${dir.path}/$fileName');
    if (!file.existsSync()) return false;
  }
  return true;
}

/// Reads the version marker from a provisioned `web/pkg/` directory.
///
/// Returns the recorded version string, or null if the marker is absent or
/// unreadable (treated as "unknown", forcing a refresh).
String? _readWasmVersionMarker(Directory webPkgDir) {
  final file = File('${webPkgDir.path}/$_wasmVersionMarkerName');
  if (!file.existsSync()) return null;
  try {
    return file.readAsStringSync().trim();
  } catch (_) {
    return null;
  }
}

/// Records which version provisioned `web/pkg/` so a later build can detect an
/// upgrade and refresh. Best-effort: a write failure must not fail the build —
/// without the marker the next build simply re-provisions.
void _writeWasmVersionMarker(Directory webPkgDir, String version) {
  try {
    if (!webPkgDir.existsSync()) {
      webPkgDir.createSync(recursive: true);
    }
    File(
      '${webPkgDir.path}/$_wasmVersionMarkerName',
    ).writeAsStringSync('$version\n');
  } catch (_) {
    // Non-fatal.
  }
}

/// Finds local WASM build in the package's rust/target/wasm32 directory.
///
/// This enables development mode where developers can use locally built
/// WASM files instead of downloading from GitHub Releases.
Directory? _findLocalWasmBuild(Uri packageRoot) {
  final localDir = Directory.fromUri(
    packageRoot.resolve('rust/target/wasm32/'),
  );
  if (_wasmFilesExist(localDir)) {
    return localDir;
  }
  return null;
}

/// Handles web builds by downloading WASM files and copying them to the app's web/pkg/ directory.
///
/// Flutter web apps need WASM files in the web/pkg/ directory to be accessible at runtime.
/// This function:
/// 1. First checks for local WASM build (development mode)
/// 2. Otherwise downloads WASM files from GitHub Releases to a shared cache
/// 3. Finds the Flutter app root (the consuming application)
/// 4. Copies WASM files to `{app_root}/web/pkg/` where Flutter web expects them
Future<void> _handleWebBuild(
  BuildInput input,
  BuildOutputBuilder output,
  Uri packageRoot,
) async {
  // Declare the local WASM build outputs and the web/pkg version marker as
  // dependencies so a rebuild or a deletion of the local build, or a manual
  // web/pkg/ wipe (which removes the marker), invalidates a cached hook result
  // instead of keeping web/pkg/ stale. The local build's files only while they
  // exist: see existingLocalWasmBuildFiles.
  output.dependencies.addAll(existingLocalWasmBuildFiles(packageRoot));

  // Find the Flutter app root first
  final appRoot = _findAppRoot(input.outputDirectoryShared);
  if (appRoot == null) {
    // ignore: avoid_print
    print('Warning: Could not find Flutter app root for web build');
    return;
  }

  final webPkgDir = Directory.fromUri(appRoot.resolve('web/pkg/'));
  output.dependencies.add(webPkgDir.uri.resolve(_wasmVersionMarkerName));

  // Read version from rust/Cargo.toml up front — it keys both the download
  // cache and the freshness check below.
  final version = await _readVersion(packageRoot);

  // Check for local WASM build first (development mode) — takes priority
  // over cached/downloaded files to avoid stale content hash mismatches.
  final localWasmDir = _findLocalWasmBuild(packageRoot);
  if (localWasmDir != null) {
    // A local build wins over the released one, so it must be shown to belong
    // to THIS crate version. Nothing downstream would notice if it did not:
    // the marker written below is a sentinel rather than a version, so the
    // freshness check further down is unreachable on this path, and
    // `rustContentHash` hashes only the bridged functions' names, which a
    // release may leave unchanged while replacing the native code behind
    // them. A stale module would then be served silently, and on the web that
    // means running an upstream version the rest of the package has already
    // moved past.
    final stamped = readLocalBuildStamp(localWasmDir);
    if (!localBuildMatchesCrate(stamped: stamped, version: version)) {
      throw HookException(
        'The local WASM build in ${localWasmDir.path} was produced by '
        '${stamped == null ? 'an unknown crate version' : 'crate $stamped'}, '
        'but rust/Cargo.toml is at $version. It takes priority over the '
        'released module, so serving it would run the wrong code. '
        'Run `make build-web` to rebuild it, or delete '
        '${localWasmDir.path} to use the released WASM instead.',
      );
    }
    // Same version, same code only if the dependencies did not move either.
    final lockUri = packageRoot.resolve('rust/Cargo.lock');
    final builtLock = readIfPresent(
      File('${localWasmDir.path}/$localBuildLockName'),
    );
    if (!localBuildMatchesLock(
      built: builtLock,
      current: readIfPresent(File.fromUri(lockUri)),
    )) {
      throw HookException(
        'The local WASM build in ${localWasmDir.path} was made from '
        '${builtLock == null ? 'an unrecorded rust/Cargo.lock' : 'another rust/Cargo.lock than the tree has now'}: '
        'its dependencies may have moved while the crate version stayed at '
        '$version. It takes priority over the released module, so serving it '
        'could run the wrong code. Run `make build-web` to rebuild it, or '
        'delete ${localWasmDir.path} to use the released WASM instead.',
      );
    }
    output.dependencies.add(lockUri);
    // ignore: avoid_print
    print('Using local WASM build from ${localWasmDir.path}');
    await _copyWasmFilesToAppRoot(localWasmDir.uri, webPkgDir);
    _writeWasmVersionMarker(webPkgDir, _localWasmMarker);
    return;
  }

  // Skip only when web/pkg/ already holds THIS version's WASM. Existence alone
  // is NOT sufficient: a stale web/pkg/ left over from an older package version
  // carries an outdated FRB wire signature, so `*_with_callbacks` calls would
  // panic with an argument-count mismatch. The marker forces a refresh on
  // upgrade (native platforms get this for free via a version-keyed cache).
  if (_wasmFilesExist(webPkgDir) &&
      _readWasmVersionMarker(webPkgDir) == version) {
    // ignore: avoid_print
    print('WASM files for $version already present in ${webPkgDir.path}');
    return;
  }

  final baseUrl =
      'https://github.com/$_githubRepo/releases/download/$_crateName-$version';
  // Version-key the download cache (mirrors the native path) so bumping the
  // package version resolves to a fresh directory and re-downloads instead of
  // reusing a previous version's archive.
  final cacheDir = input.outputDirectoryShared.resolve('web/$version/');

  // Download WASM files to cache
  final archiveFileName = '$_crateName-$version-wasm32.tar.gz';
  await provisionWasmCache(
    cacheDir: cacheDir,
    url: '$baseUrl/$archiveFileName',
    archiveFileName: archiveFileName,
    // SECURITY: resolved before the download (fail-closed, see the native path
    // above). The WASM assets are shipped in a single archive, so one checksum
    // covers every file extracted from it.
    expectedChecksum: () =>
        resolveExpectedChecksum(baseUrl, version, archiveFileName),
  );

  // Copy WASM files to web/pkg/ and record the version so the next build can
  // detect an upgrade and refresh instead of serving stale binaries.
  await _copyWasmFilesToAppRoot(cacheDir, webPkgDir);
  _writeWasmVersionMarker(webPkgDir, version);
}

/// The files of a local WASM build that exist now, for the hook to declare as
/// its dependencies.
///
/// Only those that exist: a hook runner counts a declared file that is missing
/// as changed. Declaring them all made every web build of a consumer run the
/// hook again, since the package it gets from pub.dev has no rust/target/.
/// A local build made after the hook last ran is still seen, because
/// `make build-web` drops the hook's cached result, as `make build` does.
List<Uri> existingLocalWasmBuildFiles(Uri packageRoot) => [
  for (final name in [..._wasmFiles, localBuildStampName, localBuildLockName])
    packageRoot.resolve('rust/target/wasm32/$name'),
].where((file) => File.fromUri(file).existsSync()).toList();

/// Makes [cacheDir] hold every one of [files] from the archive at [url],
/// unless it already holds them all, complete.
///
/// Complete means the completeness marker is there: it is written only after a
/// verified extraction. Nothing in an entry without it is reused, a file that
/// exists included, since an interrupted extraction can leave a truncated one.
/// Downloading only the files that were missing kept such a file: it went to
/// web/pkg/ under this version's marker and was never replaced. The native
/// path re-provisions an incomplete entry the same way.
///
/// [expectedChecksum] is asked only when there is something to download, so a
/// complete cache re-provisions web/pkg/ offline, after a manual wipe of it.
Future<void> provisionWasmCache({
  required Uri cacheDir,
  required String url,
  required String archiveFileName,
  required Future<String> Function() expectedChecksum,
  List<String> files = _wasmFiles,
}) async {
  bool present(String file) =>
      File.fromUri(cacheDir.resolve(file)).existsSync();
  if (_isCacheComplete(cacheDir) && files.every(present)) return;

  await _downloadAndExtract(
    url,
    cacheDir,
    archiveFileName,
    files.first,
    expectedChecksum: await expectedChecksum(),
  );
  for (final file in files) {
    if (!present(file)) {
      throw HookException('Failed to download WASM file: $file');
    }
  }
}

/// Finds the Flutter application root by searching parent directories from shared output.
///
/// Uses the shared output directory as starting point and looks for a pubspec.yaml
/// with a web/ directory, indicating this is a Flutter web application.
/// Additionally verifies the pubspec.yaml depends on this package to avoid
/// finding unrelated projects.
/// Returns null if no Flutter app root is found.
Uri? _findAppRoot(Uri sharedOutputDir) {
  var dir = Directory.fromUri(sharedOutputDir);

  // Limit search depth to avoid infinite loops
  for (var i = 0; i < 10; i++) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      // Reached filesystem root
      break;
    }
    dir = parent;

    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final webDir = Directory('${dir.path}/web');
      if (webDir.existsSync()) {
        // Verify this pubspec depends on our package
        if (_pubspecDependsOnPackage(pubspec)) {
          return dir.uri;
        }
      }
    }
  }

  return null;
}

/// Checks if a pubspec.yaml file depends on this package.
///
/// Returns true if the pubspec has this package as a dependency (regular, dev, or path).
bool _pubspecDependsOnPackage(File pubspec) {
  try {
    final content = pubspec.readAsStringSync();

    // Look for package name in dependencies section
    // Handles: package_name:, "package_name":, 'package_name':
    final packagePattern = RegExp(
      '^\\s*["\']?$_packageName["\']?\\s*:',
      multiLine: true,
    );

    return packagePattern.hasMatch(content);
  } catch (e) {
    // If we can't read the file, assume it doesn't depend on us
    return false;
  }
}

/// Copies WASM files from cache to the app's web/pkg/ directory.
Future<void> _copyWasmFilesToAppRoot(Uri cacheDir, Directory webPkgDir) async {
  // Create web/pkg/ directory if it doesn't exist
  if (!webPkgDir.existsSync()) {
    await webPkgDir.create(recursive: true);
  }

  // Copy each WASM file, always overwriting. The caller only reaches this
  // point after deciding web/pkg/ needs (re)provisioning, so an mtime-based
  // skip here would wrongly keep a stale copy — e.g. on a version downgrade
  // where the fresh source is older than the leftover destination.
  for (final fileName in _wasmFiles) {
    final sourceFile = File.fromUri(cacheDir.resolve(fileName));
    final destFile = File('${webPkgDir.path}/$fileName');

    if (sourceFile.existsSync()) {
      await sourceFile.copy(destFile.path);
    }
  }
}

// =============================================================================
// Native Build Support
// =============================================================================

/// The directory under the package root that holds a local build for this
/// target, or null when this target can have none.
///
/// `make build` puts the host's library in `rust/target/release/`, and only a
/// target that matches the host OS AND architecture may use it — anything else
/// would bundle e.g. a macOS dylib into an iOS app, which dyld rejects at
/// launch, or a library of the wrong architecture.
///
/// Every other target has a directory of its own, `rust/target/<triple>/release/`,
/// where a cross build lands. Reading it is what lets a pull request run its
/// own Rust on a device: without it those targets could only ever load the last
/// released library, so a test on an emulator would pass over code the pull
/// request had replaced, or fail on bindings newer than the release.
///
/// The caller refuses whatever it finds here unless `make` stamped it with the
/// current crate version and lock file, and none of this reaches a consumer:
/// `rust/target/` is not in the published package.
///
/// Pure, and takes the host as arguments, so it is testable on any machine.
String? localBuildDirectory({
  required OS targetOS,
  required Architecture targetArchitecture,
  required IOSSdk? iosSdk,
  required OS hostOS,
  required Architecture hostArchitecture,
}) {
  if (targetOS == hostOS && targetArchitecture == hostArchitecture) {
    return 'rust/target/release/';
  }
  final triple = _rustTriple(targetOS, targetArchitecture, iosSdk);
  return triple == null ? null : 'rust/target/$triple/release/';
}

/// The Rust target this package's release builds for this target, or null when
/// it builds none. The same names as in `build-openmls.yml`.
String? _rustTriple(OS targetOS, Architecture targetArch, IOSSdk? iosSdk) {
  switch (targetOS) {
    case OS.android:
      if (targetArch == Architecture.arm64) return 'aarch64-linux-android';
      if (targetArch == Architecture.arm) return 'armv7-linux-androideabi';
      if (targetArch == Architecture.x64) return 'x86_64-linux-android';
      return null;
    case OS.iOS:
      if (iosSdk != IOSSdk.iPhoneSimulator) {
        return targetArch == Architecture.arm64 ? 'aarch64-apple-ios' : null;
      }
      if (targetArch == Architecture.arm64) return 'aarch64-apple-ios-sim';
      if (targetArch == Architecture.x64) return 'x86_64-apple-ios';
      return null;
    case OS.macOS:
      if (targetArch == Architecture.arm64) return 'aarch64-apple-darwin';
      if (targetArch == Architecture.x64) return 'x86_64-apple-darwin';
      return null;
    case OS.linux:
      if (targetArch == Architecture.arm64) return 'aarch64-unknown-linux-gnu';
      if (targetArch == Architecture.x64) return 'x86_64-unknown-linux-gnu';
      return null;
    case OS.windows:
      return targetArch == Architecture.x64 ? 'x86_64-pc-windows-msvc' : null;
    default:
      return null;
  }
}

/// The make command that rebuilds what is in [directory], one of
/// [localBuildDirectory]'s answers.
String _rebuildCommand(String directory, OS targetOS) {
  if (directory == 'rust/target/release/') return '`make build`';
  final triple = directory.split('/')[2];
  return switch (targetOS) {
    OS.android => '`make build-android ARGS="--target $triple"`',
    OS.iOS => '`make build-ios ARGS="--target $triple"`',
    _ => '`make build ARGS="--target $triple"`',
  };
}

/// Gets the library filename for the target OS.
String _getLibraryFileName(OS targetOS) {
  switch (targetOS) {
    case OS.linux:
    case OS.android:
      return 'lib$_crateName.so';
    case OS.macOS:
    case OS.iOS:
      return 'lib$_crateName.dylib';
    case OS.windows:
      return '$_crateName.dll';
    default:
      return 'lib$_crateName.so';
  }
}

/// Information about a native asset for a specific platform.
class _AssetInfo {
  const _AssetInfo({
    required this.downloadUrl,
    required this.archiveFileName,
    required this.fileName,
  });

  final String downloadUrl;
  final String archiveFileName;
  final String fileName;
}

/// Resolves asset information for the target platform.
_AssetInfo _resolveAssetInfo({
  required OS targetOS,
  required Architecture targetArch,
  required IOSSdk? iosSdk,
  required String version,
}) {
  final baseUrl =
      'https://github.com/$_githubRepo/releases/download/$_crateName-$version';

  final fileName = _getLibraryFileName(targetOS);
  final platformArch = _getPlatformArchName(targetOS, targetArch, iosSdk);

  final archiveFileName = '$_crateName-$version-$platformArch.tar.gz';

  return _AssetInfo(
    downloadUrl: '$baseUrl/$archiveFileName',
    archiveFileName: archiveFileName,
    fileName: fileName,
  );
}

/// Computes the subdirectory of the shared output directory in which a
/// downloaded library is cached.
///
/// The shared output directory is reused across build configurations
/// (`package:hooks` requires hooks to sub-key it by every config field that
/// influences their output). The returned key must therefore include every
/// input that changes which artifact is downloaded: the crate [version] and
/// the full platform variant — notably iOS device vs. simulator, which share
/// [targetOS] and [targetArchitecture] on Apple-silicon hosts.
///
/// Top-level and public so the hook tests can exercise it.
String downloadCacheSubdir({
  required String version,
  required OS targetOS,
  required Architecture targetArchitecture,
  IOSSdk? iosSdk,
}) {
  return '$version-${_getPlatformArchName(targetOS, targetArchitecture, iosSdk)}';
}

/// Gets platform-architecture name for download URL.
String _getPlatformArchName(
  OS targetOS,
  Architecture targetArch,
  IOSSdk? iosSdk,
) {
  switch (targetOS) {
    case OS.linux:
      return 'linux-${_archName(targetArch)}';
    case OS.macOS:
      return 'macos-${_archName(targetArch)}';
    case OS.windows:
      // Only x86_64 is released for Windows. Flutter builds an arm64 app on
      // Windows on Arm, which cannot load that library: refuse the build here,
      // as the other systems refuse an architecture they have no release for,
      // rather than let the running app fail to load it.
      if (targetArch != Architecture.x64) {
        throw HookException('Unsupported Windows architecture: $targetArch');
      }
      return 'windows-x86_64';
    case OS.android:
      return 'android-${_androidAbi(targetArch)}';
    case OS.iOS:
      if (iosSdk == IOSSdk.iPhoneSimulator) {
        return 'ios-simulator-${_archName(targetArch)}';
      }
      return 'ios-device-arm64';
    default:
      throw HookException('Unsupported OS: $targetOS');
  }
}

/// Converts Dart Architecture to architecture name (arm64/x86_64).
String _archName(Architecture arch) {
  switch (arch) {
    case Architecture.arm64:
      return 'arm64';
    case Architecture.x64:
      return 'x86_64';
    default:
      throw HookException('Unsupported architecture: $arch');
  }
}

/// Converts Dart Architecture to Android ABI name.
String _androidAbi(Architecture arch) {
  switch (arch) {
    case Architecture.arm64:
      return 'arm64-v8a';
    case Architecture.arm:
      return 'armeabi-v7a';
    case Architecture.x64:
      return 'x86_64';
    default:
      throw HookException('Unsupported Android architecture: $arch');
  }
}

// =============================================================================
// Download Support
// =============================================================================

/// Downloads and extracts the native library archive with SHA256 verification.
///
/// [expectedChecksum] is the expected SHA256 hash of the archive, which is
/// used only if it matches.
Future<void> _downloadAndExtract(
  String url,
  Uri outputDir,
  String archiveFileName,
  String libFileName, {
  required String expectedChecksum,
}) async {
  final outDir = Directory.fromUri(outputDir);
  await outDir.create(recursive: true);

  final archiveFile = File('${outDir.path}/$archiveFileName');

  // Download with retry
  await downloadWithRetry(url, archiveFile);

  await _verifyChecksum(archiveFile, expectedChecksum, archiveFileName);

  // Extract based on format
  if (url.endsWith('.zip')) {
    await _extractZip(archiveFile, outDir);
  } else {
    await _extractTarGz(archiveFile, outDir);
  }

  // Clean up archive
  if (archiveFile.existsSync()) {
    await archiveFile.delete();
  }

  // Verify extraction
  final libFile = File('${outDir.path}/$libFileName');
  if (!libFile.existsSync()) {
    throw HookException(
      'Extraction failed: $libFileName not found in archive from $url',
    );
  }

  // Mark the cache entry complete only now — after a verified, fully extracted
  // archive. A crash before this point leaves the marker absent, so the next
  // build re-provisions instead of reusing a truncated file.
  _markCacheComplete(outputDir);
}

/// Whether [cacheDir] holds a fully provisioned download (see
/// [_cacheCompleteMarker]).
bool _isCacheComplete(Uri cacheDir) =>
    File.fromUri(cacheDir.resolve(_cacheCompleteMarker)).existsSync();

/// Records that [cacheDir] was fully provisioned. Best-effort: a write failure
/// must not fail the build (the next run simply re-provisions).
void _markCacheComplete(Uri cacheDir) {
  try {
    File.fromUri(
      cacheDir.resolve(_cacheCompleteMarker),
    ).writeAsStringSync('ok\n');
  } catch (_) {
    // Non-fatal.
  }
}

/// How long the hook pauses before each retry of a download, in order: it
/// tries once, then once after each of these, with a minute of pauses in all.
/// A runner's DNS has been seen failing for longer than the six seconds three
/// tries used to span. Only a network failure and a 5xx or 429 answer are
/// retried; a 404, any other answer, and a failure to write the file are not.
const downloadRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 30),
];

/// How long one attempt waits to connect. Without it the operating system's own
/// limit applies, over a minute on macOS and two on Linux, for each attempt.
const _connectionTimeout = Duration(seconds: 20);

/// What [delays] add up to, for the message when every attempt failed.
String _retriesSpent(List<Duration> delays) {
  final paused = delays.fold(Duration.zero, (a, b) => a + b);
  return '${delays.length + 1} attempts, with ${paused.inSeconds} seconds of '
      'pauses between them';
}

/// What to tell a user when every attempt failed on the network.
const _networkAdvice =
    'The build needs to reach GitHub release downloads: check this machine '
    'can, and build again.';

/// Downloads [url] to [outputFile], trying again after each of [delays].
///
/// Public for its tests, which pass no delays.
Future<void> downloadWithRetry(
  String url,
  File outputFile, {
  List<Duration> delays = downloadRetryDelays,
}) async {
  final client = HttpClient()..connectionTimeout = _connectionTimeout;
  Exception? lastError;
  final attempts = delays.length + 1;

  try {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();

        if (response.statusCode == 200) {
          final sink = outputFile.openWrite();
          await response.pipe(sink);
          return;
        } else if (response.statusCode == 404) {
          throw HookException(
            'Native library not found at $url (HTTP 404). '
            'Ensure GitHub Release exists with the correct version.',
          );
        } else if (response.statusCode >= 500 || response.statusCode == 429) {
          // Transient server-side/rate-limit response — let the retry loop
          // below handle it (plain Exception is caught and retried; a
          // HookException would be rethrown immediately and skip the retries).
          await response.drain<void>();
          throw Exception('Transient HTTP ${response.statusCode} from $url');
        } else {
          throw HookException(
            'Failed to download from $url: HTTP ${response.statusCode}',
          );
        }
      } on HookException {
        rethrow;
      } on FileSystemException catch (e) {
        // This machine's, not the network's: another try cannot help.
        throw HookException('Could not write ${outputFile.path}: $e');
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt < attempts) {
          await Future<void>.delayed(delays[attempt - 1]);
        }
      }
    }
  } finally {
    client.close();
  }

  throw HookException(
    'Failed to download from $url after ${_retriesSpent(delays)}. '
    'Last error: $lastError\n$_networkAdvice',
  );
}

/// Extracts a tar.gz archive.
Future<void> _extractTarGz(File archive, Directory outDir) async {
  final result = await Process.run('tar', [
    '-xzf',
    archive.path,
    '-C',
    outDir.path,
  ]);
  if (result.exitCode != 0) {
    throw HookException('Failed to extract tar.gz archive: ${result.stderr}');
  }
}

/// Extracts a zip archive.
Future<void> _extractZip(File archive, Directory outDir) async {
  ProcessResult result;

  if (Platform.isWindows) {
    result = await Process.run('powershell', [
      '-Command',
      'Expand-Archive',
      '-Path',
      archive.path,
      '-DestinationPath',
      outDir.path,
      '-Force',
    ]);
  } else {
    result = await Process.run('unzip', [
      '-o',
      archive.path,
      '-d',
      outDir.path,
    ]);
  }

  if (result.exitCode != 0) {
    throw HookException('Failed to extract zip archive: ${result.stderr}');
  }
}

/// Resolves the expected SHA256 for [archiveFileName] from the release's
/// checksums file.
///
/// Fail-closed: throws a [HookException] if the checksums file cannot be
/// downloaded or has no entry for the archive, so an unverified binary is never
/// used. There is no override. The hook downloads only the release of its own
/// crate version, and every such release publishes the file.
///
/// Public for its tests, which pass no [delays].
Future<String> resolveExpectedChecksum(
  String baseUrl,
  String version,
  String archiveFileName, {
  List<Duration> delays = downloadRetryDelays,
}) async {
  Map<String, String> checksums;
  try {
    checksums = await _downloadChecksums(baseUrl, version, delays);
  } catch (e) {
    throw HookException(
      'Refusing to use an unverified native library: could not download the '
      'SHA256 checksums file for $_crateName-$version.\n'
      'Cause: $e\n'
      'The hook checks every library it downloads, and the check cannot be '
      'skipped.',
    );
  }

  final expected = checksums[archiveFileName];
  if (expected == null) {
    throw HookException(
      'Refusing to use an unverified native library: the checksums file for '
      '$_crateName-$version has no entry for $archiveFileName.\n'
      'Available entries: ${checksums.keys.join(', ')}\n'
      'That release is incomplete. Please report it at '
      'https://github.com/$_githubRepo/issues.',
    );
  }
  return expected;
}

/// Downloads and verifies checksums file from GitHub Release.
///
/// Returns a map of filename -> expected SHA256 hash.
Future<Map<String, String>> _downloadChecksums(
  String baseUrl,
  String version,
  List<Duration> delays,
) async {
  final checksumsUrl = '$baseUrl/$_crateName-$version-checksums.sha256';
  final client = HttpClient()..connectionTimeout = _connectionTimeout;
  Object? lastError;
  final attempts = delays.length + 1;

  try {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final request = await client.getUrl(Uri.parse(checksumsUrl));
        final response = await request.close();

        if (response.statusCode == 200) {
          final content = await response
              .transform(systemEncoding.decoder)
              .join();
          final checksums = _parseChecksums(content);
          if (checksums.isEmpty) {
            // A page from something between this machine and GitHub, such as
            // a proxy's or a captive portal's, rather than a checksums file.
            throw HookException(
              'What $checksumsUrl returned is not a checksums file: no line '
              'of it names a file. Something between this machine and GitHub '
              'may have answered in its place.',
            );
          }
          return checksums;
        }

        await response.drain<void>();
        // 5xx/429 are transient — fall through to retry. Other codes (404, 4xx)
        // are permanent, so fail fast without burning retries.
        if (response.statusCode < 500 && response.statusCode != 429) {
          throw HookException(
            'Failed to download checksums from $checksumsUrl: '
            'HTTP ${response.statusCode}',
          );
        }
        lastError = 'HTTP ${response.statusCode}';
      } on HookException {
        rethrow;
      } catch (e) {
        lastError = e;
      }

      if (attempt < attempts) {
        await Future<void>.delayed(delays[attempt - 1]);
      }
    }
  } finally {
    client.close();
  }

  throw HookException(
    'Failed to download checksums from $checksumsUrl after '
    '${_retriesSpent(delays)}. Last error: $lastError\n$_networkAdvice',
  );
}

/// Parses SHA256 checksums file content.
///
/// Expected format (standard sha256sum output):
/// ```
/// <hash>  <filename>
/// <hash>  <filename>
/// ```
Map<String, String> _parseChecksums(String content) {
  final checksums = <String, String>{};

  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // Format: "<hash>  <filename>" (two spaces between hash and filename)
    // Also support single space for compatibility
    final match = RegExp(r'^([a-fA-F0-9]{64})\s+(.+)$').firstMatch(trimmed);
    if (match != null) {
      final hash = match.group(1)!.toLowerCase();
      final filename = match.group(2)!;
      checksums[filename] = hash;
    }
  }

  return checksums;
}

/// Computes SHA256 hash of a file.
Future<String> _computeFileSha256(File file) async {
  final bytes = await file.readAsBytes();
  final digest = sha256.convert(bytes);
  return digest.toString();
}

/// Verifies file SHA256 hash against expected value.
///
/// Throws [HookException] if verification fails.
Future<void> _verifyChecksum(
  File file,
  String expectedHash,
  String filename,
) async {
  final actualHash = await _computeFileSha256(file);

  if (actualHash != expectedHash.toLowerCase()) {
    // Delete the corrupted/tampered file
    if (file.existsSync()) {
      await file.delete();
    }
    throw HookException(
      'SHA256 verification failed for $filename!\n'
      'Expected: $expectedHash\n'
      'Actual:   $actualHash\n'
      'This may indicate a corrupted download or supply chain attack. '
      'Please report this issue at https://github.com/$_githubRepo/issues',
    );
  }
}

/// Custom exception for hook errors.
class HookException implements Exception {
  HookException(this.message);

  final String message;

  @override
  String toString() => 'HookException: $message';
}
