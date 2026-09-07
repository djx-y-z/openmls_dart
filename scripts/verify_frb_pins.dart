#!/usr/bin/env dart

/// Verify that every file recording the flutter_rust_bridge version agrees.
///
/// Usage:
///   fvm dart scripts/verify_frb_pins.dart
///
/// Exits 0 when they agree, 1 when they do not. Reads at most six files and
/// nothing else — no build, no network — so it is cheap enough to gate every
/// push.
///
/// See `scripts/src/frb_pins.dart` for why the agreement matters: the runtime
/// asserts the codegen version recorded in the committed bindings equals its
/// own, so a disagreement is not untidiness, it is a package that throws on
/// init in somebody else's app.
library;

import 'dart:io';

import 'src/common.dart';
import 'src/frb_pins.dart';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    print('Usage: fvm dart scripts/verify_frb_pins.dart');
    print('');
    print('Checks that pubspec.yaml, rust/Cargo.toml, the Makefile,');
    print('rust/fuzz/Cargo.toml, the committed FRB bindings and');
    print('.copier-answers.yml all name the same flutter_rust_bridge version,');
    print('and that the pubspec constraint is written as the publishable');
    print('single-version range.');
    return;
  }

  logStep('Checking flutter_rust_bridge version consistency...');

  final List<FrbPin> pins;
  try {
    pins = collectFrbPins();
  } on FrbPinFormatException catch (e) {
    logError(e.message);
    exit(1);
  }

  final report = frbPinReport(pins);
  if (report != null) {
    logError('flutter_rust_bridge versions disagree:');
    stderr.writeln(report);
    stderr.writeln('');
    stderr.writeln(
      'Move them together: set `frb_version` in .copier-answers.yml and the '
      '`=` pin in every cargo manifest that carries one, then '
      '`make setup-frb-codegen` and `make codegen` so the installed codegen '
      'and the committed bindings match the constraint.',
    );
    exit(1);
  }

  final version = pins.firstWhere((p) => p.version != null).version;
  // Absent sources report a sentence rather than a version, and a fixed column
  // is narrower than several of them; measure it instead of guessing.
  final found = pins.map((p) => p.version ?? p.detail).toList();
  final width = found.map((f) => f.length).reduce((a, b) => a > b ? a : b);
  for (var i = 0; i < pins.length; i++) {
    logInfo('${found[i].padRight(width)}  ${pins[i].source}');
  }
  logInfo('All flutter_rust_bridge pins agree on $version');
}
