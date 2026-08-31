// Checks that every place recording the flutter_rust_bridge version agrees.
//
// Five files hold the same version and nothing but agreement makes the package
// work: `frb_generated.dart` records the codegen version and the runtime
// asserts it equals its own with `==`, so a constraint admitting any other
// version throws at init — in a consumer's app, not here. That is the incident
// this exists to prevent. A caret in `pubspec.yaml` let a newer runtime into
// the published archive while the committed bindings still named the old one,
// and because `pubspec.lock` is not committed the break appeared only after
// publication, on machines nobody could see.
//
// Shaped like `verify-third-party-notices`: read what is committed, compare,
// report every disagreement at once. No build and no network — five file reads,
// so this can gate a pull request without costing a matrix leg.
//
// Everything that parses takes a string rather than a path, so the rules are
// testable without a fixture tree; only [collectFrbPins] touches the disk.
library;

import 'dart:io';

import 'common.dart';

/// One place the FRB version is recorded.
class FrbPin {
  const FrbPin({
    required this.source,
    required this.version,
    required this.detail,
  });

  /// Path relative to the package root, as a reader would open it.
  final String source;

  /// The version found, or null when the file exists but the pin is unreadable.
  final String? version;

  /// What was read, or why nothing was — quoted back in the failure.
  final String detail;

  /// Whether this source exists and has nothing to say. Absent bindings are the
  /// normal state of a project that has not run `make codegen` yet.
  bool get isAbsent => version == null && detail == _absent;

  static const _absent = 'not generated yet';
}

/// The one accepted `pubspec.yaml` form: a single version written as a range.
///
/// A bare `X.Y.Z` admits the same single version but makes the package
/// unpublishable — `dart pub publish` reports "should allow more than one
/// version" and exits 65 on any warning, which takes `make publish-dry-run`,
/// `make release` and publish.yml with it. A caret admits versions the runtime
/// assert rejects. So the form is checked, not only the number.
final _exactRange = RegExp(r'^>=(\d+\.\d+\.\d+)\s+<(\d+)\.(\d+)\.(\d+)$');

/// Strips a trailing `# comment` and any surrounding quotes from a scalar.
///
/// Both are things a person writes and neither changes the constraint, so
/// reading them as part of it turns a correctly-pinned file into a failure
/// that tells the reader to write what they already wrote.
String _scalar(String raw) {
  final hash = raw.indexOf('#');
  final withoutComment = hash == -1 ? raw : raw.substring(0, hash);
  return withoutComment.replaceAll('"', '').replaceAll("'", '').trim();
}

/// Reads the constraint from `pubspec.yaml`, requiring the exact-range form.
///
/// Returns the version, or throws [FrbPinFormatException] naming the form that
/// was written instead — the message is the whole point of failing here.
String frbVersionFromPubspec(String content) {
  final lines = RegExp(
    r'^\s*flutter_rust_bridge:\s*(.+?)\s*$',
    multiLine: true,
  ).allMatches(content).toList();
  if (lines.isEmpty) {
    throw FrbPinFormatException(
      'pubspec.yaml has no `flutter_rust_bridge:` dependency.',
    );
  }

  // More than one declaration is not a stricter version of one — it is a file
  // where the constraint this reads is not the constraint pub resolves. A
  // `dependency_overrides:` entry wins outright, and a second entry under
  // `dev_dependencies:` resolves alongside. Reading only the first would report
  // agreement about a version nothing uses.
  if (lines.length > 1) {
    final found = lines.map((m) => _scalar(m.group(1)!)).join(', ');
    throw FrbPinFormatException(
      'pubspec.yaml declares flutter_rust_bridge ${lines.length} times '
      '($found). Only one may exist: a `dependency_overrides` entry replaces '
      'the dependency outright and a second entry elsewhere resolves beside '
      'it, so the version this file appears to pin would not be the version '
      'pub installs.',
    );
  }

  final raw = _scalar(lines.single.group(1)!);
  final match = _exactRange.firstMatch(raw);
  if (match == null) {
    throw FrbPinFormatException(
      'pubspec.yaml pins flutter_rust_bridge as `$raw`, which is not the '
      'required form. Write the single version as a range, e.g. '
      '`">=2.12.0 <2.12.1"`: a caret admits versions the runtime assert in '
      '`frb_generated.dart` rejects at init, and a bare `2.12.0` makes the '
      'package unpublishable (pub warns "should allow more than one version" '
      'and `dart pub publish` exits 65 on any warning). Only `X.Y.Z` versions '
      'are supported — a pre-release has no well-defined next patch.',
    );
  }

  final lower = match.group(1)!;
  final parts = lower.split('.').map(int.parse).toList();
  final upper = [
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
  ];
  final expected = [parts[0], parts[1], parts[2] + 1];
  if (!_sameTriple(upper, expected)) {
    throw FrbPinFormatException(
      'pubspec.yaml pins flutter_rust_bridge as `$raw`, whose upper bound is '
      'not the next patch of its lower bound. `>=$lower '
      '<${expected.join('.')}` admits exactly $lower; the range as written '
      'admits more, and every extra version fails the runtime assert.',
    );
  }
  return lower;
}

bool _sameTriple(List<int> a, List<int> b) =>
    a[0] == b[0] && a[1] == b[1] && a[2] == b[2];

/// Reads the `=` pin from `rust/Cargo.toml`, in either the string or the
/// table form cargo accepts.
///
/// Every occurrence is read, not the first: the rendered manifest already
/// carries a `[target.'cfg(target_arch = "wasm32")'.dependencies]` section, so
/// a second pin there is an ordinary thing to write and would otherwise be
/// invisible.
String? frbVersionFromCargoToml(String content) {
  final matches = RegExp(
    r'^\s*flutter_rust_bridge\s*=\s*'
    r'(?:"=([^"]+)"|\{[^}]*?version\s*=\s*"=([^"]+)")',
    multiLine: true,
  ).allMatches(content).map((m) => m.group(1) ?? m.group(2)!).toSet();
  if (matches.isEmpty) return null;
  if (matches.length > 1) {
    throw FrbPinFormatException(
      'rust/Cargo.toml pins flutter_rust_bridge to more than one version '
      '(${matches.join(', ')}). Cargo resolves one of them per target, so the '
      'bindings can only match one.',
    );
  }
  return matches.single;
}

/// Reads `FRB_CODEGEN_VERSION` from the Makefile — the version of the binary
/// `make setup-frb-codegen` installs, and so the one that writes the bindings.
///
/// The **last** assignment is the one make uses: a later `=` overrides an
/// earlier `?=`, so reading the first would report the version the file opens
/// with rather than the one that installs the generator.
String? frbVersionFromMakefile(String content) {
  final matches = RegExp(
    r'^FRB_CODEGEN_VERSION\s*\??=\s*(\S+)',
    multiLine: true,
  ).allMatches(content).toList();
  return matches.isEmpty ? null : _scalar(matches.last.group(1)!);
}

/// Reads the version the committed bindings record, which the runtime compares
/// against its own with `==`.
String? frbVersionFromGeneratedBindings(String content) =>
    RegExp(r"codegenVersion\s*=>\s*'([^']+)'").firstMatch(content)?.group(1);

/// Reads `frb_version` from `.copier-answers.yml`, caret and quotes and all.
///
/// This is the answer every other file is rendered from, so a project whose
/// answer has drifted will re-acquire the drift on its next template update —
/// which is why it is checked here rather than treated as documentation.
String? frbVersionFromCopierAnswers(String content) {
  final match = RegExp(
    r'^frb_version:\s*(.+?)\s*$',
    multiLine: true,
  ).firstMatch(content);
  if (match == null) return null;
  final value = _scalar(match.group(1)!);
  return value.startsWith('^') ? value.substring(1).trim() : value;
}

/// Thrown when a pin exists but is written in a form that cannot be accepted.
class FrbPinFormatException implements Exception {
  FrbPinFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads every recorded FRB version from [packageDir].
List<FrbPin> collectFrbPins({Directory? packageDir}) {
  final dir = packageDir ?? getPackageDir();

  FrbPin read(
    String path,
    String what,
    String? Function(String content) parse, {
    bool optional = false,
  }) {
    final file = File('${dir.path}/$path');
    if (!file.existsSync()) {
      return FrbPin(
        source: path,
        version: null,
        detail: optional ? FrbPin._absent : 'file not found',
      );
    }
    final version = parse(file.readAsStringSync());
    return FrbPin(
      source: path,
      version: version,
      detail: version ?? 'no $what found in the file',
    );
  }

  return [
    read('pubspec.yaml', 'constraint', frbVersionFromPubspec),
    read(
      'rust/Cargo.toml',
      '`flutter_rust_bridge = "=X.Y.Z"`',
      frbVersionFromCargoToml,
    ),
    read('Makefile', 'FRB_CODEGEN_VERSION', frbVersionFromMakefile),
    // Optional: a project generated but not yet built has no bindings, and
    // failing there would make the gate impossible to satisfy on a first run.
    read(
      'lib/src/rust/frb_generated.dart',
      'codegenVersion',
      frbVersionFromGeneratedBindings,
      optional: true,
    ),
    read('.copier-answers.yml', 'frb_version', frbVersionFromCopierAnswers),
  ];
}

/// Describes what disagrees, or null when everything that has a version agrees.
///
/// Every disagreement is reported together rather than at the first one: these
/// move as a set, and a reader fixing them one run at a time learns the set
/// only by rediscovering it.
String? frbPinReport(List<FrbPin> pins) {
  final problems = <String>[];

  for (final pin in pins.where((p) => p.version == null && !p.isAbsent)) {
    problems.add('  ${pin.source}: ${pin.detail}');
  }

  final known = pins.where((p) => p.version != null).toList();
  final versions = known.map((p) => p.version!).toSet();
  if (versions.length > 1) {
    problems.add(
      '  the version differs between files (${versions.join(' vs ')}):',
    );
    for (final pin in known) {
      problems.add('    ${pin.version!.padRight(10)} ${pin.source}');
    }
  }

  if (problems.isEmpty) return null;
  return problems.join('\n');
}
