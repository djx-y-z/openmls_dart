#!/usr/bin/env dart

/// Check for openmls updates.
///
/// This script checks for new openmls releases and optionally updates
/// the upstream dependency tag in rust/Cargo.toml.
///
/// Usage:
///   fvm dart run scripts/check_new_upstream_version.dart [options]
///
/// Options:
///   - `--update`          Update rust/Cargo.toml if new version available
///   - `--version [ver]`   Check/update to specific version
///   - `--force`           Force update even if versions match
///   - `--json`            Output results as JSON
///   - `--ci`              CI mode: write to GITHUB_OUTPUT
///   - `--help, -h`        Show this help
///
/// Examples:
///   ```bash
///   # Just check for updates
///   fvm dart run scripts/check_new_upstream_version.dart
///
///   # Check and update rust/Cargo.toml
///   fvm dart run scripts/check_new_upstream_version.dart --update
///
///   # CI mode (writes to GITHUB_OUTPUT)
///   fvm dart run scripts/check_new_upstream_version.dart --update --ci
///
///   # Update to specific version
///   fvm dart run scripts/check_new_upstream_version.dart --update --version openmls-v0.8.0
///
///   # Output JSON for scripting
///   fvm dart run scripts/check_new_upstream_version.dart --json
///   ```
library;

import 'dart:io';

import 'src/check_updates.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  // Parse arguments
  final doUpdate = args.contains('--update');
  final force = args.contains('--force');
  final jsonOutput = args.contains('--json');
  final ciMode = args.contains('--ci');

  String? targetVersion;
  final versionIndex = args.indexOf('--version');
  if (versionIndex != -1 && versionIndex + 1 < args.length) {
    targetVersion = args[versionIndex + 1];
  }

  if (!jsonOutput) {
    print('');
    print('========================================');
    print('  openmls Update Checker');
    print('========================================');
    print('');
  }

  try {
    // Perform the update check
    final result = await performUpdateCheck(
      targetVersion: targetVersion,
      doUpdate: doUpdate,
      force: force,
      silent: jsonOutput,
    );

    // Write to GITHUB_OUTPUT if in CI mode
    if (ciMode) {
      await writeGitHubOutputs(
        checkResult: result.checkResult,
        updated: result.updated,
      );
    }

    // Output results
    if (jsonOutput) {
      printJsonOutput(checkResult: result.checkResult, updated: result.updated);
    } else {
      printUpdateSummary(
        checkResult: result.checkResult,
        updated: result.updated,
        updatedFiles: result.updatedFiles,
      );
    }

    // Exit code: 0 if up to date or updated, 1 if update available but not applied
    if (result.checkResult.needsUpdate && !doUpdate) {
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
Check for openmls Updates

Usage:
  fvm dart run scripts/check_new_upstream_version.dart [options]

Options:
  --update          Update rust/Cargo.toml if new version available
  --version <ver>   Check/update to specific version
  --force           Force update even if versions match
  --json            Output results as JSON
  --ci              CI mode: write to GITHUB_OUTPUT
  --help, -h        Show this help

Examples:
  # Just check for updates
  fvm dart run scripts/check_new_upstream_version.dart

  # Check and update rust/Cargo.toml
  fvm dart run scripts/check_new_upstream_version.dart --update

  # CI mode (for GitHub Actions)
  fvm dart run scripts/check_new_upstream_version.dart --update --ci

  # Update to specific version
  fvm dart run scripts/check_new_upstream_version.dart --update --version openmls-v0.8.0

  # Output JSON for scripting
  fvm dart run scripts/check_new_upstream_version.dart --json

Exit codes:
  0 - Up to date or successfully updated
  1 - Update available (use --update to apply)
  2 - Error occurred
''');
}
