/// Checking the RESOLVED cargo feature graph, rather than the text of a manifest.
///
/// `rust/Cargo.toml` says which features this crate asks for. It cannot say
/// which features a dependency ends up built with, because cargo UNIFIES
/// features across the graph: any dependency — including one added
/// transitively, by
/// somebody else, in a version bump nobody here reviewed — can turn a feature
/// on for a crate this manifest never mentions. A comment in the manifest is
/// therefore a statement of intent that nothing enforces.
///
/// What must not happen is named by the `forbidden_features` answer rather
/// than by this file. The case it was written for: a feature that pulls a
/// backtrace formatter into the wrapped library, so a symbolized Rust
/// backtrace — build-machine paths, symbol names, crate layout — reaches the
/// caller through the ORDINARY error channel, no panic required. Where one
/// such feature implies another, both are named: forbidding only the outer one
/// misses the shorter path to the same leak.
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
/// This is a failure and not a pass. A rule about a crate that matches
/// nothing is indistinguishable, in its output, from a rule about a crate
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
/// Rendered from the `forbidden_features` copier answer, so this is a literal
/// rather than a parser: a malformed answer fails when the template renders —
/// where the render gate can see it — instead of becoming a red CI run in a
/// generated project.
///
/// Keyed by crate, deliberately. A flat list of feature NAMES cannot express
/// this and is red on a healthy tree, because the same name is usually
/// legitimate on a neighbouring crate: one may carry `test-utils` because
/// something it exposes is reachable only with it, and a crate pulled in by
/// the FFI bridge may carry a `backtrace` feature of its own that forms no
/// path into the wrapped library's error channel.
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
