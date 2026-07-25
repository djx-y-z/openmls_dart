/// Update checking utilities for openmls.
///
/// Provides functions to check for upstream updates, compare versions,
/// and update rust/Cargo.toml.
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// GitHub repository for upstream openmls releases.
const _upstreamRepo = 'openmls/openmls';

/// Tag prefix used by the upstream repo for openmls releases.
const _tagPrefix = 'openmls-v';

/// Accepts exactly `<_tagPrefix>X.Y.Z` with optional semver prerelease
/// identifiers. Built from [_tagPrefix] rather than hardcoded, so a repo whose
/// upstream uses a non-default prefix validates its own tags correctly.
final _upstreamTagPattern = RegExp(
  '^${RegExp.escape(_tagPrefix)}'
  r'(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

/// Validates an upstream release tag before it is used or exported.
///
/// Tag values reach `GITHUB_OUTPUT` and from there workflow shell commands and
/// branch names, so anything that is not the exact expected tag form is
/// rejected. Applies to upstream API data, manual workflow input, and the tag
/// recorded in `rust/Cargo.toml` alike.
String validateUpstreamTag(String tag) {
  if (!_upstreamTagPattern.hasMatch(tag)) {
    throw FormatException('Refusing unexpected upstream tag format: "$tag"');
  }
  return tag;
}

/// Result of checking for updates.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.needsUpdate,
    required this.isPrerelease,
    required this.releaseUrl,
  });

  /// Current version from rust/Cargo.toml (upstream tag).
  final String currentVersion;

  /// Latest version from upstream GitHub releases.
  final String latestVersion;

  /// Whether an update is needed.
  final bool needsUpdate;

  /// Whether the latest release is a prerelease.
  final bool isPrerelease;

  /// URL to the release page on GitHub.
  final String releaseUrl;

  Map<String, dynamic> toJson() => {
    'current_version': currentVersion,
    'latest_version': latestVersion,
    'needs_update': needsUpdate,
    'is_prerelease': isPrerelease,
    'release_url': releaseUrl,
  };
}

/// Result of performing an update check with optional update.
class PerformUpdateResult {
  const PerformUpdateResult({
    required this.checkResult,
    required this.updated,
    this.updatedFiles = const [],
  });

  /// The update check result.
  final UpdateCheckResult checkResult;

  /// Whether files were updated.
  final bool updated;

  /// List of files that were updated.
  final List<String> updatedFiles;
}

/// Result of [updateVersionFiles].
class UpdateFilesResult {
  const UpdateFilesResult({required this.updatedFiles});

  final List<String> updatedFiles;
}

/// Checks for updates from upstream GitHub releases.
///
/// If [targetVersion] is provided, checks against that specific version.
/// Otherwise, fetches the latest release from GitHub.
///
/// Returns [UpdateCheckResult] with comparison information.
Future<UpdateCheckResult> checkForUpdates({
  String? targetVersion,
  bool silent = false,
}) async {
  // Read current version from rust/Cargo.toml
  final currentVersion = validateUpstreamTag(getUpstreamVersion());

  if (!silent) {
    logInfo('Current openmls version: $currentVersion');
  }

  // Get target version (either specified or fetch latest)
  String latestVersion;
  bool isPrerelease;
  String releaseUrl;

  if (targetVersion != null) {
    // Manual workflow input is as untrusted as the upstream API response.
    latestVersion = validateUpstreamTag(targetVersion);
    isPrerelease = _isPrerelease(latestVersion);
    releaseUrl =
        'https://github.com/$_upstreamRepo/releases/tag/$targetVersion';
    if (!silent) {
      logInfo('Checking against specified version: $latestVersion');
    }
  } else {
    if (!silent) {
      logStep('Fetching latest release from GitHub...');
    }
    final release = await _fetchLatestRelease();
    // The tag name is attacker-controlled upstream data that ends up in
    // GITHUB_OUTPUT and, from there, in workflow shell commands and branch
    // names. validateUpstreamTag rejects unexpected prefixes and characters.
    latestVersion = validateUpstreamTag(release['tag_name'] as String);
    isPrerelease = release['prerelease'] as bool? ?? false;
    releaseUrl =
        release['html_url'] as String? ??
        'https://github.com/$_upstreamRepo/releases';
    if (!silent) {
      logInfo('Latest upstream version: $latestVersion');
    }
  }

  // Compare versions (normalize for comparison)
  final currentNorm = _normalizeVersion(currentVersion);
  final latestNorm = _normalizeVersion(latestVersion);
  final comparison = compareVersions(currentNorm, latestNorm);
  final needsUpdate = comparison < 0;

  return UpdateCheckResult(
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    needsUpdate: needsUpdate,
    isPrerelease: isPrerelease,
    releaseUrl: releaseUrl,
  );
}

/// Normalize version by removing the tag prefix for comparison.
///
/// Strips the configured tag prefix ('openmls-v') and falls back
/// to stripping a plain 'v'/'V' prefix if the tag prefix doesn't match.
String _normalizeVersion(String version) {
  if (version.startsWith(_tagPrefix)) {
    return version.substring(_tagPrefix.length);
  }
  if (version.startsWith('v') || version.startsWith('V')) {
    return version.substring(1);
  }
  return version;
}

/// Check if a version is a prerelease.
///
/// Normalizes the version first to strip the tag prefix, then
/// checks for prerelease indicators like `-alpha`, `-beta`, `-rc`.
bool _isPrerelease(String version) {
  final normalized = _normalizeVersion(version);
  return normalized.contains('-') ||
      normalized.contains('alpha') ||
      normalized.contains('beta') ||
      normalized.contains('rc');
}

/// Fetch the latest release from GitHub API.
Future<Map<String, dynamic>> _fetchLatestRelease() async {
  final client = HttpClient();
  try {
    final url = Uri.parse(
      'https://api.github.com/repos/$_upstreamRepo/releases/latest',
    );
    final request = await client.getUrl(url);
    request.headers.set('Accept', 'application/vnd.github.v3+json');
    request.headers.set('User-Agent', 'openmls-update-checker');

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      return jsonDecode(body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to fetch latest release: ${response.statusCode}');
    }
  } finally {
    client.close();
  }
}

/// Update upstream version in all relevant files.
///
/// Updates:
/// - rust/Cargo.toml (upstream dependency tags only)
/// - README.md (badge) - if exists
/// - CLAUDE.md (example) - if exists (enable_claude=true)
/// - .copier-answers.yml (upstream_version) - if exists
///
/// Does NOT bump the `openmls_frb` crate version: that is a deliberate
/// release decision made later via `make release-frb` (which bumps the crate
/// and pushes the `openmls_frb-v*` tag that triggers the native build). See
/// the two-stage release flow in CLAUDE.md.
///
/// Returns the list of updated file names.
Future<UpdateFilesResult> updateVersionFiles({
  required String newVersion,
  required String oldVersion,
  bool silent = false,
}) async {
  final packageDir = getPackageDir();
  final updatedFiles = <String>[];
  // 1. Update rust/Cargo.toml (upstream dependency tags)
  if (!silent) logStep('Updating rust/Cargo.toml...');
  final cargoFile = File('${packageDir.path}/rust/Cargo.toml');
  if (!cargoFile.existsSync()) {
    throw Exception('rust/Cargo.toml not found');
  }
  var cargoContent = cargoFile.readAsStringSync();

  // Update all upstream dependency tags

  final tagPattern1 = RegExp(r'(openmls\s*=\s*\{[^}]*tag\s*=\s*")[^"]+(")');
  cargoContent = cargoContent.replaceAllMapped(
    tagPattern1,
    (match) => '${match.group(1)}$newVersion${match.group(2)}',
  );

  final tagPattern2 = RegExp(
    r'(openmls_rust_crypto\s*=\s*\{[^}]*tag\s*=\s*")[^"]+(")',
  );
  cargoContent = cargoContent.replaceAllMapped(
    tagPattern2,
    (match) => '${match.group(1)}$newVersion${match.group(2)}',
  );

  final tagPattern3 = RegExp(
    r'(openmls_basic_credential\s*=\s*\{[^}]*tag\s*=\s*")[^"]+(")',
  );
  cargoContent = cargoContent.replaceAllMapped(
    tagPattern3,
    (match) => '${match.group(1)}$newVersion${match.group(2)}',
  );

  final tagPattern4 = RegExp(
    r'(openmls_traits\s*=\s*\{[^}]*tag\s*=\s*")[^"]+(")',
  );
  cargoContent = cargoContent.replaceAllMapped(
    tagPattern4,
    (match) => '${match.group(1)}$newVersion${match.group(2)}',
  );

  final tagPattern5 = RegExp(
    r'(openmls_memory_storage\s*=\s*\{[^}]*tag\s*=\s*")[^"]+(")',
  );
  cargoContent = cargoContent.replaceAllMapped(
    tagPattern5,
    (match) => '${match.group(1)}$newVersion${match.group(2)}',
  );

  // NOTE: the `openmls_frb` crate version is intentionally left untouched
  // here. It is bumped as a deliberate release step (`make release-frb`), not
  // on every upstream dependency update, so that intermediate updates can
  // accumulate on main without publishing a throwaway native binary.

  await cargoFile.writeAsString(cargoContent);
  updatedFiles.add('rust/Cargo.toml');
  if (!silent) logInfo('Updated rust/Cargo.toml: tag = "$newVersion"');

  // 2. Update README.md badge (if exists)
  final readmeFile = File('${packageDir.path}/README.md');
  if (readmeFile.existsSync()) {
    if (!silent) logStep('Updating README.md badge...');
    var content = readmeFile.readAsStringSync();
    // Match badge pattern: [![name](https://img.shields.io/badge/name-vX.Y.Z-orange.svg)]
    final badgePattern = RegExp(
      r'(\[!\[openmls\]\(https://img\.shields\.io/badge/openmls-)v?[0-9]+\.[0-9]+\.[0-9]+[^)]*(-orange\.svg\)\])',
    );
    if (badgePattern.hasMatch(content)) {
      content = content.replaceAllMapped(
        badgePattern,
        (match) => '${match.group(1)}$newVersion${match.group(2)}',
      );
      await readmeFile.writeAsString(content);
      updatedFiles.add('README.md');
      if (!silent) logInfo('Updated README.md badge');
    }
  }

  // 3. Update CLAUDE.md example (if exists - enable_claude=true)
  final claudeFile = File('${packageDir.path}/CLAUDE.md');
  if (claudeFile.existsSync()) {
    if (!silent) logStep('Updating CLAUDE.md...');
    var content = claudeFile.readAsStringSync();
    // Replace version in example: tag = "vX.Y.Z"
    content = content.replaceAll('tag = "$oldVersion"', 'tag = "$newVersion"');
    await claudeFile.writeAsString(content);
    updatedFiles.add('CLAUDE.md');
    if (!silent) logInfo('Updated CLAUDE.md example');
  }

  // 4. Update .copier-answers.yml (if exists)
  final copierFile = File('${packageDir.path}/.copier-answers.yml');
  if (copierFile.existsSync()) {
    if (!silent) logStep('Updating .copier-answers.yml...');
    var content = copierFile.readAsStringSync();
    // Accept double-quoted ("vX.Y.Z"), single-quoted ('vX.Y.Z'), and
    // unquoted (vX.Y.Z) YAML values — preserve the original quoting style.
    final copierPattern = RegExp(
      '''(upstream_version:\\s*)(["']?)([^"'\\s]+)\\2''',
    );
    if (copierPattern.hasMatch(content)) {
      content = content.replaceFirstMapped(copierPattern, (match) {
        final quote = match.group(2) ?? '';
        return '${match.group(1)}$quote$newVersion$quote';
      });
      await copierFile.writeAsString(content);
      updatedFiles.add('.copier-answers.yml');
      if (!silent) logInfo('Updated .copier-answers.yml: upstream_version');
    }
  }

  return UpdateFilesResult(updatedFiles: updatedFiles);
}

/// Perform full update check with optional update.
Future<PerformUpdateResult> performUpdateCheck({
  String? targetVersion,
  bool doUpdate = false,
  bool force = false,
  bool silent = false,
}) async {
  final checkResult = await checkForUpdates(
    targetVersion: targetVersion,
    silent: silent,
  );

  final filesResult = doUpdate && (checkResult.needsUpdate || force)
      ? await updateVersionFiles(
          newVersion: checkResult.latestVersion,
          oldVersion: checkResult.currentVersion,
          silent: silent,
        )
      : const UpdateFilesResult(updatedFiles: []);

  return PerformUpdateResult(
    checkResult: checkResult,
    updated: filesResult.updatedFiles.isNotEmpty,
    updatedFiles: filesResult.updatedFiles,
  );
}

/// Write outputs to GitHub Actions output file.
Future<void> writeGitHubOutputs({
  required UpdateCheckResult checkResult,
  required bool updated,
}) async {
  final githubOutput = Platform.environment['GITHUB_OUTPUT'];
  if (githubOutput == null) return;

  final file = File(githubOutput);
  final buffer = StringBuffer()
    ..writeln('current_version=${checkResult.currentVersion}')
    ..writeln('latest_version=${checkResult.latestVersion}')
    ..writeln('needs_update=${checkResult.needsUpdate}')
    ..writeln('is_prerelease=${checkResult.isPrerelease}')
    ..writeln('release_url=${checkResult.releaseUrl}')
    ..writeln('updated=$updated');

  file.writeAsStringSync(buffer.toString(), mode: FileMode.append);
}

/// Print results as JSON.
void printJsonOutput({
  required UpdateCheckResult checkResult,
  required bool updated,
}) {
  final output = <String, dynamic>{...checkResult.toJson(), 'updated': updated};

  const encoder = JsonEncoder.withIndent('  ');
  print(encoder.convert(output));
}

/// Print update summary in human-readable format.
void printUpdateSummary({
  required UpdateCheckResult checkResult,
  required bool updated,
  List<String> updatedFiles = const [],
}) {
  print('');
  print('========================================');
  print('  Openmls Update Check');
  print('========================================');
  print('');
  print('  Current version: ${checkResult.currentVersion}');
  print('  Latest version:  ${checkResult.latestVersion}');
  print('');

  if (checkResult.needsUpdate) {
    print('  ${Colors.colorize('Update available!', Colors.green)}');
  } else {
    print('  ${Colors.colorize('Already up to date', Colors.green)}');
  }

  if (checkResult.isPrerelease) {
    print('  ${Colors.colorize('(pre-release)', Colors.yellow)}');
  }

  if (updated && updatedFiles.isNotEmpty) {
    print('');
    print('  ${Colors.colorize('Files updated:', Colors.green)}');
    for (final file in updatedFiles) {
      print('    ${Colors.colorize('✓', Colors.green)} $file');
    }
    print('');
    print('  ${Colors.colorize('Next steps:', Colors.cyan)}');
    print('    1. Run: make rust-update (to update Cargo.lock)');
    print('    2. Run: make codegen (if API changed)');
    print('    3. Update CHANGELOG.md');
    print('    4. Run: make test');
    print('    5. Commit and push changes');
  }
  print('');
}
