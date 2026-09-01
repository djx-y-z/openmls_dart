#!/usr/bin/env dart

/// Update CHANGELOG.md with AI-generated entry for openmls update.
///
/// Hands the openmls release notes and the upstream commit list to an AI
/// model and files the resulting entry in CHANGELOG.md.
///
/// Usage:
///   fvm dart scripts/update_changelog.dart [options]
///
/// Options:
///   - `--version [ver]`     openmls version (e.g., v1.0.0)
///   - `--from [ver]`        Previous version — enables upstream commit analysis
///   - `--ci`                CI mode
///   - `--codegen [result]`  `unchanged` | `changed` | `not-run`
///   - `--ci-output [path]`  Append key=value outputs to a file
///   - `--help, -h`          Show this help
///
/// Environment:
///   AI_MODELS           Ordered `provider/model` list. Optional.
///   ANTHROPIC_API_KEY   Key for `anthropic/...` entries.
///   GEMINI_API_KEY      Key for `google/...` entries.
///   OPENROUTER_API_KEY  Key for `openrouter/vendor/model` entries.
///
/// Examples:
///   ```bash
///   # Update changelog for specific version
///   AI_MODELS=anthropic/claude-opus-5 ANTHROPIC_API_KEY=xxx \
///     fvm dart scripts/update_changelog.dart --version v1.0.0
///
///   # CI mode (key from environment)
///   fvm dart scripts/update_changelog.dart --version v1.0.0 --ci
///   ```
library;

import 'dart:io';

import 'src/ai_client.dart';
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

  String? fromVersion;
  final fromIndex = args.indexOf('--from');
  if (fromIndex != -1 && fromIndex + 1 < args.length) {
    fromVersion = args[fromIndex + 1];
  }

  // Three states, all meaningful: the pipeline ran codegen and the bindings
  // held; it ran and they moved; or it never got that far. Absent, the prompt
  // is told nothing and forbidden from guessing.
  String? codegenResult;
  final codegenIndex = args.indexOf('--codegen');
  if (codegenIndex != -1 && codegenIndex + 1 < args.length) {
    codegenResult = args[codegenIndex + 1];
    const allowed = {'unchanged', 'changed', 'not-run'};
    if (!allowed.contains(codegenResult)) {
      print(
        'Error: --codegen must be one of ${allowed.join(', ')}, got '
        '"$codegenResult".',
      );
      exit(1);
    }
    // Equivalent to omitting it, and the value CI passes when codegen failed.
    if (codegenResult == 'not-run') codegenResult = null;
  }

  String? ciOutputPath;
  final ciOutputIndex = args.indexOf('--ci-output');
  if (ciOutputIndex != -1 && ciOutputIndex + 1 < args.length) {
    ciOutputPath = args[ciOutputIndex + 1];
  }

  if (version == null) {
    print('Error: --version is required');
    print('');
    _printUsage();
    exit(1);
  }

  print('');
  print('========================================');
  print('  CHANGELOG Update with AI');
  print('========================================');
  print('');

  // Which models are usable is decided before any work is done, and reported
  // in full: a typo'd entry or a missing key is the difference between an
  // AI-written entry and a pull request nobody notices is missing one.
  final resolution = resolveAiModelsFromEnv();
  logAiModelResolution(resolution);

  if (resolution.isEmpty) {
    final configured = Platform.environment[aiModelsEnvVar];
    print('');
    print('Error: no AI model is configured, so there is nothing to ask.');
    print('');
    print(
      '  $aiModelsEnvVar: '
      '${configured == null || configured.trim().isEmpty ? '(not set — there is no default)' : configured}',
    );
    print('  Name a `provider/model` list, e.g. "$aiModelsExample",');
    print('  and set the key for each provider you name:');
    for (final provider in aiProviderKeyEnvVars.entries) {
      print('    ${provider.key.padRight(11)} → ${provider.value}');
    }
    exit(1);
  }

  try {
    final model = await updateChangelog(
      version: version,
      fromVersion: fromVersion,
      models: resolution.usable,
      codegenResult: codegenResult,
      ciMode: ciMode,
    );

    // Published so the pull request can say which model wrote the entry.
    // Without it, a silently failing first provider shows up only as a change
    // in house style that nobody attributes to a provider switch.
    if (ciOutputPath != null) {
      File(
        ciOutputPath,
      ).writeAsStringSync('ai_provider=$model\n', mode: FileMode.append);
    }

    print('');
    print('CHANGELOG.md updated successfully by $model!');
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
  --version <ver>     openmls version (e.g., v1.0.0) [required]
  --from <ver>        Previous openmls version — when given, the
                      upstream commit list between the two tags is fed to the
                      AI for a more complete changelog entry, and a compare
                      link is used instead of a release-notes link
  --ci                CI mode
  --codegen <result>  What `make codegen` did in this run:
                      `unchanged` | `changed` | `not-run`. Given, the entry may
                      state the result; omitted, it must not mention codegen at
                      all rather than infer it from the house style
  --ci-output <path>  Append key=value outputs to a file (writes
                      `ai_provider=<provider/model>`)
  --help, -h          Show this help

Environment:
  $aiModelsEnvVar           Ordered comma-separated `provider/model` list,
                      highest priority first. REQUIRED — there is no default,
                      and with it unset no model is called at all.
                      Example: `$aiModelsExample`.
                      An entry whose key is unset is skipped.
  ANTHROPIC_API_KEY   Key for `anthropic/...` entries.
  GEMINI_API_KEY      Key for `google/...` entries.
  OPENROUTER_API_KEY  Key for `openrouter/vendor/model` entries — an
                      aggregator, so the model half carries its own slash.
  $aiEffortEnvVar          How hard to think: ${aiEffortLevels.join(' | ')}.
                      Optional; defaults to `$defaultAiEffort`.

Examples:
  # Update changelog for specific version
  AI_MODELS=anthropic/claude-opus-5 ANTHROPIC_API_KEY=xxx \
    fvm dart scripts/update_changelog.dart --version v1.0.0

  # CI mode (key from environment)
  fvm dart scripts/update_changelog.dart --version v1.0.0 --ci
''');
}
