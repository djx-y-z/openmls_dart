import 'package:test/test.dart';

import '../../scripts/src/feature_graph.dart';

/// Synthetic `cargo tree --format '{p}|{f}' --prefix none` lines.
///
/// Deliberately not this project's real graph: these cover the MECHANISM, and
/// a fixture built from the `forbidden_features` answer would only restate its
/// own input. The rules are passed explicitly for the same reason — the
/// rendered `defaultForbiddenFeatures` is this project's policy, not something
/// these tests should assert.
const _graph = [
  'crate_a v1.0.0 (https://example.invalid/repo?tag=v1#abc)|feat_keep,feat_other',
  'crate_b v2.3.4|feat_ban,feat_keep',
  'crate_c v0.1.0|',
];

const _rules = {
  'crate_a': {'feat_ban'},
};

void main() {
  group('parseCargoTreeLine', () {
    test('parses a git dependency with a source and features', () {
      final node = parseCargoTreeLine(_graph.first)!;
      expect(node.name, 'crate_a');
      expect(node.version, '1.0.0');
      expect(node.features, {'feat_keep', 'feat_other'});
    });

    test('parses a registry dependency with no source', () {
      final node = parseCargoTreeLine(_graph[1])!;
      expect(node.name, 'crate_b');
      expect(node.version, '2.3.4');
      expect(node.features, {'feat_ban', 'feat_keep'});
    });

    test('parses a crate with no features enabled', () {
      expect(parseCargoTreeLine(_graph[2])!.features, isEmpty);
    });

    test('parses the repeated-subtree marker cargo appends', () {
      // cargo prints `(*)` instead of re-expanding a subtree it already showed.
      final node = parseCargoTreeLine('crate_a v1.0.0 (*)|feat_ban')!;
      expect(node.name, 'crate_a');
      expect(node.features, {'feat_ban'});
    });

    test('returns null for a line that is not a crate node', () {
      expect(parseCargoTreeLine(''), isNull);
      expect(parseCargoTreeLine('   '), isNull);
      expect(parseCargoTreeLine('[build-dependencies]'), isNull);
    });
  });

  group('findForbiddenFeatures', () {
    test('a clean graph has no violations', () {
      expect(findForbiddenFeatures(_graph, forbidden: _rules), isEmpty);
    });

    test('catches a forbidden feature on the crate it is keyed to', () {
      final graph = ['crate_a v1.0.0|feat_ban,feat_keep', ..._graph.skip(1)];
      final found = findForbiddenFeatures(graph, forbidden: _rules);
      expect(found, hasLength(1));
      expect(found.single.crate.name, 'crate_a');
      expect(found.single.feature, 'feat_ban');
    });

    test('does NOT flag the same feature name on ANOTHER crate', () {
      // The reason the rules are keyed by crate. `crate_b` carries `feat_ban`
      // in every fixture above and is never a violation, because the rule
      // names `crate_a`. A flat list of feature names would fail here — on a
      // graph that is healthy.
      final offenders = findForbiddenFeatures(_graph, forbidden: _rules);
      expect(offenders, isEmpty);
      expect(parseCargoTreeLine(_graph[1])!.features, contains('feat_ban'));
    });

    test('FAILS when a crate named in the rules is absent from the graph', () {
      // A rule matching nothing reports the same "clean" as a rule matching
      // something clean, so a renamed or dropped dependency would silently
      // retire the check instead of breaking it.
      expect(
        () => findForbiddenFeatures(const [
          'crate_b v2.3.4|feat_keep',
        ], forbidden: _rules),
        throwsA(isA<FeatureGraphException>()),
      );
    });

    test('reports every violation, not only the first', () {
      final found = findForbiddenFeatures(
        const ['crate_a v1.0.0|feat_ban,feat_ban_two'],
        forbidden: const {
          'crate_a': {'feat_ban', 'feat_ban_two'},
        },
      );
      expect(found.map((v) => v.feature).toSet(), {'feat_ban', 'feat_ban_two'});
    });

    test("this project's own rules name at least one crate", () {
      // The rendered policy is not asserted here beyond this: an EMPTY rule
      // set would make every check above vacuous, and the template renders no
      // gate at all in that case — so if this file exists, the rules must not
      // be empty.
      expect(defaultForbiddenFeatures, isNotEmpty);
    });
  });
}
