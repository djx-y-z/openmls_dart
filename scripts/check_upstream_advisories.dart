#!/usr/bin/env dart

/// Check openmls's published security advisories against the
/// upstream crates rust/Cargo.lock resolves.
///
/// Reads `openmls/openmls`'s own advisory list, which neither
/// `make rust-audit` (RustSec) nor Dependabot (GitHub's global database) is
/// guaranteed to see — see `src/upstream_advisories.dart`.
///
/// Usage:
///   fvm dart scripts/check_upstream_advisories.dart [options]
///
/// Options:
///   - `--ci`              CI mode: annotate findings and write to GITHUB_OUTPUT
///   - `--help, -h`        Show this help
///
/// Exit codes:
///   0 - no published advisory covers a locked version
///   1 - one does, or its range could not be read and counts as covering it
///   2 - the advisories could not be fetched, so nothing was checked
library;

import 'dart:io';

import 'src/common.dart';
import 'src/upstream_advisories.dart';
import 'src/upstream_source.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }
  final ci = args.contains('--ci');
  final repo = upstreamSource.repo;

  final lockFile = File('${getPackageDir().path}/rust/Cargo.lock');
  if (!lockFile.existsSync()) {
    _finish(
      ci: ci,
      checked: false,
      hits: const [],
      reason: 'rust/Cargo.lock not found',
    );
  }
  final locked = lockedVersions(lockFile.readAsStringSync());

  logStep('Reading the published security advisories of $repo...');
  final List<UpstreamAdvisory> advisories;
  try {
    advisories = await fetchUpstreamAdvisories(repo: repo, http: upstreamHttp);
  } catch (e) {
    _finish(ci: ci, checked: false, hits: const [], reason: '$e');
  }

  final hits = advisoryHits(advisories: advisories, locked: locked);
  if (hits.isEmpty) {
    logSuccess(
      'None of the ${advisories.length} published advisories of $repo '
      'covers a version rust/Cargo.lock resolves.',
    );
  }
  _finish(ci: ci, checked: true, hits: hits);
}

/// Reports the outcome and exits. In CI the outputs are written before the
/// exit, because make turns every failing status into 2 and a caller that
/// needs to tell "covered" from "not checked" can only read it here.
Never _finish({
  required bool ci,
  required bool checked,
  required List<AdvisoryHit> hits,
  String reason = '',
}) {
  if (ci) {
    final githubOutput = Platform.environment['GITHUB_OUTPUT'];
    if (githubOutput != null) {
      final ids = {for (final h in hits) h.advisory.ghsaId}.join(',');
      File(githubOutput).writeAsStringSync(
        'checked=$checked\n'
        'affected=${hits.isNotEmpty}\n'
        'advisories=$ids\n',
        mode: FileMode.append,
      );
    }
  }
  if (!checked) {
    final message =
        'Upstream advisories were NOT checked, which is not the same as '
        'none being found: $reason';
    logError(message);
    if (ci) print('::error::${escapeWorkflowCommand(message)}');
    exit(2);
  }
  for (final hit in hits) {
    logError(hit.describe());
    if (ci) print('::error::${escapeWorkflowCommand(hit.describe())}');
  }
  exit(hits.isEmpty ? 0 : 1);
}

void _printUsage() {
  print('''
Check openmls's published security advisories against rust/Cargo.lock

Usage:
  fvm dart scripts/check_upstream_advisories.dart [options]

Options:
  --ci          CI mode: annotate findings and write to GITHUB_OUTPUT
  --help, -h    Show this help

Environment:
  GITHUB_TOKEN  Optional, for quota only: the advisories are public.
                GH_TOKEN, which the gh CLI uses, works too.

Exit codes:
  0 - no published advisory covers a locked version
  1 - one does, or its range could not be read and counts as covering it
  2 - the advisories could not be fetched, so nothing was checked
''');
}
