import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/third_party_notices.dart';

CrateNotice _crate(
  String name,
  String version, {
  String? spdx,
  Map<String, String> texts = const {},
}) =>
    CrateNotice(name: name, version: version, spdx: spdx, licenceTexts: texts);

void main() {
  group('parseCargoTree', () {
    test('extracts name@version and drops duplicate markers', () {
      const stdout = '''
addr2line v0.25.1
adler2 v2.0.1
aead v0.5.2
aead v0.5.2 (*)
''';
      expect(parseCargoTree(stdout), {
        'addr2line@0.25.1',
        'adler2@2.0.1',
        'aead@0.5.2',
      });
    });

    test('handles git dependencies with a trailing source', () {
      const stdout =
          'openmls v0.8.1 (https://github.com/openmls/openmls?tag=openmls-v0.8.1)';
      expect(parseCargoTree(stdout), {'openmls@0.8.1'});
    });

    test('ignores blank and malformed lines', () {
      expect(parseCargoTree('\n   \nnot-a-crate-line\n'), isEmpty);
    });
  });

  group('renderNotices', () {
    test('pools identical licence texts and references them by index', () {
      const shared = 'Apache License, Version 2.0 …';
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {
          'a@1.0.0': _crate(
            'a',
            '1.0.0',
            spdx: 'Apache-2.0',
            texts: {'LICENSE-APACHE': shared},
          ),
          'b@2.0.0': _crate(
            'b',
            '2.0.0',
            spdx: 'Apache-2.0',
            texts: {'LICENSE-APACHE': shared},
          ),
        },
      );

      // The shared text appears once in the pool, not once per crate.
      expect(shared.allMatches(output).length, 1);
      expect(output, contains('LICENSE-APACHE [T1]'));
      expect(output, contains('referenced by 2 crate(s)'));
      expect(output, contains('Distinct licence texts: 1'));
      expect(output, contains('Crates listed: 2'));
    });

    test('is deterministic regardless of input map order', () {
      final entries = [
        MapEntry(
          'zeta@1.0.0',
          _crate('zeta', '1.0.0', spdx: 'MIT', texts: {'LICENSE': 'Z text'}),
        ),
        MapEntry(
          'alpha@1.0.0',
          _crate('alpha', '1.0.0', spdx: 'MIT', texts: {'LICENSE': 'A text'}),
        ),
      ];

      final first = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: Map.fromEntries(entries),
      );
      final second = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: Map.fromEntries(entries.reversed),
      );
      expect(first, second);
      expect(
        first.indexOf('alpha 1.0.0'),
        lessThan(first.indexOf('zeta 1.0.0')),
      );
    });

    test('records crates that ship no licence file', () {
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {'bare@1.0.0': _crate('bare', '1.0.0', spdx: 'MIT')},
      );
      expect(output, contains('crate ships no licence file'));
      expect(output, contains('Distinct licence texts: 0'));
    });

    test('marks a crate with no declared SPDX expression', () {
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {'nospdx@1.0.0': _crate('nospdx', '1.0.0')},
      );
      expect(output, contains('(not declared in crate manifest)'));
    });
  });

  group('describeDrift', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('notices_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reports a missing file', () {
      final missing = File('${tmp.path}/absent.txt');
      expect(
        describeDrift(generated: 'anything', committed: missing),
        contains('Missing'),
      );
    });

    test('returns null when the committed file matches', () {
      final file = File('${tmp.path}/notices.txt')..writeAsStringSync('same');
      expect(describeDrift(generated: 'same', committed: file), isNull);
    });

    test('distinguishes a crate-count change from a content-only change', () {
      final file = File('${tmp.path}/notices.txt')
        ..writeAsStringSync('Crates listed: 5\nold');
      expect(
        describeDrift(generated: 'Crates listed: 7\nnew', committed: file),
        contains('lists 5 crates, dependency graph resolves to 7'),
      );
      expect(
        describeDrift(generated: 'Crates listed: 5\nnew', committed: file),
        contains('same crate count (5)'),
      );
    });
  });
}
