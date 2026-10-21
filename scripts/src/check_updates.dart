/// Update checking utilities for openmls.
///
/// Provides functions to check for upstream updates, compare versions,
/// and update rust/Cargo.toml. Everything that depends on where the upstream
/// crates come from — what a pin looks like, where the newest release is
/// found, how a bump is written — is asked of [upstreamSource].
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';
import 'upstream_source.dart';

/// Result of checking for updates.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.needsUpdate,
    required this.isPrerelease,
    required this.releaseUrl,
  });

  /// Current upstream pin, from rust/Cargo.toml.
  final String currentVersion;

  /// Pin of the newest upstream release.
  final String latestVersion;

  /// Whether an update is needed.
  final bool needsUpdate;

  /// Whether the latest release is a prerelease.
  final bool isPrerelease;

  /// URL of a page about the latest release.
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

/// Checks for updates from upstream.
///
/// If [targetVersion] is provided, checks against that specific version.
/// Otherwise, asks [upstreamSource] for the newest release.
///
/// Returns [UpdateCheckResult] with comparison information.
Future<UpdateCheckResult> checkForUpdates({
  String? targetVersion,
  bool silent = false,
}) async {
  final source = upstreamSource;

  // With upstream crates, the pin recorded in rust/Cargo.toml, validated — the
  // same shape as anything fetched from upstream, and a missing one fails here
  // instead of reading as "up to date". Without any, this project follows the
  // upstream repository's releases with its own crate version, which carries
  // no tag prefix.
  final currentVersion = source.crates.isEmpty
      ? getCrateVersion()
      : getUpstreamVersion();

  if (!silent) {
    logInfo('Current openmls version: $currentVersion');
  }

  // Get target version (either specified or fetch latest)
  String latestVersion;
  bool isPrerelease;
  String releaseUrl;

  if (targetVersion != null) {
    // Manual workflow input is as untrusted as the upstream API response.
    latestVersion = source.validatePin(
      targetVersion,
      origin: '--version argument',
    );
    isPrerelease = source.isPrerelease(latestVersion);
    releaseUrl = source.pageFor(latestVersion).url;
    if (!silent) {
      logInfo('Checking against specified version: $latestVersion');
    }
  } else {
    if (!silent) {
      logStep('Fetching the latest upstream release...');
    }
    // Validated by the source: the pin is attacker-controlled upstream data
    // that ends up in GITHUB_OUTPUT and, from there, in workflow shell
    // commands and branch names.
    final release = await source.fetchLatest(upstreamHttp);
    latestVersion = release.pin;
    isPrerelease = release.isPrerelease;
    releaseUrl = release.page;
    if (!silent) {
      logInfo('Latest upstream version: $latestVersion');
    }
  }

  // Compare the versions the pins denote, prefixes stripped.
  final comparison = compareVersions(
    source.semverOf(currentVersion),
    source.semverOf(latestVersion),
  );
  final needsUpdate = comparison < 0;

  return UpdateCheckResult(
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    needsUpdate: needsUpdate,
    isPrerelease: isPrerelease,
    releaseUrl: releaseUrl,
  );
}

/// Rewrites the upstream version badge in [readmeContent] to [version].
///
/// [version] is the bare version the pin denotes — [UpstreamSource.semverOf]
/// — and not the pin itself, which every *other* file [updateVersionFiles]
/// writes needs. The badge displays a version, and the library name is
/// already in the badge text, so writing a tag verbatim renders the prefix
/// twice: `badge/openmls-<prefix>1.2.3`.
///
/// A leading `v` is kept exactly as the badge already spells it, and content
/// with no badge comes back unchanged.
String updateReadmeBadge(String readmeContent, String version) {
  // [![name](https://img.shields.io/badge/name-vX.Y.Z-orange.svg)]
  final badgePattern = RegExp(
    r'(\[!\[openmls\]\(https://img\.shields\.io/badge/openmls-)(v?)[0-9]+\.[0-9]+\.[0-9]+[^)]*(-orange\.svg\)\])',
  );
  return readmeContent.replaceAllMapped(
    badgePattern,
    (m) => '${m.group(1)}${m.group(2)}$version${m.group(3)}',
  );
}

/// Update upstream version in all relevant files.
///
/// Updates:
/// - rust/Cargo.toml (upstream dependency pins only)
/// - README.md (badge) - if exists
/// - CLAUDE.md (example) - if exists (enable_claude=true)
/// - .copier-answers.yml (the answers recording the pins) - if exists
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
  final source = upstreamSource;
  final packageDir = getPackageDir();
  final updatedFiles = <String>[];

  // 1. Update rust/Cargo.toml (upstream dependency pins). The whole bump is
  // worked out before anything is written, so a refusal — a yanked release,
  // a requirement that cannot be followed — leaves every file as it was.
  final bump = source.crates.isEmpty
      ? null
      : await source.planBump(newVersion, upstreamHttp);
  if (bump != null) {
    if (!silent) logStep('Updating rust/Cargo.toml...');
    final cargoFile = File('${packageDir.path}/rust/Cargo.toml');
    if (!cargoFile.existsSync()) {
      throw Exception('rust/Cargo.toml not found');
    }
    final cargoContent = source.rewriteCargoToml(
      cargoFile.readAsStringSync(),
      bump,
    );
    // NOTE: the `openmls_frb` crate version is intentionally left
    // untouched here. It is bumped as a deliberate release step (`make
    // release-frb`), not on every upstream dependency update, so that
    // intermediate updates can accumulate on main without publishing a
    // throwaway native binary.

    await cargoFile.writeAsString(cargoContent);
    updatedFiles.add('rust/Cargo.toml');
    if (!silent) {
      logInfo('Updated rust/Cargo.toml: ${source.pinLiteral(newVersion)}');
    }
  }

  // 2. Update README.md badge (if exists)
  final readmeFile = File('${packageDir.path}/README.md');
  if (readmeFile.existsSync()) {
    if (!silent) logStep('Updating README.md badge...');
    final content = readmeFile.readAsStringSync();
    final updated = updateReadmeBadge(content, source.semverOf(newVersion));
    if (updated != content) {
      await readmeFile.writeAsString(updated);
      updatedFiles.add('README.md');
      if (!silent) logInfo('Updated README.md badge');
    }
  }

  // 3. Update CLAUDE.md example (if exists - enable_claude=true)
  final claudeFile = File('${packageDir.path}/CLAUDE.md');
  if (claudeFile.existsSync()) {
    if (!silent) logStep('Updating CLAUDE.md...');
    var content = claudeFile.readAsStringSync();
    // Replace the pin where the documentation quotes the dependency line.
    content = content.replaceAll(
      source.pinLiteral(oldVersion),
      source.pinLiteral(newVersion),
    );
    await claudeFile.writeAsString(content);
    updatedFiles.add('CLAUDE.md');
    if (!silent) logInfo('Updated CLAUDE.md example');
  }

  // 4. Update .copier-answers.yml (if exists), so the next `copier update`
  // renders the dependency lines this project now has.
  final copierFile = File('${packageDir.path}/.copier-answers.yml');
  if (bump != null && copierFile.existsSync()) {
    if (!silent) logStep('Updating .copier-answers.yml...');
    final content = copierFile.readAsStringSync();
    final updated = source.rewriteAnswers(content, bump);
    if (updated != content) {
      await copierFile.writeAsString(updated);
      updatedFiles.add('.copier-answers.yml');
      if (!silent) logInfo('Updated .copier-answers.yml');
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
