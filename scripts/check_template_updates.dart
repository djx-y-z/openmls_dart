#!/usr/bin/env dart

/// Check for copier template updates.
///
/// This script checks for new versions of the copier template used to
/// generate this project and reports available updates with changelog.
///
/// Usage:
///   fvm dart run scripts/check_template_updates.dart [options]
///
/// Options:
///   - `--version [ver]`        Check against specific version
///   - `--force`                Report update even if versions match
///   - `--json`                 Output results as JSON
///   - `--ci-output <path>`     Write key=value outputs to file (for GitHub Actions)
///   - `--help, -h`             Show this help
///
/// Examples:
///   ```bash
///   # Just check for updates
///   fvm dart run scripts/check_template_updates.dart
///
///   # CI mode (writes outputs to GITHUB_OUTPUT file)
///   fvm dart run scripts/check_template_updates.dart --ci-output $GITHUB_OUTPUT
///
///   # Check against specific version
///   fvm dart run scripts/check_template_updates.dart --version v1.7.0
///
///   # Output JSON for scripting
///   fvm dart run scripts/check_template_updates.dart --json
///   ```
library;

import 'dart:io';

import 'src/check_template_updates.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  // Parse arguments
  final force = args.contains('--force');
  final jsonOutput = args.contains('--json');

  String? targetVersion;
  final versionIndex = args.indexOf('--version');
  if (versionIndex != -1 && versionIndex + 1 < args.length) {
    targetVersion = args[versionIndex + 1];
  }

  String? ciOutputPath;
  final ciOutputIndex = args.indexOf('--ci-output');
  if (ciOutputIndex != -1 && ciOutputIndex + 1 < args.length) {
    ciOutputPath = args[ciOutputIndex + 1];
  }

  if (!jsonOutput) {
    print('');
    print('========================================');
    print('  Template Update Checker');
    print('========================================');
    print('');
  }

  try {
    // Perform the template update check
    final result = await checkForTemplateUpdates(
      targetVersion: targetVersion,
      silent: jsonOutput,
    );

    // Apply --force: treat as needing update even if versions match
    final effectiveResult = force && !result.needsUpdate
        ? TemplateCheckResult(
            currentVersion: result.currentVersion,
            latestVersion: result.latestVersion,
            needsUpdate: true,
            templateRepo: result.templateRepo,
            releaseUrl: result.releaseUrl,
            compareUrl: result.compareUrl,
            changelog: result.changelog,
          )
        : result;

    // Write outputs to file if --ci-output was specified
    if (ciOutputPath != null) {
      await writeTemplateGitHubOutputs(
        result: effectiveResult,
        outputPath: ciOutputPath,
      );
    }

    // Output results
    if (jsonOutput) {
      printTemplateJsonOutput(result: effectiveResult);
    } else {
      printTemplateUpdateSummary(result: effectiveResult);
    }

    // Exit code: 0 if up to date, 1 if update available, 2 if error
    if (effectiveResult.needsUpdate) {
      exit(1); // Signal that update is available
    }
  } catch (e) {
    if (!jsonOutput) {
      print('Error: $e');
    }
    exit(2);
  }
}

void _printUsage() {
  print('''
Check for Copier Template Updates

Usage:
  fvm dart run scripts/check_template_updates.dart [options]

Options:
  --version <ver>        Check against specific version
  --force                Report update even if versions match
  --json                 Output results as JSON
  --ci-output <path>     Write key=value outputs to file (for GitHub Actions)
  --help, -h             Show this help

Examples:
  # Just check for updates
  fvm dart run scripts/check_template_updates.dart

  # CI mode (writes outputs to GITHUB_OUTPUT file)
  fvm dart run scripts/check_template_updates.dart --ci-output \$GITHUB_OUTPUT

  # Check against specific version
  fvm dart run scripts/check_template_updates.dart --version v1.7.0

  # Output JSON for scripting
  fvm dart run scripts/check_template_updates.dart --json

Exit codes:
  0 - Up to date
  1 - Update available
  2 - Error occurred
''');
}
