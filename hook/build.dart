/// Build hook for downloading and bundling openmls native libraries.
///
/// This hook is automatically invoked by the Dart/Flutter build system
/// when building applications that depend on the openmls package.
///
/// The hook downloads pre-built native libraries from GitHub Releases
/// based on the target platform and architecture.
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
/// hook prefers a host-matching `rust/target/` build over downloading:
/// ```bash
/// # Native platforms → rust/target/release/lib<crate>.<ext>
/// make build
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
    // Web builds don't produce CodeAssets - they copy WASM files to web/pkg/
    if (!input.config.buildCodeAssets) {
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
    final localLib = _findLocalBuild(packageRoot, targetOS, targetArch);
    if (localLib != null) {
      output.assets.code.add(
        CodeAsset(
          package: _packageName,
          name: _assetId,
          linkMode: DynamicLoadingBundled(),
          file: localLib,
        ),
      );
      // Declare the library itself, not only the manifest. `_findLocalBuild`
      // returned it because it exists right now, so this follows the same
      // declare-only-while-it-exists rule as the skip marker above. Without it
      // the build system keeps a cached result pointing at this path:
      // rebuilding the crate without touching Cargo.toml keeps serving the
      // previous binary, and removing the build (`make clean`) makes the next
      // `dart test` / `dart run` fail outright — hooks_runner reuses the cached
      // asset and the SDK aborts copying a file that is no longer there.
      output.dependencies
        ..add(packageRoot.resolve('rust/Cargo.toml'))
        ..add(localLib);
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
      // Fail-closed — if a trusted checksum cannot be obtained the build aborts
      // (unless explicitly overridden), so a failed/interfered checksum fetch
      // cannot silently downgrade to running an unverified native library.
      final expectedChecksum = await _resolveExpectedChecksum(
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
  // dependencies so a `make build-web` rebuild (which only changes
  // rust/target/wasm32/*) or a manual web/pkg/ wipe (which removes the marker)
  // invalidates a cached hook result instead of keeping web/pkg/ stale.
  for (final fileName in _wasmFiles) {
    output.dependencies.add(
      packageRoot.resolve('rust/target/wasm32/$fileName'),
    );
  }

  // Find the Flutter app root first
  final appRoot = _findAppRoot(input.outputDirectoryShared);
  if (appRoot == null) {
    // ignore: avoid_print
    print('Warning: Could not find Flutter app root for web build');
    return;
  }

  final webPkgDir = Directory.fromUri(appRoot.resolve('web/pkg/'));
  output.dependencies.add(webPkgDir.uri.resolve('$_wasmVersionMarkerName'));

  // Read version from rust/Cargo.toml up front — it keys both the download
  // cache and the freshness check below.
  final version = await _readVersion(packageRoot);

  // Check for local WASM build first (development mode) — takes priority
  // over cached/downloaded files to avoid stale content hash mismatches.
  final localWasmDir = _findLocalWasmBuild(packageRoot);
  if (localWasmDir != null) {
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

  final cacheReady =
      _isCacheComplete(cacheDir) &&
      _wasmFiles.every((f) => File.fromUri(cacheDir.resolve(f)).existsSync());

  // Only touch the network when the version-keyed cache is not already a
  // complete, verified provisioning. This lets an offline re-provision of
  // web/pkg/ (e.g. after a manual wipe) reuse the warm cache instead of failing
  // on an unreachable checksums file.
  if (!cacheReady) {
    // SECURITY: resolve the expected SHA256 up front (fail-closed, see the
    // native path above). The WASM assets are shipped in a single archive, so
    // one checksum covers every file extracted from it.
    final expectedChecksum = await _resolveExpectedChecksum(
      baseUrl,
      version,
      archiveFileName,
    );

    for (final fileName in _wasmFiles) {
      final file = File.fromUri(cacheDir.resolve(fileName));

      if (!file.existsSync()) {
        await _downloadAndExtract(
          '$baseUrl/$archiveFileName',
          cacheDir,
          archiveFileName,
          fileName,
          expectedChecksum: expectedChecksum,
        );
      }

      if (!file.existsSync()) {
        throw HookException('Failed to download WASM file: $fileName');
      }
    }
  }

  // Copy WASM files to web/pkg/ and record the version so the next build can
  // detect an upgrade and refresh instead of serving stale binaries.
  await _copyWasmFilesToAppRoot(cacheDir, webPkgDir);
  _writeWasmVersionMarker(webPkgDir, version);
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

/// Looks for a locally built library in `rust/target/<profile>/`.
///
/// This enables development mode where developers use a locally built library
/// instead of downloading from GitHub Releases. Checks release profile first,
/// then debug.
///
/// A plain `rust/target/<profile>/` build is always a HOST build, so it is only
/// valid when the target OS AND architecture match the host — otherwise we would
/// bundle e.g. a macOS dylib into an iOS app (dyld rejects it at launch) or a
/// wrong-arch `.so`. For any cross-target build this returns null and the hook
/// downloads the correct released binary instead (cross-compiled outputs land in
/// `rust/target/<triple>/release/`, which this intentionally does not read).
///
/// Returns the Uri to the local library if a host-matching build is found, null
/// otherwise.
Uri? _findLocalBuild(Uri packageRoot, OS targetOS, Architecture targetArch) {
  if (targetOS != OS.current || targetArch != Architecture.current) {
    return null;
  }

  final fileName = _getLibraryFileName(targetOS);

  // Try release first, then debug
  for (final profile in ['release', 'debug']) {
    final path = packageRoot.resolve('rust/target/$profile/$fileName');
    if (File.fromUri(path).existsSync()) {
      // ignore: avoid_print
      print('Using local $targetOS-$targetArch build: ${path.toFilePath()}');
      return path;
    }
  }

  return null;
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
/// [expectedChecksum] is the expected SHA256 hash of the archive.
/// If null, verification is skipped (not recommended for production).
Future<void> _downloadAndExtract(
  String url,
  Uri outputDir,
  String archiveFileName,
  String libFileName, {
  String? expectedChecksum,
}) async {
  final outDir = Directory.fromUri(outputDir);
  await outDir.create(recursive: true);

  final archiveFile = File('${outDir.path}/$archiveFileName');

  // Download with retry
  await _downloadWithRetry(url, archiveFile);

  // Verify SHA256 checksum if provided
  if (expectedChecksum != null) {
    await _verifyChecksum(archiveFile, expectedChecksum, archiveFileName);
  }

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

/// Downloads a file with retry logic.
Future<void> _downloadWithRetry(
  String url,
  File outputFile, {
  int maxRetries = 3,
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final client = HttpClient();
  Exception? lastError;

  try {
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
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
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt < maxRetries) {
          await Future<void>.delayed(retryDelay * attempt);
        }
      }
    }
  } finally {
    client.close();
  }

  throw HookException(
    'Failed to download from $url after $maxRetries attempts. '
    'Last error: $lastError',
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

/// Environment variable that downgrades a missing/unfetchable checksum from a
/// hard build failure to a warning. Unset by default, so verification is
/// fail-closed: a network problem or an interfered checksum fetch aborts the
/// build instead of silently loading an unverified native library.
const _allowUnverifiedEnv = 'OPENMLS_ALLOW_UNVERIFIED_DOWNLOAD';

/// Whether the developer has explicitly opted out of checksum verification.
bool _allowUnverifiedDownload() {
  final value = Platform.environment[_allowUnverifiedEnv]?.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
}

/// Resolves the expected SHA256 for [archiveFileName] from the release's
/// checksums file.
///
/// Fail-closed: throws a [HookException] if the checksums file cannot be
/// downloaded or has no entry for the archive, so an unverified binary is never
/// used. Returns `null` (verification skipped, with a warning) only when the
/// [_allowUnverifiedEnv] escape hatch is set.
Future<String?> _resolveExpectedChecksum(
  String baseUrl,
  String version,
  String archiveFileName,
) async {
  Map<String, String> checksums;
  try {
    checksums = await _downloadChecksums(baseUrl, version);
  } catch (e) {
    if (_allowUnverifiedDownload()) {
      // ignore: avoid_print
      print(
        'Warning: could not download SHA256 checksums: $e\n'
        '$_allowUnverifiedEnv is set — proceeding WITHOUT verification.',
      );
      return null;
    }
    throw HookException(
      'Refusing to use an unverified native library: failed to download the '
      'SHA256 checksums file for $_crateName-$version.\n'
      'Cause: $e\n'
      'This guards against a corrupted or tampered download. If you are '
      'deliberately building against a release with no checksums file, set '
      '$_allowUnverifiedEnv=1 to override (NOT recommended for production).',
    );
  }

  final expected = checksums[archiveFileName];
  if (expected == null) {
    if (_allowUnverifiedDownload()) {
      // ignore: avoid_print
      print(
        'Warning: no checksum entry for $archiveFileName.\n'
        '$_allowUnverifiedEnv is set — proceeding WITHOUT verification.',
      );
      return null;
    }
    throw HookException(
      'Refusing to use an unverified native library: the checksums file for '
      '$_crateName-$version has no entry for $archiveFileName.\n'
      'Available entries: ${checksums.keys.join(', ')}\n'
      'Set $_allowUnverifiedEnv=1 to override (NOT recommended for production).',
    );
  }
  return expected;
}

/// Downloads and verifies checksums file from GitHub Release.
///
/// Returns a map of filename -> expected SHA256 hash.
Future<Map<String, String>> _downloadChecksums(
  String baseUrl,
  String version, {
  int maxRetries = 3,
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final checksumsUrl = '$baseUrl/$_crateName-$version-checksums.sha256';
  final client = HttpClient();
  Object? lastError;

  try {
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final request = await client.getUrl(Uri.parse(checksumsUrl));
        final response = await request.close();

        if (response.statusCode == 200) {
          final content = await response
              .transform(systemEncoding.decoder)
              .join();
          return _parseChecksums(content);
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

      if (attempt < maxRetries) {
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  } finally {
    client.close();
  }

  throw HookException(
    'Failed to download checksums from $checksumsUrl after $maxRetries '
    'attempts. Last error: $lastError',
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
