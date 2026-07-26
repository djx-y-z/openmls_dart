import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/third_party_notices.dart';

CrateNotice _crate(
  String name,
  String version, {
  String? spdx,
  Map<String, String> texts = const {},
  String? repository,
  List<String> authors = const [],
}) => CrateNotice(
  name: name,
  version: version,
  spdx: spdx,
  licenceTexts: texts,
  repository: repository,
  authors: authors,
);

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
          'somecrate v0.8.1 (https://github.com/acme/somecrate?tag=v0.8.1)';
      expect(parseCargoTree(stdout), {'somecrate@0.8.1'});
    });

    test('handles build metadata in the version', () {
      expect(parseCargoTree('openssl-src v300.5.5+3.5.5'), {
        'openssl-src@300.5.5+3.5.5',
      });
    });

    test('ignores blank and malformed lines', () {
      expect(parseCargoTree('\n   \nnot-a-crate-line\n'), isEmpty);
    });
  });

  group('collectLinkedCrates', () {
    test('refuses to produce an empty inventory', () {
      expect(
        () => collectLinkedCrates(manifestPath: 'rust/Cargo.toml', targets: []),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('No release targets configured'),
          ),
        ),
      );
    });
  });

  group('readLicenceTexts', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('notices_scan'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Directory dir(String path) =>
        Directory('${tmp.path}/$path')..createSync(recursive: true);
    void write(String path, String content) =>
        File('${tmp.path}/$path').writeAsStringSync(content);

    test('finds a licence beside vendored code and keys it by path', () {
      dir('crate/sqlcipher');
      write('crate/LICENSE', 'binding licence');
      write('crate/sqlcipher/LICENSE', 'vendored licence');

      expect(readLicenceTexts(Directory('${tmp.path}/crate')), {
        'LICENSE': 'binding licence',
        'sqlcipher/LICENSE': 'vendored licence',
      });
    });

    test('stops descending past the depth limit', () {
      dir('crate/a/b/c/d');
      write('crate/a/b/c/LICENSE', 'reachable');
      write('crate/a/b/c/d/LICENSE', 'too deep');

      expect(readLicenceTexts(Directory('${tmp.path}/crate')), {
        'a/b/c/LICENSE': 'reachable',
      });
    });

    test('walks up to the repository root for a git dependency', () {
      dir('checkout/member');
      write('checkout/LICENSE', 'workspace licence');

      expect(
        readLicenceTexts(
          Directory('${tmp.path}/checkout/member'),
          gitSourced: true,
        ),
        {'../LICENSE': 'workspace licence'},
      );
    });

    test('never walks up for a registry crate', () {
      dir('registry/crate');
      write('registry/LICENSE', 'some other crate licence');

      expect(
        readLicenceTexts(Directory('${tmp.path}/registry/crate')),
        isEmpty,
      );
    });

    test('prefers the crate own licence over walking up', () {
      dir('checkout/member');
      write('checkout/LICENSE', 'workspace licence');
      write('checkout/member/LICENSE', 'member licence');

      expect(
        readLicenceTexts(
          Directory('${tmp.path}/checkout/member'),
          gitSourced: true,
        ),
        {'LICENSE': 'member licence'},
      );
    });

    test('skips a file it cannot decode', () {
      dir('crate');
      File('${tmp.path}/crate/LICENSE').writeAsBytesSync([0xff, 0xfe, 0x41]);
      write('crate/LICENSE-MIT', 'readable');

      expect(readLicenceTexts(Directory('${tmp.path}/crate')), {
        'LICENSE-MIT': 'readable',
      });
    });
  });

  group('parseSpdxIds', () {
    test('splits OR expressions', () {
      expect(parseSpdxIds('MIT OR Apache-2.0'), ['MIT', 'Apache-2.0']);
    });

    test('splits the legacy slash spelling', () {
      expect(parseSpdxIds('MIT/Apache-2.0'), ['MIT', 'Apache-2.0']);
    });

    test('drops operators and parentheses', () {
      expect(parseSpdxIds('(MIT AND BSD-3-Clause) OR MPL-2.0'), [
        'MIT',
        'BSD-3-Clause',
        'MPL-2.0',
      ]);
    });
  });

  group('isOwnLicenceKey', () {
    test('accepts a crate-root and a repository-root licence', () {
      expect(isOwnLicenceKey('LICENSE'), isTrue);
      expect(isOwnLicenceKey('../LICENSE'), isTrue);
    });

    test('rejects a licence belonging to vendored code', () {
      expect(isOwnLicenceKey('sqlcipher/LICENSE'), isFalse);
    });
  });

  group('suppliedLicenceFor', () {
    test('supplies the invariant text of a licence that has one', () {
      final licence = suppliedLicenceFor(_crate('c', '1.0.0', spdx: 'MPL-2.0'));
      expect(licence!.spdx, 'MPL-2.0');
      expect(licence.reconstructed, isFalse);
      expect(licence.text, contains('Mozilla Public License Version 2.0'));
    });

    test('prefers an invariant licence over reconstructing MIT', () {
      final licence = suppliedLicenceFor(
        _crate('c', '1.0.0', spdx: 'MIT OR Apache-2.0', authors: ['A']),
      );
      expect(licence!.spdx, 'Apache-2.0');
      expect(licence.reconstructed, isFalse);
    });

    test('reconstructs MIT from the authors metadata', () {
      final licence = suppliedLicenceFor(
        _crate('c', '1.0.0', spdx: 'MIT', authors: ['Ada <ada@example.com>']),
      );
      expect(licence!.reconstructed, isTrue);
      expect(licence.text, contains('Copyright (c) Ada <ada@example.com>'));
      expect(licence.text, contains('Permission is hereby granted'));
    });

    test('says so when MIT attribution cannot be recovered', () {
      final licence = suppliedLicenceFor(
        _crate('c', '1.0.0', spdx: 'MIT', repository: 'https://example.com/c'),
      );
      expect(licence!.text, contains('not stated in the crate manifest'));
      expect(licence.text, contains('https://example.com/c'));
    });

    test('declines an expression carrying a licence exception', () {
      expect(
        suppliedLicenceFor(
          _crate('c', '1.0.0', spdx: 'Apache-2.0 WITH LLVM-exception'),
        ),
        isNull,
      );
    });

    test('declines a licence whose text embeds a copyright line', () {
      expect(
        suppliedLicenceFor(_crate('c', '1.0.0', spdx: 'BSD-3-Clause')),
        isNull,
      );
      expect(suppliedLicenceFor(_crate('c', '1.0.0')), isNull);
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
      expect(output, isNot(contains('CANONICAL LICENCE TEXTS')));
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

    test('supplies a canonical text for a crate that ships none', () {
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {
          'bare@1.0.0': _crate(
            'bare',
            '1.0.0',
            spdx: 'Apache-2.0',
            repository: 'https://example.com/bare',
          ),
        },
      );
      expect(output, contains('Canonical licence texts supplied: 1'));
      expect(
        output,
        contains(
          'ships no licence file of its own; canonical Apache-2.0 text '
          '[C1]',
        ),
      );
      expect(output, contains('Source:  https://example.com/bare'));
      expect(output, contains('[C1] supplied for 1 crate(s) — Apache-2.0'));
      expect(output, contains('TERMS AND CONDITIONS FOR USE'));
    });

    test('flags a reconstructed attribution in the pool header', () {
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {
          'bare@1.0.0': _crate('bare', '1.0.0', spdx: 'MIT', authors: ['Ada']),
        },
      );
      expect(
        output,
        contains(
          '[C1] supplied for 1 crate(s) — MIT, copyright line composed '
          'from crate metadata',
        ),
      );
    });

    test('supplies a text when the only licence shipped is vendored', () {
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {
          'v@1.0.0': _crate(
            'v',
            '1.0.0',
            spdx: 'Apache-2.0',
            texts: {'vendor/LICENSE': 'licence of the vendored code'},
          ),
        },
      );
      expect(output, contains('vendor/LICENSE [T1]'));
      expect(output, contains('canonical Apache-2.0 text [C1]'));
    });

    test('records a crate whose licence cannot be supplied at all', () {
      final output = renderNotices(
        packageName: 'openmls',
        crateName: 'openmls_frb',
        notices: {'bare@1.0.0': _crate('bare', '1.0.0', spdx: 'ISC')},
      );
      expect(output, contains('ships no licence file'));
      expect(output, contains('cannot be recovered'));
      expect(output, contains('Canonical licence texts supplied: 0'));
      expect(output, isNot(contains('CANONICAL LICENCE TEXTS')));
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
