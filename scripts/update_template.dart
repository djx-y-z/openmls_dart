#!/usr/bin/env dart

/// Apply a copier template update.
///
/// Runs `copier update` for the requested version, reports whatever copier
/// could not merge, checks that the version bump actually landed in
/// `.copier-answers.yml`, and records the adoption in CHANGELOG.md.
///
/// Usage:
///   fvm dart scripts/update_template.dart --version vX.Y.Z [options]
///
/// Options:
///   - `--version <ver>`        Template version to update to (required)
///   - `--skip-changelog`       Apply the update without a CHANGELOG entry
///   - `--json`                 Output the result as JSON
///   - `--ci-output <path>`     Append key=value outputs to a file
///   - `--help, -h`             Show this help
///
/// The CHANGELOG entry needs `AI_MODELS_TOKEN`; without it the update still
/// applies and the entry is skipped.
///
/// Exit codes are deliberately coarse: 0 means copier ran and the working tree
/// now holds the update, **including** when it left conflicts, because that
/// outcome still wants a pull request a human can finish. Anything a caller
/// needs to branch on — conflicts, a missing version bump, a skipped CHANGELOG
/// — is reported through `--ci-output`, not through the status. Only a failure
/// that leaves nothing usable exits non-zero.
///
/// Examples:
///   ```bash
///   # Apply an update locally
///   fvm dart scripts/update_template.dart --version v4.3.0
///
///   # CI: apply and publish the result as step outputs
///   fvm dart scripts/update_template.dart --version v4.3.0 \
///     --ci-output $GITHUB_OUTPUT
///   ```
library;

import 'dart:convert';
import 'dart:io';

import 'src/update_template.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  final jsonOutput = args.contains('--json');
  final skipChangelog = args.contains('--skip-changelog');

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

  if (targetVersion == null || targetVersion.isEmpty) {
    print('Error: --version is required.');
    print('');
    _printUsage();
    exit(2);
  }

  // The version reaches a `--vcs-ref=` argument and, from CI, a branch name.
  // The template's tags are plain semver, optionally v-prefixed.
  if (!RegExp(r'^v?\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$').hasMatch(targetVersion)) {
    print(
      'Error: --version must use the vX.Y.Z or X.Y.Z form, got '
      '"$targetVersion".',
    );
    exit(2);
  }

  if (!jsonOutput) {
    print('');
    print('========================================');
    print('  Template Update');
    print('========================================');
    print('');
  }

  try {
    final result = await applyTemplateUpdate(
      toVersion: targetVersion,
      aiToken: Platform.environment['AI_MODELS_TOKEN'],
      skipChangelog: skipChangelog,
    );

    if (ciOutputPath != null) {
      writeUpdateGitHubOutputs(result: result, outputPath: ciOutputPath);
    }

    if (jsonOutput) {
      print(const JsonEncoder.withIndent('  ').convert(result.toJson()));
    } else {
      printUpdateSummary(result: result);
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
Apply a Copier Template Update

Usage:
  fvm dart scripts/update_template.dart --version <ver> [options]

Options:
  --version <ver>        Template version to update to (required)
  --skip-changelog       Apply the update without a CHANGELOG entry
  --json                 Output the result as JSON
  --ci-output <path>     Append key=value outputs to a file
  --help, -h             Show this help

Environment:
  AI_MODELS_TOKEN        GitHub Models token used for the CHANGELOG entry.
                         Without it the update still applies.

Examples:
  # Apply an update locally
  fvm dart scripts/update_template.dart --version v4.3.0

  # CI: apply and publish the result as step outputs
  fvm dart scripts/update_template.dart --version v4.3.0 \\
    --ci-output \$GITHUB_OUTPUT

Exit codes:
  0 - copier ran and the update is in the working tree (conflicts included;
      inspect the outputs to tell a clean update from one needing a human)
  2 - the update could not be applied
''');
}
