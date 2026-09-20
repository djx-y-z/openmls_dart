#!/usr/bin/env dart

/// Refuse a resolved dependency graph that enables a feature which must not ship.
///
/// Usage:
///   fvm dart scripts/verify_feature_graph.dart
///
/// Exits 0 when the graph is clean, 1 when it is not. Runs `cargo tree`, which
/// resolves but does not compile, so it is cheap enough to gate every push.
///
/// See `scripts/src/feature_graph.dart` for what is forbidden and why a
/// manifest comment cannot enforce it.
library;

import 'dart:convert';
import 'dart:io';

import 'src/common.dart';
import 'src/feature_graph.dart';

/// `--edges normal`: the graph that ends up INSIDE the shipped library.
/// Build-dependencies and dev-dependencies compile on the way there without
/// contributing features to it, and including them would mean a test-only
/// dependency could redden a release that is fine.
///
/// `--target all`: the union over every platform, so a dependency that turns
/// the feature on only for, say, wasm32 is still caught. A clean union means
/// every individual target is clean, which one host-shaped run cannot show.
///
/// `--locked`: read `Cargo.lock` as committed instead of re-resolving, so the
/// answer is a property of this revision rather than of the machine and the
/// day.
///
/// ⚠ `--manifest-path` rather than `cd rust`, which is the OPPOSITE of what
/// `make rust-clippy-web` must do — there, invoking cargo from the repository
/// root drops the wasm32 rustflags in `rust/.cargo/config.toml` and lints a
/// configuration the crate never builds under. It is safe here because that
/// file carries rustflags alone, and rustflags do not reach resolution: this
/// command resolves without compiling. Measured rather than reasoned — both
/// invocations emit the same 345 lines, byte for byte.
const _cargoTreeArgs = [
  'tree',
  '--manifest-path',
  'rust/Cargo.toml',
  '--locked',
  '--edges',
  'normal',
  '--target',
  'all',
  '--prefix',
  'none',
  '--format',
  '{p}|{f}',
];

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    print('Usage: fvm dart scripts/verify_feature_graph.dart');
    print('');
    print('Checks the RESOLVED cargo feature graph — not the manifest text —');
    print('for features that must never be enabled in a shipped binary.');
    print('Currently: openmls must carry neither `test-utils` nor');
    print('`backtrace`, either of which routes a symbolized backtrace into');
    print('the ordinary error channel out to the Dart caller.');
    return;
  }

  logStep('Checking the resolved cargo feature graph...');

  final result = Process.runSync('cargo', _cargoTreeArgs);
  if (result.exitCode != 0) {
    logError('cargo tree failed (exit ${result.exitCode}):');
    stderr.writeln(result.stderr);
    exit(1);
  }

  final List<FeatureViolation> violations;
  try {
    violations = findForbiddenFeatures(
      const LineSplitter().convert(result.stdout as String),
    );
  } on FeatureGraphException catch (e) {
    logError(e.message);
    exit(1);
  }

  if (violations.isNotEmpty) {
    logError('Forbidden features are enabled in the shipped dependency graph:');
    for (final v in violations) {
      stderr.writeln('  ${v.crate.name} v${v.crate.version} → ${v.feature}');
      stderr.writeln('    enabled features: ${v.crate.features.join(', ')}');
    }
    stderr.writeln('');
    stderr.writeln(
      'Nothing in rust/Cargo.toml has to ask for these for them to appear: '
      'cargo unifies features across the graph, so a dependency added '
      'transitively — by a version bump nobody here reviewed — can turn one '
      'on. Find who does with:',
    );
    stderr.writeln('');
    for (final v in violations) {
      stderr.writeln(
        '  cd rust && cargo tree --locked --edges normal --target all '
        '--invert ${v.crate.name} --format \'{p}|{f}\'',
      );
    }
    exit(1);
  }

  logSuccess('Feature graph clean: no forbidden feature is enabled.');
}
