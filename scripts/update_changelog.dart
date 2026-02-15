#!/usr/bin/env dart

/// Update CHANGELOG.md with AI-generated entry for openmls update.
///
/// This script uses GitHub Models API to analyze openmls release notes
/// and generate an appropriate changelog entry.
///
/// Usage:
///   fvm dart scripts/update_changelog.dart [options]
///
/// Options:
///   - `--version [ver]`   openmls version (e.g., v1.0.0)
///   - `--ci`              CI mode: use AI_MODELS_TOKEN for API
///   - `--help, -h`        Show this help
///
/// Environment:
///   AI_MODELS_TOKEN   Required for GitHub Models API authentication
///
/// Examples:
///   ```bash
///   # Update changelog for specific version
///   AI_MODELS_TOKEN=xxx fvm dart scripts/update_changelog.dart --version v1.0.0
///
///   # CI mode (token from environment)
///   fvm dart scripts/update_changelog.dart --version v1.0.0 --ci
///   ```
library;

import 'dart:io';

import 'src/update_changelog.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  // Parse arguments
  final ciMode = args.contains('--ci');

  String? version;
  final versionIndex = args.indexOf('--version');
  if (versionIndex != -1 && versionIndex + 1 < args.length) {
    version = args[versionIndex + 1];
  }

  if (version == null) {
    print('Error: --version is required');
    print('');
    _printUsage();
    exit(1);
  }

  // Check for AI Models token
  final token = Platform.environment['AI_MODELS_TOKEN'];
  if (token == null || token.isEmpty) {
    print('Error: AI_MODELS_TOKEN environment variable is required');
    print('');
    print('Get a token from: https://github.com/settings/tokens');
    print('Required permission: Models → Read only');
    exit(1);
  }

  print('');
  print('========================================');
  print('  CHANGELOG Update with AI');
  print('========================================');
  print('');

  try {
    await updateChangelog(version: version, token: token, ciMode: ciMode);
    print('');
    print('CHANGELOG.md updated successfully!');
  } catch (e) {
    print('Error: $e');
    exit(2);
  }
}

void _printUsage() {
  print('''
Update CHANGELOG.md with AI

Usage:
  fvm dart scripts/update_changelog.dart [options]

Options:
  --version <ver>   openmls version (e.g., v1.0.0) [required]
  --ci              CI mode
  --help, -h        Show this help

Environment:
  AI_MODELS_TOKEN   Required for GitHub Models API authentication

Examples:
  # Update changelog for specific version
  AI_MODELS_TOKEN=xxx fvm dart scripts/update_changelog.dart --version v1.0.0

  # CI mode (token from environment)
  fvm dart scripts/update_changelog.dart --version v1.0.0 --ci
''');
}
