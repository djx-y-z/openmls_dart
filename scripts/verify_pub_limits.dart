#!/usr/bin/env dart

/// Verify that no file pub.dev limits is larger than pub.dev accepts.
///
/// Usage:
///   fvm dart scripts/verify_pub_limits.dart
///
/// Exits 1 when a file is over its limit, 0 otherwise, and warns from 200 KiB.
/// Reads file sizes and pubspec.yaml's `name:` — no build, no network — so it
/// is cheap enough to gate every push.
///
/// See `scripts/src/pub_limits.dart` for why: `dart pub publish --dry-run`
/// checks none of these, and pub.dev refuses the upload after the tag.
library;

import 'dart:io';

import 'src/common.dart';
import 'src/pub_limits.dart';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    print('Usage: fvm dart scripts/verify_pub_limits.dart');
    print('');
    print('Checks README.md, CHANGELOG.md, LICENSE and every example file');
    print('pub.dev could show against its 256 KiB upload limit, and');
    print('pubspec.yaml against its 128 KiB one. Warns from 200 KiB.');
    return;
  }

  logStep('Checking the file sizes pub.dev refuses at upload...');
  final checks = collectPubLimitChecks(getPackageDir());

  final width = checks
      .map((c) => c.path.length)
      .reduce((a, b) => a > b ? a : b);
  for (final c in checks) {
    logInfo('${c.path.padRight(width)}  ${c.bytes} / ${c.limit} bytes');
  }

  // On a green run a [WARN] line is read by nobody, so under GitHub Actions
  // each finding is also an annotation, which the run page shows.
  final annotate = Platform.environment['GITHUB_ACTIONS'] == 'true';

  for (final c in checks.where((c) => c.status == PubLimitStatus.near)) {
    final message =
        '$c — past the ${pubContentWarnAt ~/ 1024} KiB warning line. '
        '${pubLimitAdvice(c)}';
    logWarn(message);
    if (annotate) print('::warning file=${c.path}::$message');
  }

  final over = checks.where((c) => c.status == PubLimitStatus.over).toList();
  if (over.isEmpty) {
    logSuccess('Every file is within what pub.dev accepts.');
    return;
  }
  for (final c in over) {
    final message =
        '$c — the upload will be refused, after the tag. '
        '${pubLimitAdvice(c)}';
    logError(message);
    if (annotate) print('::error file=${c.path}::$message');
  }
  exit(1);
}
