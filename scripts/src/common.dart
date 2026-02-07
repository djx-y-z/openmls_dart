/// Common utilities for build scripts.
// ignore_for_file: avoid_classes_with_only_static_members
library;

import 'dart:io';

// =============================================================================
// ANSI Colors for terminal output
// =============================================================================

/// ANSI color utilities for terminal output.
class Colors {
  static const reset = '\x1B[0m';
  static const red = '\x1B[31m';
  static const green = '\x1B[32m';
  static const yellow = '\x1B[33m';
  static const blue = '\x1B[34m';
  static const cyan = '\x1B[36m';
  static const bold = '\x1B[1m';

  static bool get supportsAnsi =>
      stdout.supportsAnsiEscapes &&
      !Platform.environment.containsKey('NO_COLOR');

  static String colorize(String text, String color) {
    if (!supportsAnsi) return text;
    return '$color$text$reset';
  }
}

void logInfo(String message) =>
    print(Colors.colorize('[INFO] $message', Colors.blue));
void logStep(String message) =>
    print(Colors.colorize('[STEP] $message', Colors.cyan));
void logWarn(String message) =>
    print(Colors.colorize('[WARN] $message', Colors.yellow));
void logWarning(String message) => logWarn(message); // Alias for compatibility
void logError(String message) =>
    print(Colors.colorize('[ERROR] $message', Colors.red));
void logSuccess(String message) =>
    print(Colors.colorize('[SUCCESS] $message', Colors.green));

void logPlatform(String platform, String message) =>
    print(Colors.colorize('[$platform] $message', Colors.cyan));

void printBuildHeader(String platform) {
  final separator = '=' * 60;
  print('');
  print(Colors.colorize(separator, Colors.bold));
  print(Colors.colorize('  Building openmls for $platform', Colors.bold));
  print(Colors.colorize(separator, Colors.bold));
  print('');
}

void printBuildSummary(String platform, String outputDir) {
  print('');
  logSuccess('Build complete for $platform!');
  logInfo('Output: $outputDir');
  print('');
}

// =============================================================================
// Directory utilities
// =============================================================================

/// Gets the package root directory.
Directory getPackageDir() {
  // Find package root by looking for pubspec.yaml
  final startDir = Directory.current;
  var dir = startDir;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw Exception(
        'Could not find package root (pubspec.yaml not found)\n'
        'Started search from: ${startDir.path}\n'
        'Searched up to filesystem root.',
      );
    }
    dir = parent;
  }
  return dir;
}

/// Gets a temporary build directory.
String getTempBuildDir() {
  final packageDir = getPackageDir();
  return '${packageDir.path}/temp';
}

/// Ensures a directory exists.
Future<void> ensureDir(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
}

/// Removes a directory if it exists.
Future<void> removeDir(String path) async {
  final dir = Directory(path);
  if (dir.existsSync()) {
    await dir.delete(recursive: true);
  }
}

/// Copies a file.
Future<void> copyFile(String source, String destination) async {
  final sourceFile = File(source);
  if (!sourceFile.existsSync()) {
    throw Exception('Source file not found: $source');
  }

  final destDir = Directory(File(destination).parent.path);
  if (!destDir.existsSync()) {
    await destDir.create(recursive: true);
  }

  await sourceFile.copy(destination);
}

// =============================================================================
// Version utilities
// =============================================================================

/// Gets the crate version from rust/Cargo.toml [package] section.
///
/// This is the version of the openmls_frb crate, used for native library releases.
String getCrateVersion() {
  final packageDir = getPackageDir();
  final cargoPath = '${packageDir.path}/rust/Cargo.toml';
  final cargoFile = File(cargoPath);

  if (!cargoFile.existsSync()) {
    throw Exception(
      'rust/Cargo.toml not found at: $cargoPath\n'
      'Package root: ${packageDir.path}\n'
      'Make sure you are running this from the correct directory.',
    );
  }

  final content = cargoFile.readAsStringSync();

  final versionMatch = RegExp(
    r'^version\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(content);

  if (versionMatch == null) {
    throw Exception(
      'version field not found in rust/Cargo.toml\n'
      'File: $cargoPath\n'
      'Expected format: version = "X.Y.Z"',
    );
  }

  return versionMatch.group(1)!.trim();
}

/// Gets the upstream version (git tag) from rust/Cargo.toml.
///
/// Supports multiple upstream crates from the same git repo.
/// Parses the tag from the first crate: openmls = { git = "...", tag = "vX.Y.Z" }
String getUpstreamVersion() {
  final packageDir = getPackageDir();
  final cargoPath = '${packageDir.path}/rust/Cargo.toml';
  final cargoFile = File(cargoPath);

  if (!cargoFile.existsSync()) {
    throw Exception('rust/Cargo.toml not found');
  }

  final content = cargoFile.readAsStringSync();

  // Extract the tag from first upstream dependency
  // Matches: openmls = { git = "...", tag = "vX.Y.Z" }
  final versionMatch = RegExp(
    r'openmls\s*=\s*\{[^}]*tag\s*=\s*"([^"]+)"',
  ).firstMatch(content);

  if (versionMatch == null) {
    throw Exception(
      'openmls tag not found in rust/Cargo.toml. '
      'Expected format: openmls = { git = "...", tag = "vX.Y.Z" }',
    );
  }

  return versionMatch.group(1)!.trim();
}

/// Compares two semantic versions.
///
/// Returns:
/// - negative if [a] < [b]
/// - zero if [a] == [b]
/// - positive if [a] > [b]
///
/// Handles versions with or without 'v' prefix.
/// Supports prereleases (e.g., "1.0.0-alpha" < "1.0.0").
int compareVersions(String a, String b) {
  final aNorm = _normalizeVersion(a);
  final bNorm = _normalizeVersion(b);

  // Split into main version and prerelease
  final aParts = _parseVersionParts(aNorm);
  final bParts = _parseVersionParts(bNorm);

  // Compare main version parts
  final maxLen = aParts.mainParts.length > bParts.mainParts.length
      ? aParts.mainParts.length
      : bParts.mainParts.length;

  for (var i = 0; i < maxLen; i++) {
    final aNum = i < aParts.mainParts.length ? aParts.mainParts[i] : 0;
    final bNum = i < bParts.mainParts.length ? bParts.mainParts[i] : 0;
    if (aNum != bNum) {
      return aNum - bNum;
    }
  }

  // If main versions are equal, compare prereleases
  // A prerelease version is less than a release version
  if (aParts.prerelease != null && bParts.prerelease == null) {
    return -1; // a is prerelease, b is release
  }
  if (aParts.prerelease == null && bParts.prerelease != null) {
    return 1; // a is release, b is prerelease
  }
  if (aParts.prerelease != null && bParts.prerelease != null) {
    return aParts.prerelease!.compareTo(bParts.prerelease!);
  }

  return 0;
}

/// Normalizes a version string by removing 'v' prefix.
String _normalizeVersion(String version) {
  if (version.startsWith('v') || version.startsWith('V')) {
    return version.substring(1);
  }
  return version;
}

/// Parsed version with main parts and optional prerelease.
class _VersionParts {
  _VersionParts(this.mainParts, this.prerelease);

  final List<int> mainParts;
  final String? prerelease;
}

/// Parses a version string into components.
_VersionParts _parseVersionParts(String version) {
  // Split by hyphen to separate prerelease
  final dashIndex = version.indexOf('-');
  String mainVersion;
  String? prerelease;

  if (dashIndex != -1) {
    mainVersion = version.substring(0, dashIndex);
    prerelease = version.substring(dashIndex + 1);
  } else {
    mainVersion = version;
  }

  // Parse main version numbers
  final parts = mainVersion.split('.').map((p) {
    final num = int.tryParse(p);
    return num ?? 0;
  }).toList();

  return _VersionParts(parts, prerelease);
}

// =============================================================================
// Command execution
// =============================================================================

/// Checks if a command exists in PATH.
Future<bool> commandExists(String command) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    command,
  ]);
  return result.exitCode == 0;
}

/// Checks if a command is available, throws if not.
Future<void> requireCommand(String command) async {
  if (!await commandExists(command)) {
    final pathEnv = Platform.environment['PATH'] ?? 'not set';
    throw Exception(
      'Required command not found: $command\n'
      'Make sure $command is installed and available in your PATH.\n'
      'Current PATH: $pathEnv',
    );
  }
}

/// Runs a command and returns the result.
Future<ProcessResult> runCommand(
  String command,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  logInfo('Running: $command ${args.join(' ')}');
  return Process.run(
    command,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

/// Runs a command and throws if it fails.
Future<void> runCommandOrFail(
  String command,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await runCommand(
    command,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  if (result.exitCode != 0) {
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    final fullCommand = '$command ${args.join(' ')}';
    final cwd = workingDirectory ?? Directory.current.path;

    throw Exception(
      'Command failed with exit code ${result.exitCode}\n'
      'Command: $fullCommand\n'
      'Working directory: $cwd\n'
      '${stdout.isNotEmpty ? 'stdout:\n$stdout\n' : ''}'
      '${stderr.isNotEmpty ? 'stderr:\n$stderr' : ''}',
    );
  }
}

// =============================================================================
// Git utilities
// =============================================================================

/// Clones a git repository.
Future<void> gitClone({
  required String url,
  required String targetDir,
  String? branch,
  int depth = 1,
}) async {
  final args = ['clone', '--depth', depth.toString()];

  if (branch != null) {
    args.addAll(['--branch', branch]);
  }

  args.addAll([url, targetDir]);

  await runCommandOrFail('git', args);
}
