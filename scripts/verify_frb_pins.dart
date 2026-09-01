#!/usr/bin/env dart

/// Verify that every file recording the flutter_rust_bridge version agrees.
///
/// Usage:
///   fvm dart scripts/verify_frb_pins.dart
///
/// Exits 0 when they agree, 1 when they do not. Reads five files and nothing
/// else — no build, no network — so it is cheap enough to gate every push.
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
    print('Checks that pubspec.yaml, rust/Cargo.toml, the Makefile, the');
    print('committed FRB bindings and .copier-answers.yml all name the same');
    print('flutter_rust_bridge version, and that the pubspec constraint is');
    print('written as the publishable single-version range.');
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
      'Move them together: set `frb_version` in .copier-answers.yml, then '
      '`make setup-frb-codegen` and `make codegen` so the installed codegen '
      'and the committed bindings match the constraint.',
    );
    exit(1);
  }

  final version = pins.firstWhere((p) => p.version != null).version;
  for (final pin in pins) {
    logInfo('${(pin.version ?? pin.detail).padRight(18)} ${pin.source}');
  }
  logInfo('All flutter_rust_bridge pins agree on $version');
}
