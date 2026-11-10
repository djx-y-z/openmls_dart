/// Fail on a bridged function the example's integration tests never call.
///
/// Reads the report `make coverage-example` leaves. See
/// `scripts/src/example_coverage.dart` for the rules.
///
/// Usage: make verify-example-coverage [ARGS=<path to lcov.info>]
library;

import 'dart:io';

import 'src/example_coverage.dart';

void main(List<String> args) {
  final report = File(args.isEmpty ? 'example/coverage/lcov.info' : args.first);
  if (!report.existsSync()) {
    stderr.writeln(
      'No coverage report at ${report.path}. Run `make coverage-example '
      'ARGS="-d <device>"`.',
    );
    exit(1);
  }

  final coverage = verifyExampleCoverage(
    lcov: report.readAsStringSync(),
    generated: File(generatedBindings).readAsStringSync(),
  );
  stdout.writeln(coverageSummary(coverage));

  final problems = coverage.problems;
  if (problems.isEmpty) return;
  problems.forEach(stderr.writeln);
  exit(1);
}
