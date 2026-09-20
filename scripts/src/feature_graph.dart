/// Checking the RESOLVED cargo feature graph, rather than the text of a manifest.
///
/// `rust/Cargo.toml` says which features this crate asks for. It cannot say
/// which features `openmls` ends up built with, because cargo UNIFIES features
/// across the graph: any dependency — including one added transitively, by
/// somebody else, in a version bump nobody here reviewed — can turn a feature
/// on for a crate this manifest never mentions. A comment in the manifest is
/// therefore a statement of intent that nothing enforces.
///
/// What must not happen is specific. `openmls/test-utils` implies
/// `openmls/backtrace` (upstream's own `[features]` table lists `"backtrace"`
/// inside `test-utils`), and with it `LibraryError::custom()` formats a
/// symbolized Rust backtrace — build-machine paths, symbol names, crate layout
/// — into an error that travels the ORDINARY error channel out to the Dart
/// caller. No panic required. `backtrace` is also enableable on its own, so
/// forbidding `test-utils` alone would miss the shorter path to the same leak.
library;

/// One node of `cargo tree --format '{p}|{f}'` output.
class CrateFeatures {
  const CrateFeatures({
    required this.name,
    required this.version,
    required this.features,
  });

  final String name;
  final String version;
  final Set<String> features;

  @override
  String toString() => '$name v$version (${features.join(', ')})';
}

/// A forbidden feature found enabled on a crate that ships.
class FeatureViolation {
  const FeatureViolation({required this.crate, required this.feature});

  final CrateFeatures crate;
  final String feature;
}

/// Raised when the graph does not contain a crate the rules name.
///
/// This is a failure and not a pass. A rule about `openmls` that matches
/// nothing is indistinguishable, in its output, from a rule about `openmls`
/// that matches something clean — so a renamed or dropped dependency would
/// silently retire the check instead of breaking it.
class FeatureGraphException implements Exception {
  const FeatureGraphException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Features that must never be enabled on a crate in the shipped graph.
///
/// Keyed by crate, deliberately. A flat list of feature NAMES cannot express
/// this and would be red on a healthy tree: `openmls_basic_credential` carries
/// `test-utils` on purpose — that is what makes `SignatureKeyPair::private()`
/// reachable, and that crate's `test-utils` implies no backtrace — while
/// `allo-isolate`, which arrives under `flutter_rust_bridge`, carries a
/// `backtrace` feature of its own that has nothing to do with openmls's error
/// channel.
const Map<String, Set<String>> defaultForbiddenFeatures = {
  'openmls': {'test-utils', 'backtrace'},
};

/// Parses one `cargo tree --format '{p}|{f}' --prefix none` line.
///
/// `{p}` renders as `name version` plus, for a git or path dependency, a
/// parenthesised source. Returns null for a line that is not a crate node,
/// which includes the blank lines and the `[build-dependencies]` style headers
/// cargo emits between sections.
CrateFeatures? parseCargoTreeLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;

  final bar = trimmed.indexOf('|');
  if (bar < 0) return null;

  final left = trimmed.substring(0, bar).trim();
  final right = trimmed.substring(bar + 1).trim();

  // `name vX.Y.Z` optionally followed by ` (source)`, and cargo marks a
  // repeated subtree with a trailing `(*)`.
  final match = RegExp(r'^(\S+)\s+v(\S+)').firstMatch(left);
  if (match == null) return null;

  return CrateFeatures(
    name: match.group(1)!,
    version: match.group(2)!,
    features: right.isEmpty
        ? <String>{}
        : right
              .split(',')
              .map((f) => f.trim())
              .where((f) => f.isNotEmpty)
              .toSet(),
  );
}

/// Every forbidden feature enabled anywhere in [lines].
///
/// Throws [FeatureGraphException] when a crate named in [forbidden] is absent
/// from the graph entirely — see that class for why absence is not a pass.
List<FeatureViolation> findForbiddenFeatures(
  Iterable<String> lines, {
  Map<String, Set<String>> forbidden = defaultForbiddenFeatures,
}) {
  final nodes = lines
      .map(parseCargoTreeLine)
      .whereType<CrateFeatures>()
      .toList(growable: false);

  final seen = nodes.map((n) => n.name).toSet();
  final missing = forbidden.keys.where((c) => !seen.contains(c)).toList()
    ..sort();
  if (missing.isNotEmpty) {
    throw FeatureGraphException(
      'These crates are named in the feature rules but are absent from the '
      'dependency graph: ${missing.join(', ')}.\n'
      'A rule that matches nothing reports the same "clean" as a rule that '
      'matches something clean, so this fails rather than passing. Either the '
      'dependency was renamed or dropped — update the rules — or the graph was '
      'read wrongly.',
    );
  }

  final violations = <FeatureViolation>[];
  for (final node in nodes) {
    final banned = forbidden[node.name];
    if (banned == null) continue;
    for (final feature in node.features) {
      if (banned.contains(feature)) {
        violations.add(FeatureViolation(crate: node, feature: feature));
      }
    }
  }
  return violations;
}
