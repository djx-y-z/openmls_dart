import 'package:test/test.dart';

import '../../scripts/src/feature_graph.dart';

/// Real `cargo tree --format '{p}|{f}' --prefix none` lines from this project,
/// trimmed to the crates that matter. The two clean-but-tempting ones are kept
/// deliberately: they are what a flat forbidden-feature list would trip over.
const _healthyGraph = [
  'openmls v0.9.0 (https://github.com/openmls/openmls?tag=openmls-v0.9.0#3a3e35de)|draft-ietf-mls-pq-ciphersuites,js',
  'openmls_basic_credential v0.6.0 (https://github.com/openmls/openmls?tag=openmls-v0.9.0#3a3e35de)|draft-ietf-mls-pq-ciphersuites,test-utils',
  'allo-isolate v0.1.27|anyhow,backtrace,default,zero-copy',
  'backtrace v0.3.76|default,std',
  'zeroize v1.8.2|alloc,default,derive,zeroize_derive',
];

void main() {
  group('parseCargoTreeLine', () {
    test('parses a git dependency with a source and features', () {
      final node = parseCargoTreeLine(_healthyGraph.first)!;
      expect(node.name, 'openmls');
      expect(node.version, '0.9.0');
      expect(node.features, {'draft-ietf-mls-pq-ciphersuites', 'js'});
    });

    test('parses a registry dependency with no source', () {
      final node = parseCargoTreeLine('backtrace v0.3.76|default,std')!;
      expect(node.name, 'backtrace');
      expect(node.features, {'default', 'std'});
    });

    test('parses a crate with no features enabled', () {
      final node = parseCargoTreeLine('futures v0.3.31|')!;
      expect(node.name, 'futures');
      expect(node.features, isEmpty);
    });

    test('parses the repeated-subtree marker cargo appends', () {
      // cargo prints `(*)` instead of re-expanding a subtree it already showed.
      final node = parseCargoTreeLine('openmls v0.9.0 (*)|test-utils')!;
      expect(node.name, 'openmls');
      expect(node.features, {'test-utils'});
    });

    test('returns null for a line that is not a crate node', () {
      expect(parseCargoTreeLine(''), isNull);
      expect(parseCargoTreeLine('   '), isNull);
      expect(parseCargoTreeLine('[build-dependencies]'), isNull);
    });
  });

  group('findForbiddenFeatures', () {
    test('a healthy graph has no violations', () {
      expect(findForbiddenFeatures(_healthyGraph), isEmpty);
    });

    test('catches test-utils on openmls', () {
      final graph = [
        'openmls v0.9.0 (https://x#y)|draft-ietf-mls-pq-ciphersuites,test-utils',
        ..._healthyGraph.skip(1),
      ];
      final found = findForbiddenFeatures(graph);
      expect(found, hasLength(1));
      expect(found.single.crate.name, 'openmls');
      expect(found.single.feature, 'test-utils');
    });

    test('catches backtrace on openmls WITHOUT test-utils', () {
      // `backtrace` is enableable on its own upstream, so forbidding
      // `test-utils` alone would miss the shorter path to the same leak.
      final graph = [
        'openmls v0.9.0 (https://x#y)|backtrace,draft-ietf-mls-pq-ciphersuites',
        ..._healthyGraph.skip(1),
      ];
      final found = findForbiddenFeatures(graph);
      expect(found.single.feature, 'backtrace');
    });

    test('does NOT flag test-utils on openmls_basic_credential', () {
      // It is enabled on purpose — it is what makes
      // `SignatureKeyPair::private()` reachable — and implies no backtrace.
      // A flat list of feature names would be red here on a healthy tree.
      expect(findForbiddenFeatures(_healthyGraph), isEmpty);
    });

    test('does NOT flag the backtrace feature of allo-isolate', () {
      // It arrives under flutter_rust_bridge and forms no path into openmls's
      // error channel. Present in the healthy fixture for exactly this reason.
      final names = _healthyGraph
          .map(parseCargoTreeLine)
          .whereType<CrateFeatures>()
          .where((c) => c.features.contains('backtrace'))
          .map((c) => c.name);
      expect(names, contains('allo-isolate'));
      expect(findForbiddenFeatures(_healthyGraph), isEmpty);
    });

    test('FAILS when a crate named in the rules is absent from the graph', () {
      // A rule matching nothing reports the same "clean" as a rule matching
      // something clean, so a renamed or dropped dependency would silently
      // retire the check instead of breaking it.
      expect(
        () => findForbiddenFeatures(const ['zeroize v1.8.2|alloc,default']),
        throwsA(isA<FeatureGraphException>()),
      );
    });

    test('reports every violation, not only the first', () {
      final found = findForbiddenFeatures(const [
        'openmls v0.9.0 (https://x#y)|backtrace,test-utils',
      ]);
      expect(found.map((v) => v.feature).toSet(), {'backtrace', 'test-utils'});
    });

    test('honours a caller-supplied rule set', () {
      final found = findForbiddenFeatures(
        _healthyGraph,
        forbidden: const {
          'zeroize': {'derive'},
        },
      );
      expect(found.single.crate.name, 'zeroize');
    });
  });
}
