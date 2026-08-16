/// Common utilities for build scripts.
// ignore_for_file: avoid_classes_with_only_static_members
library;

import 'dart:convert';
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

/// Gets the crate name from rust/Cargo.toml `[package]` section.
///
/// This is the `[[package]]` name used in `rust/Cargo.lock`, needed to keep the
/// lockfile's own version stanza in sync when the crate version is bumped.
String getCrateName() {
  final packageDir = getPackageDir();
  final cargoPath = '${packageDir.path}/rust/Cargo.toml';
  final cargoFile = File(cargoPath);

  if (!cargoFile.existsSync()) {
    throw Exception('rust/Cargo.toml not found at: $cargoPath');
  }

  final content = cargoFile.readAsStringSync();

  final nameMatch = RegExp(
    r'^name\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(content);

  if (nameMatch == null) {
    throw Exception(
      'name field not found in rust/Cargo.toml\n'
      'File: $cargoPath\n'
      'Expected format: name = "crate_name"',
    );
  }

  return nameMatch.group(1)!.trim();
}

/// Gets the package version from the pubspec.yaml `version:` field.
///
/// This is the version of the published Dart package, used for pub.dev releases
/// (stage 2). Distinct from [getCrateVersion] (the native `openmls_frb`
/// crate, stage 1).
String getPackageVersion() {
  final packageDir = getPackageDir();
  final pubspecPath = '${packageDir.path}/pubspec.yaml';
  final pubspecFile = File(pubspecPath);

  if (!pubspecFile.existsSync()) {
    throw Exception('pubspec.yaml not found at: $pubspecPath');
  }

  final content = pubspecFile.readAsStringSync();

  final versionMatch = RegExp(
    r'^version:\s*(.+)$',
    multiLine: true,
  ).firstMatch(content);

  if (versionMatch == null) {
    throw Exception(
      'version field not found in pubspec.yaml\n'
      'File: $pubspecPath\n'
      'Expected format: version: X.Y.Z',
    );
  }

  return versionMatch.group(1)!.trim();
}

/// Gets the upstream version (git tag) from rust/Cargo.toml.
///
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

// =============================================================================
// GitHub API
// =============================================================================

/// The token to authenticate GitHub API calls with, or `null` when none is set.
///
/// `GITHUB_TOKEN` is what a workflow exports; `GH_TOKEN` is what the
/// [`gh`](https://cli.github.com) CLI uses, so running the same script locally
/// picks up an existing login instead of needing its own setup.
String? githubToken() {
  for (final name in const ['GITHUB_TOKEN', 'GH_TOKEN']) {
    final value = Platform.environment[name];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Thrown by [githubApiGet] for any response other than 200.
///
/// [toString] is the message alone, so what reaches the terminal is the
/// diagnosis rather than `Exception: ` in front of it.
class GithubApiException implements Exception {
  GithubApiException(this.message);

  /// The full, already formatted explanation — see [describeGithubFailure].
  final String message;

  @override
  String toString() => message;
}

/// `GET`s [url] from the GitHub API, authenticating whenever a token is
/// available, and returns the response body.
///
/// The token is about quota, not access: every repository these scripts read is
/// public. Unauthenticated requests are counted per **source IP** at 60/hour,
/// and GitHub-hosted runners share their egress addresses with every other job
/// on them — so a daily check that asks for nothing but a public release can be
/// refused with a 403 that reads exactly like a permission problem, on a
/// schedule nobody can predict. Reading public data needs no permission beyond
/// the default, so a job's own `GITHUB_TOKEN` is enough even when the
/// repository being read is not the one the job runs in.
///
/// Throws [GithubApiException] on any non-200 response.
Future<String> githubApiGet(
  Uri url, {
  required String accept,
  required String userAgent,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    request.headers.set('Accept', accept);
    request.headers.set('User-Agent', userAgent);

    final token = githubToken();
    if (token != null) {
      request.headers.set('Authorization', 'Bearer $token');
    }

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) return body;

    throw GithubApiException(
      describeGithubFailure(
        url: url,
        statusCode: response.statusCode,
        body: body,
        authenticated: token != null,
        rateLimitRemaining: _firstHeader(
          response.headers,
          'x-ratelimit-remaining',
        ),
        rateLimitReset: _firstHeader(response.headers, 'x-ratelimit-reset'),
      ),
    );
  } finally {
    client.close();
  }
}

/// The first value of header [name], or `null` when it is absent.
///
/// Not `HttpHeaders.value`, which *throws* when a header arrives more than
/// once. This runs while already reporting a failure, and a second exception
/// raised there would replace the diagnosis with noise about the diagnosis.
String? _firstHeader(HttpHeaders headers, String name) {
  final values = headers[name];
  return values == null || values.isEmpty ? null : values.first;
}

/// Builds the message for a failed GitHub API call.
///
/// Pure, and public because it carries the whole diagnosis. A bare status code
/// cannot tell "the quota for this runner's IP is spent" apart from "that
/// repository does not exist", and those call for opposite responses — one is
/// waited out, the other is a typo in a variable. GitHub states the reason in
/// the response body and the quota in `x-ratelimit-*`; both are kept here
/// instead of being discarded with the response.
String describeGithubFailure({
  required Uri url,
  required int statusCode,
  required String body,
  required bool authenticated,
  String? rateLimitRemaining,
  String? rateLimitReset,
}) {
  final lines = <String>[
    'GitHub API request failed with HTTP $statusCode',
    '  GET $url',
  ];

  final message = _githubErrorMessage(body);
  if (message != null) {
    lines.add('  $message');
  }

  if (rateLimitRemaining == '0') {
    final reset = _formatEpochSeconds(rateLimitReset);
    final until = reset == null ? '' : ' until $reset';
    lines.add('  Rate limit exhausted$until.');
  }

  if (!authenticated) {
    lines.add(
      '  The request was unauthenticated: 60/hour, counted per source IP and '
      'shared with every other job on the same runner. Set GITHUB_TOKEN to use '
      'your own quota.',
    );
  }

  return lines.join('\n');
}

/// The `message` field GitHub puts in an error body, or a snippet of the body
/// when it is not the JSON object the API documents.
String? _githubErrorMessage(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      final message = decoded['message'];
      if (message is String && message.isNotEmpty) return message;
    }
  } on FormatException {
    // Not JSON at all — an HTML error page from something in front of the API,
    // most likely. A snippet of it still beats reporting nothing.
  }

  // Cut on code points rather than UTF-16 units, so a body that is not the
  // documented JSON — an HTML page, most likely — cannot end the message on
  // half a character.
  if (trimmed.runes.length <= 200) return trimmed;
  return '${String.fromCharCodes(trimmed.runes.take(200))}…';
}

/// Renders an `x-ratelimit-reset` header (Unix seconds) as a UTC timestamp.
String? _formatEpochSeconds(String? value) {
  final seconds = int.tryParse(value ?? '');
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).toIso8601String();
}
