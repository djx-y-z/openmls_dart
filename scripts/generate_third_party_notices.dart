#!/usr/bin/env dart

/// Generate or verify THIRD_PARTY_NOTICES.txt for the shipped native library.
///
/// The prebuilt `openmls_frb` library is statically linked against its whole
/// Rust dependency tree. MIT, BSD and Apache-2.0 all require the corresponding
/// notices to travel with a binary distribution, and Flutter's
/// `LicenseRegistry` does not cover them — it only aggregates `LICENSE` files
/// of pub packages, and Rust crates are not pub packages.
///
/// The generated file lives at the package root. It is deliberately NOT
/// declared under `flutter: assets:`: a package-declared asset is bundled into
/// every consuming application whether or not it is used. Applications that
/// want to surface the notices at runtime can copy the file into their own
/// assets.
///
/// Usage:
///   fvm dart run scripts/generate_third_party_notices.dart [options]
///
/// Options:
///   - `--check`      Verify the committed file is up to date (no writes)
///   - `--help, -h`   Show this help
///
/// Exit codes:
///   0 - Generated, or (with --check) the committed file is current
///   1 - (--check only) the committed file is missing or out of date
///   2 - Error occurred
library;

import 'dart:io';

import 'src/common.dart';
import 'src/third_party_notices.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  final checkOnly = args.contains('--check');

  try {
    final target = File(noticesPath());

    logStep(
      'Resolving linked crates across ${releaseTargets.length} release '
      'targets...',
    );
    final generated = generateNoticesForRepo(
      onProgress: (t) => logInfo('  $t'),
    );

    if (checkOnly) {
      final drift = describeDrift(generated: generated, committed: target);
      if (drift != null) {
        logError(drift);
        exit(1);
      }
      logSuccess('THIRD_PARTY_NOTICES.txt is up to date');
      return;
    }

    target.writeAsStringSync(generated);
    final sizeKb = (generated.length / 1024).toStringAsFixed(1);
    logSuccess('Wrote ${target.path} ($sizeKb KB)');
  } catch (e) {
    logError('$e');
    exit(2);
  }
}

void _printUsage() {
  // ignore: avoid_print
  print('''
Generate or verify THIRD_PARTY_NOTICES.txt

Usage:
  fvm dart run scripts/generate_third_party_notices.dart [options]

Options:
  --check      Verify the committed file is up to date (no writes)
  --help, -h   Show this help

Exit codes:
  0 - Generated, or (with --check) the committed file is current
  1 - (--check only) the committed file is missing or out of date
  2 - Error occurred
''');
}
