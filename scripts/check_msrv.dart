#!/usr/bin/env dart

/// Check the minimum Rust version against what the dependency graph needs.
///
/// The floor is declared in `rust/Cargo.toml` (`rust-version`, what CI's MSRV
/// check builds with), rendered there from the `rust_version` answer in
/// `.copier-answers.yml`, and advertised in `README.md` and `CONTRIBUTING.md`
/// next to the rustup link. An upstream update can raise the floor its crates
/// declare, and then every one of those has to follow.
///
/// Usage:
///   fvm dart scripts/check_msrv.dart [options]
///
/// Options:
///   - `--update`            Raise them all to the higher of the declared
///                           floor and the graph's
///   - `--ci-output [path]`  Append `msrv_from`, `msrv_to` and `msrv_moved`
///                           to a file
///   - `--help, -h`          Show this help
///
/// Exit codes:
///   0 - Consistent, and at or above the graph's floor (or updated)
///   1 - Inconsistent, or below the graph's floor (use --update to fix)
///   2 - Error occurred
library;

import 'dart:convert';
import 'dart:io';

import 'src/common.dart';
import 'src/msrv.dart';

const _manifest = 'rust/Cargo.toml';
const _answers = '.copier-answers.yml';
const _docs = ['README.md', 'CONTRIBUTING.md'];

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }
  final update = args.contains('--update');
  String? ciOutput;
  final ciOutputIndex = args.indexOf('--ci-output');
  if (ciOutputIndex != -1 && ciOutputIndex + 1 < args.length) {
    ciOutput = args[ciOutputIndex + 1];
  }

  final packageDir = getPackageDir();
  File file(String path) => File('${packageDir.path}/$path');

  final declared = rustVersionIn(file(_manifest).readAsStringSync());
  if (declared == null || !isRustVersion(declared)) {
    logError('$_manifest declares no rust-version this script can read.');
    exit(2);
  }

  // The graph as it is locked: `--locked`, so this reads the resolution the
  // update produced and never makes one of its own.
  final metadata = await Process.run('cargo', [
    'metadata',
    '--manifest-path',
    _manifest,
    '--format-version',
    '1',
    '--locked',
  ], workingDirectory: packageDir.path);
  if (metadata.exitCode != 0) {
    logError('cargo metadata failed: ${(metadata.stderr as String).trim()}');
    exit(2);
  }
  final floor = floorOf(
    jsonDecode(metadata.stdout as String) as Map<String, dynamic>,
  );

  final target =
      floor != null && compareRustVersions(floor.version, declared) > 0
      ? floor.version
      : declared;
  logInfo('$_manifest declares $declared.');
  logInfo(
    floor == null
        ? 'No crate in the resolved graph declares a rust-version.'
        : 'The highest floor in the resolved graph is ${floor.version}, '
              'declared by ${floor.declaredBy}.',
  );

  final problems = <String>[];
  final writes = <String, String>{};

  if (target != declared) {
    problems.add('$_manifest declares $declared, below the graph\'s $target');
    writes[_manifest] = withRustVersion(
      file(_manifest).readAsStringSync(),
      target,
    );
  }

  final answersFile = file(_answers);
  if (answersFile.existsSync()) {
    final text = answersFile.readAsStringSync();
    final answer = rustVersionAnswerIn(text);
    if (answer == null) {
      logInfo('$_answers carries no rust_version answer.');
    } else if (answer == target) {
      logInfo('$_answers answers rust_version: $answer.');
    } else {
      problems.add('$_answers answers rust_version: $answer');
      writes[_answers] = withRustVersionAnswer(text, target);
    }
  }

  for (final doc in _docs) {
    final docFile = file(doc);
    if (!docFile.existsSync()) continue;
    final text = docFile.readAsStringSync();
    final advertised = advertisedRustVersionIn(text);
    if (advertised == null) {
      logInfo('$doc does not advertise a Rust version.');
    } else if (advertised == target) {
      logInfo('$doc advertises Rust $advertised+.');
    } else {
      problems.add('$doc advertises Rust $advertised+');
      writes[doc] = withAdvertisedRustVersion(text, target);
    }
  }

  if (ciOutput != null) {
    File(ciOutput).writeAsStringSync(
      'msrv_from=$declared\nmsrv_to=$target\nmsrv_moved=${target != declared}\n',
      mode: FileMode.append,
    );
  }

  if (problems.isEmpty) {
    logSuccess(
      'The minimum Rust version is $declared everywhere it is stated.',
    );
    exit(0);
  }
  for (final problem in problems) {
    logWarn(problem);
  }
  if (!update) {
    logError(
      'Not at $target everywhere. Run `make check-msrv ARGS="--update"`.',
    );
    exit(1);
  }
  writes.forEach((path, text) => file(path).writeAsStringSync(text));
  logSuccess('Raised to $target: ${writes.keys.join(', ')}.');
}

void _printUsage() {
  print('''
Check the minimum Rust version against what the dependency graph needs

Usage:
  fvm dart scripts/check_msrv.dart [options]

Options:
  --update            Raise rust/Cargo.toml, .copier-answers.yml and the
                      docs to the higher of the declared floor and the
                      highest rust-version a crate in the resolved graph
                      declares
  --ci-output <path>  Append msrv_from, msrv_to and msrv_moved to a file
  --help, -h          Show this help

It reads what crates declare. A crate that uses a feature newer than its own
floor is invisible to it: the CI MSRV check stays the oracle for that.
''');
}
