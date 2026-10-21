import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../scripts/src/upstream_source.dart';

// Every source is tested here from fixtures, whichever one this project was
// generated with — the template compiles all of them into every project so
// that every project's `make test` keeps all of them working. Only the last
// test reads this project's own files.

/// A git source with a prefix other than `v`, the case a hardcoded `v?` breaks.
const _git = GitTagSource(
  repo: 'owner/upstream',
  crates: ['upstream-core', 'upstream-protocol'],
  tagPrefix: 'upstream-v',
);

/// A registry source whose crates are versioned independently.
const _registry = CratesIoSource(
  repo: 'owner/upstream',
  crates: ['upstream-core', 'upstream-protocol', 'upstream-traits'],
);

const _api = 'https://crates.io/api/v1/crates';

/// A full commit id, as `.cargo_vcs_info.json` records it.
const _sha = '0123456789abcdef0123456789abcdef01234567';

/// An [UpstreamHttp] that answers from a table and records what was asked.
class _FakeHttp implements UpstreamHttp {
  _FakeHttp({this.json = const {}, this.bytes = const {}});

  /// Response bodies by URL: a string as it is, anything else JSON-encoded.
  final Map<String, Object> json;

  /// Raw responses by URL.
  final Map<String, Uint8List> bytes;

  /// Every URL requested, in order.
  final requested = <String>[];

  @override
  Future<String> getJson(Uri url) async {
    requested.add('$url');
    final body = json['$url'];
    if (body == null) throw StateError('unexpected GET $url');
    return body is String ? body : jsonEncode(body);
  }

  @override
  Future<Uint8List> getBytes(Uri url) async {
    requested.add('$url');
    final body = bytes['$url'];
    if (body == null) throw StateError('unexpected GET $url');
    return body;
  }
}

/// A 512-byte tar header for [name], [size] bytes of [type] — only the fields
/// the reader looks at; it checks no checksum.
Uint8List _header(
  String name,
  int size, {
  int type = 0x30,
  String prefix = '',
  String magic = 'ustar\x00',
}) {
  final header = Uint8List(512);
  void put(int at, String text) =>
      header.setRange(at, at + text.length, latin1.encode(text));
  put(0, name);
  put(124, '${size.toRadixString(8).padLeft(11, '0')}\x00');
  header[156] = type;
  put(257, magic);
  put(345, prefix);
  return header;
}

/// A regular file entry: its header and its content.
(Uint8List, List<int>) _file(
  String name,
  String content, {
  String prefix = '',
  String magic = 'ustar\x00',
}) {
  final bytes = utf8.encode(content);
  return (_header(name, bytes.length, prefix: prefix, magic: magic), bytes);
}

/// A tar archive of [entries], each padded to whole blocks, closed by the two
/// zero blocks tar ends with.
Uint8List _tar(List<(Uint8List, List<int>)> entries) => Uint8List.fromList([
  for (final (header, data) in entries) ...[
    ...header,
    ...data,
    ...List.filled((512 - data.length % 512) % 512, 0),
  ],
  ...List.filled(1024, 0),
]);

/// A `.crate`: a gzipped tar of `<crate>-<version>/`, with [vcs] as its
/// `.cargo_vcs_info.json` when given.
Uint8List _crate(String crate, String version, {String? vcs}) =>
    Uint8List.fromList(
      gzip.encode(
        _tar([
          _file('$crate-$version/Cargo.toml', '[package]\nname = "$crate"\n'),
          if (vcs != null) _file('$crate-$version/.cargo_vcs_info.json', vcs),
        ]),
      ),
    );

/// The text of a `.cargo_vcs_info.json`.
String _vcs({String sha = _sha, bool dirty = false, String path = 'core'}) =>
    jsonEncode({
      'git': {'sha1': sha, if (dirty) 'dirty': true},
      'path_in_vcs': path,
    });

/// One package of a `cargo metadata` document.
Map<String, dynamic> _package(
  String name,
  String version,
  String? source,
  String manifest, {
  String? repository,
}) => {
  'name': name,
  'version': version,
  'source': source,
  'manifest_path': manifest,
  'repository': repository,
};

void main() {
  group('GitTagSource.validatePin', () {
    test('accepts the exact upstream tag form', () {
      for (final tag in [
        'upstream-v0.8.1',
        'upstream-v1.0.0',
        'upstream-v10.20.30',
        'upstream-v0.9.0-pre.1',
        'upstream-v1.0.0-rc-2',
      ]) {
        expect(_git.validatePin(tag, origin: 'test'), tag);
      }
    });

    test('rejects a bare version, and the default prefix', () {
      // `v` is the default prefix, so a tag in that shape is the likeliest
      // thing to reach a project that overrides it — from a copied command
      // line, or from a sibling repository.
      for (final tag in ['0.8.1', 'v0.8.1']) {
        expect(
          () => _git.validatePin(tag, origin: 'test'),
          throwsFormatException,
          reason: 'must reject: $tag',
        );
      }
    });

    test('rejects shell metacharacters and newline injection', () {
      for (final tag in [
        'upstream-v0.8.1; rm -rf /',
        r'upstream-v0.8.1$(whoami)',
        'upstream-v0.8.1`id`',
        'upstream-v0.8.1 --force',
        'upstream-v0.8.1\nmalicious',
        'upstream-v0.8.1\n',
      ]) {
        expect(
          () => _git.validatePin(tag, origin: 'test'),
          throwsFormatException,
          reason: 'must reject: $tag',
        );
      }
    });

    test('rejects path traversal and a prefix not at the start', () {
      for (final tag in [
        'upstream-v../../etc/passwd',
        'upstream-v0.8.1/../evil',
        'xupstream-v0.8.1',
      ]) {
        expect(
          () => _git.validatePin(tag, origin: 'test'),
          throwsFormatException,
          reason: 'must reject: $tag',
        );
      }
    });

    test('rejects non-canonical numeric segments', () {
      for (final tag in [
        'upstream-v0.08.1',
        'upstream-v0.8',
        'upstream-v0.8.1.2',
      ]) {
        expect(
          () => _git.validatePin(tag, origin: 'test'),
          throwsFormatException,
          reason: 'must reject: $tag',
        );
      }
    });

    test('names the rejected origin in the message', () {
      // The call sites (API response, --version argument, recorded pin) fail
      // for different reasons; the message has to say which one to look at.
      expect(
        () => _git.validatePin('nope', origin: '--version argument'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--version argument'),
          ),
        ),
      );
    });
  });

  group('GitTagSource.pinFrom', () {
    const realPin =
        'upstream-core = { git = "https://example.invalid/upstream", '
        'tag = "upstream-v1.2.3" }';

    test('reads the tag from an ordinary pin', () {
      expect(_git.pinFrom(realPin), 'upstream-v1.2.3');
    });

    test('reads the pin, not a commented-out one above it', () {
      // What an upgrade leaves behind when the old line is kept for reference.
      expect(
        _git.pinFrom(
          '# upstream-core = { git = "...", tag = "upstream-v1.0.0" }\n'
          '$realPin',
        ),
        'upstream-v1.2.3',
      );
    });

    test('a comment naming a newer tag cannot report us as up to date', () {
      // The dangerous direction: read this and the update check reports the
      // dependency as current, so an upstream release never lands.
      expect(
        _git.pinFrom(
          '   # upstream-core = { git = "...", tag = "upstream-v9.9.9" }\n'
          '$realPin',
        ),
        'upstream-v1.2.3',
      );
    });

    test('a tag on a following line is not the pin', () {
      // TOML forbids a newline inside an inline table, so a `tag` below the
      // dependency belongs to something else and must not be read as its own.
      expect(
        () => _git.pinFrom(
          'upstream-core = { git = "https://example.invalid" }\n'
          'tag = "upstream-v0.1.0"\n',
        ),
        throwsFormatException,
      );
    });

    test('a missing pin is an error that says what was expected', () {
      expect(
        () => _git.pinFrom('[dependencies]\nrand = "0.8"\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(
              'upstream-core = { git = "...", tag = "upstream-vX.Y.Z" }',
            ),
          ),
        ),
      );
    });

    test('a recorded tag of the wrong shape is refused, not used', () {
      expect(
        () => _git.pinFrom(
          'upstream-core = { git = "https://example.invalid", tag = "v1.2.3" }',
        ),
        throwsFormatException,
      );
    });

    test('reads back what declarationOf writes', () {
      final pin = _git.pinOf('1.2.3');
      expect(pin, 'upstream-v1.2.3');
      expect(_git.pinFrom(_git.declarationOf(pin)), pin);
    });
  });

  group('GitTagSource.semverOf', () {
    test('strips the configured prefix', () {
      expect(_git.semverOf('upstream-v1.2.3'), '1.2.3');
    });

    test('falls back to a bare v, and otherwise leaves the pin alone', () {
      expect(_git.semverOf('v1.2.3'), '1.2.3');
      expect(_git.semverOf('1.2.3'), '1.2.3');
    });
  });

  group('GitTagSource.rewriteCargoToml', () {
    const before =
        '[dependencies]\n'
        'rand = "0.8"\n'
        'upstream-core = { git = "https://example.invalid", tag = "upstream-v1.0.0" }\n'
        'upstream-protocol = { git = "https://example.invalid", tag = "upstream-v1.0.0", features = ["x"] }\n'
        '# upstream-core = { git = "https://example.invalid", tag = "upstream-v0.1.0" }\n'
        '\n'
        "[target.'cfg(target_arch = \"wasm32\")'.dependencies]\n"
        'upstream-core = { git = "https://example.invalid", tag = "upstream-v1.0.0", features = ["js"] }\n';

    test('moves every upstream crate, in every table, to the tag', () {
      final after = _git.rewriteCargoToml(before, (
        pin: 'upstream-v2.0.0',
        companions: const {},
      ));
      expect('upstream-v2.0.0'.allMatches(after), hasLength(3));
      expect(after, contains('features = ["x"]'));
      expect(after, contains('features = ["js"]'));
    });

    test('leaves comments and other dependencies alone', () {
      final after = _git.rewriteCargoToml(before, (
        pin: 'upstream-v2.0.0',
        companions: const {},
      ));
      expect(after, contains('rand = "0.8"'));
      expect(after, contains('# upstream-core = {'));
      expect(after, contains('tag = "upstream-v0.1.0"'));
    });
  });

  group('GitTagSource and the network', () {
    final latest = Uri.parse(
      'https://api.github.com/repos/owner/upstream/releases/latest',
    );

    test(
      'fetchLatest validates the tag and reports what GitHub says',
      () async {
        final http = _FakeHttp(
          json: {
            '$latest': {
              'tag_name': 'upstream-v1.3.0',
              'prerelease': false,
              'html_url': 'https://example.invalid/release',
            },
          },
        );
        final release = await _git.fetchLatest(http);
        expect(release.pin, 'upstream-v1.3.0');
        expect(release.isPrerelease, isFalse);
        expect(release.page, 'https://example.invalid/release');
      },
    );

    test('fetchLatest refuses a tag of another shape', () async {
      final http = _FakeHttp(
        json: {
          '$latest': {'tag_name': 'v1.3.0'},
        },
      );
      await expectLater(_git.fetchLatest(http), throwsFormatException);
    });

    test('fetchLatest refuses a payload with no tag at all', () async {
      final http = _FakeHttp(
        json: {
          '$latest': {'message': 'API rate limit exceeded'},
        },
      );
      await expectLater(_git.fetchLatest(http), throwsFormatException);
    });

    test('a bump is the tag alone, and the tag is its own revision', () async {
      final http = _FakeHttp();
      final bump = await _git.planBump('upstream-v1.3.0', http);
      expect(bump.pin, 'upstream-v1.3.0');
      expect(bump.companions, isEmpty);
      final revision = await _git.revisionOf('upstream-v1.3.0', http);
      expect(revision, (ref: 'upstream-v1.3.0', dirty: false));
      expect(http.requested, isEmpty);
    });

    test('pageFor names the GitHub release', () {
      expect(
        _git.pageFor('upstream-v1.3.0').url,
        'https://github.com/owner/upstream/releases/tag/upstream-v1.3.0',
      );
    });
  });

  group('GitTagSource.cratesIn', () {
    const checkout = '/home/runner/.cargo/git/checkouts';
    const upstream = GitTagSource(
      repo: 'owner/upstream',
      crates: ['upstream-protocol'],
      tagPrefix: 'v',
    );
    VcsInfo? none(String dir) => null;

    // The shape `cargo metadata` gives for a package's own graph: the bound
    // crates, one more pulled in from the same repository, a git dependency
    // from another repository, a registry crate and the workspace's own crate.
    test('takes the upstream repository crates, with their directories', () {
      final crates = upstream.cratesIn({
        'packages': [
          _package(
            'upstream-protocol',
            '0.1.0',
            'git+https://github.com/owner/upstream?tag=v0.105.1#1738ead8',
            '$checkout/upstream-2a19/1738ead/rust/protocol/Cargo.toml',
          ),
          _package(
            'upstream-debug',
            '0.105.1',
            'git+https://github.com/owner/upstream?tag=v0.105.1#1738ead8',
            '$checkout/upstream-2a19/1738ead/rust/debug/Cargo.toml',
          ),
          _package(
            'ratchet',
            '1.6.0',
            'git+https://github.com/owner/ratchet.git?tag=v1.6.0#06959b47',
            '$checkout/ratchet-b58d/06959b4/Cargo.toml',
          ),
          _package(
            'libc',
            '0.2.191',
            'registry+https://github.com/rust-lang/crates.io-index',
            '/home/runner/.cargo/registry/src/index/libc-0.2.191/Cargo.toml',
          ),
          _package(
            'wrapper_frb',
            '7.0.0',
            null,
            '/work/wrapper/rust/Cargo.toml',
          ),
        ],
      }, vcsInfo: none);
      expect(crates, [
        (name: 'upstream-debug', version: '0.105.1', dir: 'rust/debug/'),
        (name: 'upstream-protocol', version: '0.1.0', dir: 'rust/protocol/'),
      ]);
    });

    // A repository whose crate sits at its root owns every path in it, which
    // the empty directory says.
    test('a crate at the repository root gets the empty directory', () {
      const ratchet = GitTagSource(
        repo: 'owner/ratchet',
        crates: ['ratchet'],
        tagPrefix: 'v',
      );
      final crates = ratchet.cratesIn({
        'packages': [
          _package(
            'ratchet',
            '1.6.0',
            'git+https://github.com/Owner/Ratchet.git#06959b47',
            '$checkout/ratchet-b58d/06959b4/Cargo.toml',
          ),
        ],
      }, vcsInfo: none);
      expect(crates.single.dir, isEmpty);
    });

    test('a crate whose checkout path cannot be read is left out', () {
      final crates = upstream.cratesIn({
        'packages': [
          _package(
            'upstream-core',
            '0.1.0',
            'git+https://github.com/owner/upstream#1738ead8',
            '/somewhere/else/core/Cargo.toml',
          ),
        ],
      }, vcsInfo: none);
      expect(crates, isEmpty);
      expect(upstream.cratesIn({}, vcsInfo: none), isEmpty);
    });
  });

  group('CratesIoSource.validatePin', () {
    test('accepts an exact crates.io version', () {
      for (final version in ['1.2.3', '0.9.0-rc.1', '10.20.30']) {
        expect(_registry.validatePin(version, origin: 'test'), version);
      }
    });

    test('rejects a tag, a range, and what a shell would read', () {
      for (final version in [
        'v1.2.3',
        'upstream-v1.2.3',
        '1.2',
        '01.2.3',
        '1.2.3+build',
        '=1.2.3',
        '1.2.3; rm -rf /',
        '1.2.3\n',
      ]) {
        expect(
          () => _registry.validatePin(version, origin: 'test'),
          throwsFormatException,
          reason: 'must reject: $version',
        );
      }
    });
  });

  group('CratesIoSource.pinFrom', () {
    test('reads an exact version, bare or in a table', () {
      expect(_registry.pinFrom('upstream-core = "=1.2.3"\n'), '1.2.3');
      expect(
        _registry.pinFrom(
          'upstream-core = { version = "=1.2.3", features = ["x"] }\n',
        ),
        '1.2.3',
      );
    });

    test('every declaration counts, and they must agree', () {
      const twice =
          '[dependencies]\n'
          'upstream-core = { version = "=1.2.3", features = ["x"] }\n'
          "[target.'cfg(target_arch = \"wasm32\")'.dependencies]\n"
          'upstream-core = { version = "=1.2.3", features = ["js"] }\n';
      expect(_registry.pinFrom(twice), '1.2.3');
      expect(
        () => _registry.pinFrom(twice.replaceFirst('=1.2.3', '=1.2.2')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('=1.2.2'), contains('=1.2.3')),
          ),
        ),
      );
    });

    test('a range is refused: it is Cargo.lock that would decide', () {
      expect(
        () => _registry.pinFrom('upstream-core = "1.2.3"\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('pinned exactly'),
          ),
        ),
      );
    });

    test('a git declaration is not a registry pin', () {
      expect(
        () => _registry.pinFrom(
          'upstream-core = { git = "https://example.invalid", tag = "v1.2.3" }',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('still declared from git or a path'),
          ),
        ),
      );
    });

    // What a project looks like halfway through a change of source: the
    // registry in the main table, git still in a target table. Every
    // declaration that reads as a pin agrees, so only refusing the stray one
    // keeps the check from comparing against a version nothing builds.
    test('a change of source left half done is refused', () {
      for (final stray in [
        'upstream-core = { git = "https://example.invalid", tag = "v1.2.3" }',
        'upstream-traits = { path = "../traits" }',
      ]) {
        expect(
          () => _registry.pinFrom(
            '[dependencies]\n'
            'upstream-core = { version = "=1.2.3", features = ["x"] }\n'
            "[target.'cfg(target_arch = \"wasm32\")'.dependencies]\n"
            '$stray\n',
          ),
          throwsFormatException,
          reason: 'must refuse: $stray',
        );
      }
    });

    test('a declaration with no version at all says so', () {
      expect(
        () => _registry.pinFrom('upstream-core = { features = ["x"] }\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not declared with a version'),
          ),
        ),
      );
    });

    test(
      'a comment, or a crate whose name only starts the same, is not it',
      () {
        expect(
          _registry.pinFrom(
            '# upstream-core = "=9.9.9"\n'
            'upstream-core-macros = "=8.8.8"\n'
            'upstream-core = "=1.2.3"\n',
          ),
          '1.2.3',
        );
      },
    );

    test('reads back what declarationOf writes', () {
      final pin = _registry.pinOf('1.2.3');
      expect(pin, '1.2.3');
      expect(_registry.pinFrom(_registry.declarationOf(pin)), pin);
    });
  });

  group('CratesIoSource.rewriteCargoToml', () {
    const before =
        '[dependencies]\n'
        'rand = "0.8"\n'
        'upstream-core = { version = "=1.0.0", features = ["x"] }\n'
        'upstream-protocol = "0.5.0"\n'
        'upstream-traits = { version = "0.5.0", features = ["y"] }\n'
        '# upstream-core = "=0.1.0"\n'
        '\n'
        "[target.'cfg(target_arch = \"wasm32\")'.dependencies]\n"
        'upstream-core = { version = "=1.0.0", features = ["js"] }\n';

    test('pins the primary crate everywhere, keeping each table', () {
      final after = _registry.rewriteCargoToml(before, (
        pin: '2.0.0',
        companions: const {},
      ));
      expect(
        after,
        contains('upstream-core = { version = "=2.0.0", features = ["x"] }'),
      );
      expect(
        after,
        contains('upstream-core = { version = "=2.0.0", features = ["js"] }'),
      );
      expect(after, contains('# upstream-core = "=0.1.0"'));
      expect(after, contains('rand = "0.8"'));
    });

    test('moves exactly the companions the bump names', () {
      final after = _registry.rewriteCargoToml(before, (
        pin: '2.0.0',
        companions: const {'upstream-traits': '0.6.0'},
      ));
      expect(
        after,
        contains('upstream-traits = { version = "0.6.0", features = ["y"] }'),
      );
      expect(after, contains('upstream-protocol = "0.5.0"'));
    });
  });

  group('CratesIoSource.rewriteAnswers', () {
    const answers =
        'native_repo: owner/upstream\n'
        "upstream_crate_versions: 'upstream-protocol=0.5.0,upstream-traits=0.5.0'\n"
        'upstream_crates: upstream-core,upstream-protocol,upstream-traits\n'
        'upstream_source: crates_io\n'
        'upstream_version: 1.0.0\n';

    test('moves the pin and every crate the bump names, keeping the rest', () {
      final after = _registry.rewriteAnswers(answers, (
        pin: '2.0.0',
        companions: const {'upstream-traits': '0.6.0'},
      ));
      expect(after, contains('upstream_version: 2.0.0\n'));
      expect(
        after,
        contains(
          "upstream_crate_versions: 'upstream-protocol=0.5.0,upstream-traits=0.6.0'\n",
        ),
      );
    });

    test('with no upstream_crate_versions to move, moves the pin alone', () {
      final after = _registry.rewriteAnswers('upstream_version: "1.0.0"\n', (
        pin: '2.0.0',
        companions: const {'upstream-traits': '0.6.0'},
      ));
      expect(after, 'upstream_version: "2.0.0"\n');
    });
  });

  group('CratesIoSource and the network', () {
    Map<String, Object> published(String version, {bool yanked = false}) => {
      '$_api/upstream-core/$version': {
        'version': {'num': version, 'yanked': yanked},
      },
    };

    test('fetchLatest takes the highest stable version', () async {
      final http = _FakeHttp(
        json: {
          '$_api/upstream-core': {
            'crate': {
              'max_stable_version': '1.3.0',
              'max_version': '2.0.0-rc.1',
            },
          },
          ...published('1.3.0'),
        },
      );
      final release = await _registry.fetchLatest(http);
      expect(release.pin, '1.3.0');
      expect(release.isPrerelease, isFalse);
      expect(release.page, 'https://crates.io/crates/upstream-core/1.3.0');
    });

    test('fetchLatest falls back to a pre-release, and says so', () async {
      final http = _FakeHttp(
        json: {
          '$_api/upstream-core': {
            'crate': {'max_stable_version': null, 'max_version': '2.0.0-rc.1'},
          },
          ...published('2.0.0-rc.1'),
        },
      );
      final release = await _registry.fetchLatest(http);
      expect(release.isPrerelease, isTrue);
    });

    test('fetchLatest refuses a malformed or a yanked version', () async {
      final malformed = _FakeHttp(
        json: {
          '$_api/upstream-core': {
            'crate': {'max_stable_version': '1.3.0; rm -rf /'},
          },
        },
      );
      await expectLater(
        _registry.fetchLatest(malformed),
        throwsFormatException,
      );
      final yanked = _FakeHttp(
        json: {
          '$_api/upstream-core': {
            'crate': {'max_stable_version': '1.3.0'},
          },
          ...published('1.3.0', yanked: true),
        },
      );
      await expectLater(_registry.fetchLatest(yanked), throwsFormatException);
    });

    test('fetchLatest reports an error payload as one', () async {
      final http = _FakeHttp(
        json: {
          '$_api/upstream-core': {
            'errors': [
              {'detail': 'Not Found'},
            ],
          },
        },
      );
      await expectLater(
        _registry.fetchLatest(http),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Not Found'),
          ),
        ),
      );
    });

    test('planBump takes each companion from the release itself', () async {
      final http = _FakeHttp(
        json: {
          ...published('1.3.0'),
          '$_api/upstream-core/1.3.0/dependencies': {
            'dependencies': [
              {
                'crate_id': 'upstream-protocol',
                'kind': 'normal',
                'req': '=0.4.0',
              },
              {
                'crate_id': 'upstream-traits',
                'kind': 'normal',
                'req': '^0.6.0',
              },
              {'crate_id': 'upstream-traits', 'kind': 'dev', 'req': '^0.1.0'},
              {'crate_id': 'rand', 'kind': 'normal', 'req': '^0.8'},
            ],
          },
        },
      );
      final bump = await _registry.planBump('1.3.0', http);
      expect(bump.pin, '1.3.0');
      expect(bump.companions, {
        'upstream-protocol': '=0.4.0',
        'upstream-traits': '0.6.0',
      });
    });

    test('planBump leaves a crate the release does not depend on', () async {
      final http = _FakeHttp(
        json: {
          ...published('1.3.0'),
          '$_api/upstream-core/1.3.0/dependencies': {
            'dependencies': [
              {
                'crate_id': 'upstream-traits',
                'kind': 'normal',
                'req': '^0.6.0',
              },
            ],
          },
        },
      );
      final bump = await _registry.planBump('1.3.0', http);
      expect(bump.companions.keys, ['upstream-traits']);
    });

    test('planBump refuses a yanked release', () async {
      final http = _FakeHttp(json: published('1.3.0', yanked: true));
      await expectLater(
        _registry.planBump('1.3.0', http),
        throwsFormatException,
      );
    });

    test('a single-crate source asks for no dependency list', () async {
      const single = CratesIoSource(
        repo: 'owner/upstream',
        crates: ['upstream-core'],
      );
      final http = _FakeHttp(json: published('1.3.0'));
      final bump = await single.planBump('1.3.0', http);
      expect(bump.companions, isEmpty);
      expect(http.requested, ['$_api/upstream-core/1.3.0']);
    });

    test('revisionOf reads the commit the published crate records', () async {
      final http = _FakeHttp(
        bytes: {
          'https://static.crates.io/crates/upstream-core/upstream-core-1.3.0.crate':
              _crate('upstream-core', '1.3.0', vcs: _vcs(dirty: true)),
        },
      );
      expect(await _registry.revisionOf('1.3.0', http), (
        ref: _sha,
        dirty: true,
      ));
    });

    test('revisionOf says so when the crate records no commit', () async {
      final http = _FakeHttp(
        bytes: {
          'https://static.crates.io/crates/upstream-core/upstream-core-1.3.0.crate':
              _crate('upstream-core', '1.3.0'),
        },
      );
      await expectLater(
        _registry.revisionOf('1.3.0', http),
        throwsFormatException,
      );
    });
  });

  group('CratesIoSource.cratesIn', () {
    const registry = 'registry+https://github.com/rust-lang/crates.io-index';
    const cache = '/home/runner/.cargo/registry/src/index.crates.io-1949';
    final vcs = <String, VcsInfo>{
      '$cache/upstream-core-1.3.0/': vcsInfoFrom(_vcs()),
      '$cache/upstream-traits-0.6.0/': vcsInfoFrom(_vcs(path: '')),
      '$cache/upstream-protocol-0.4.0/': vcsInfoFrom(_vcs(path: 'proto/')),
    };

    test('takes the registry crates published from the repository', () {
      final crates = _registry.cratesIn({
        'packages': [
          _package(
            'upstream-core',
            '1.3.0',
            registry,
            '$cache/upstream-core-1.3.0/Cargo.toml',
            repository: 'https://github.com/owner/upstream/',
          ),
          _package(
            'upstream-traits',
            '0.6.0',
            registry,
            '$cache/upstream-traits-0.6.0/Cargo.toml',
            repository: 'https://github.com/Owner/Upstream.git',
          ),
          _package(
            'upstream-protocol',
            '0.4.0',
            registry,
            '$cache/upstream-protocol-0.4.0/Cargo.toml',
            repository: 'http://github.com/owner/upstream',
          ),
          _package(
            'libc',
            '0.2.191',
            registry,
            '$cache/libc-0.2.191/Cargo.toml',
            repository: 'https://github.com/rust-lang/libc',
          ),
        ],
      }, vcsInfo: (dir) => vcs[dir]);
      expect(crates, [
        (name: 'upstream-core', version: '1.3.0', dir: 'core/'),
        (name: 'upstream-protocol', version: '0.4.0', dir: 'proto/'),
        (name: 'upstream-traits', version: '0.6.0', dir: ''),
      ]);
    });

    // A workspace's member crates often name their own directory as their
    // repository — the shape every crate but the primary had in the project
    // this was measured in. Only the primary would otherwise be upstream.
    test('a repository given as a directory in it is still the repository', () {
      final crates = _registry.cratesIn({
        'packages': [
          _package(
            'upstream-traits',
            '0.6.0',
            registry,
            '$cache/upstream-traits-0.6.0/Cargo.toml',
            repository: 'https://github.com/owner/upstream/tree/main/traits',
          ),
          _package(
            'upstream-protocol',
            '0.4.0',
            registry,
            '$cache/upstream-protocol-0.4.0/Cargo.toml',
            repository: 'https://github.com/owner/upstream-extra',
          ),
        ],
      }, vcsInfo: (dir) => vcs[dir]);
      expect(crates, [(name: 'upstream-traits', version: '0.6.0', dir: '')]);
    });

    test('a git package, or one with no recorded path, is left out', () {
      final crates = _registry.cratesIn({
        'packages': [
          _package(
            'upstream-core',
            '1.3.0',
            'git+https://github.com/owner/upstream#1738ead8',
            '/home/runner/.cargo/git/checkouts/up-2a19/1738ead/core/Cargo.toml',
            repository: 'https://github.com/owner/upstream',
          ),
          _package(
            'upstream-extra',
            '0.1.0',
            registry,
            '$cache/upstream-extra-0.1.0/Cargo.toml',
            repository: 'https://github.com/owner/upstream',
          ),
        ],
      }, vcsInfo: (dir) => vcs[dir]);
      expect(crates, isEmpty);
    });
  });

  group('companion requirements', () {
    test('a caret requirement is written as Cargo writes its default', () {
      expect(requirementFrom('^0.6.0'), '0.6.0');
      expect(requirementFrom('^0.6'), '0.6');
      expect(requirementFrom('=0.4.0'), '=0.4.0');
      expect(requirementFrom('0.6.0'), '0.6.0');
    });

    test('anything but a single version is refused, not approximated', () {
      for (final req in ['>=0.6, <0.8', '~0.6', '*', '^0.6.0; rm -rf /']) {
        expect(
          () => requirementFrom(req),
          throwsFormatException,
          reason: 'must reject: $req',
        );
      }
    });

    test('a crate declared twice must be declared alike', () {
      expect(
        () => companionRequirements(
          [
            {'crate_id': 'upstream-traits', 'kind': 'normal', 'req': '^0.6.0'},
            {'crate_id': 'upstream-traits', 'kind': 'normal', 'req': '^0.7.0'},
          ],
          companions: ['upstream-traits'],
          release: 'upstream-core 1.3.0',
        ),
        throwsFormatException,
      );
    });

    test('upstream_crate_versions reads as a map', () {
      expect(parseCrateRequirements('a=0.6.0, b = =0.4.0,,c'), {
        'a': '0.6.0',
        'b': '=0.4.0',
      });
    });
  });

  group('answers file', () {
    test('a key is read and replaced with its quoting kept', () {
      for (final quote in ['', "'", '"']) {
        final answers = 'upstream_version: ${quote}1.0.0$quote\nother: x\n';
        expect(readAnswer(answers, 'upstream_version'), '1.0.0');
        expect(
          replaceAnswer(answers, 'upstream_version', '2.0.0'),
          'upstream_version: ${quote}2.0.0$quote\nother: x\n',
        );
      }
    });

    test('a key that only ends in the name is not the key', () {
      const answers = 'my_upstream_version: 9.9.9\n';
      expect(readAnswer(answers, 'upstream_version'), isNull);
      expect(replaceAnswer(answers, 'upstream_version', '2.0.0'), isNull);
    });
  });

  group('vcsInfoFrom', () {
    test('reads the commit, the dirty flag and the path', () {
      expect(vcsInfoFrom(_vcs()), (
        sha1: _sha,
        dirty: false,
        pathInVcs: 'core',
      ));
      expect(vcsInfoFrom(_vcs(dirty: true)).dirty, isTrue);
      expect(
        vcsInfoFrom(
          jsonEncode({
            'git': {'sha1': _sha},
          }),
        ).pathInVcs,
        isEmpty,
      );
    });

    test('refuses anything that is not a full commit id', () {
      for (final sha in ['0123abc', _sha.toUpperCase(), '$_sha/../x', '']) {
        expect(
          () => vcsInfoFrom(_vcs(sha: sha)),
          throwsFormatException,
          reason: 'must reject: $sha',
        );
      }
    });

    test('refuses a path that leaves the repository', () {
      for (final path in ['/etc', '../outside', 'a/../../b', 'a b', 'a?x']) {
        expect(
          () => vcsInfoFrom(_vcs(path: path)),
          throwsFormatException,
          reason: 'must reject: $path',
        );
      }
    });
  });

  group('tarEntry', () {
    test('finds a regular file by its path, and nothing else', () {
      final tar = _tar([
        _file('pkg-1.0.0/Cargo.toml', 'manifest'),
        _file('pkg-1.0.0/.cargo_vcs_info.json', 'info'),
      ]);
      expect(
        utf8.decode(tarEntry(tar, 'pkg-1.0.0/.cargo_vcs_info.json')!),
        'info',
      );
      expect(tarEntry(tar, 'pkg-1.0.0/missing'), isNull);
    });

    test('joins the POSIX prefix, and ignores it in a GNU header', () {
      final posix = _tar([_file('info.json', 'posix', prefix: 'pkg-1.0.0')]);
      expect(utf8.decode(tarEntry(posix, 'pkg-1.0.0/info.json')!), 'posix');
      final gnu = _tar([
        _file('info.json', 'gnu', prefix: 'pkg-1.0.0', magic: 'ustar  \x00'),
      ]);
      expect(tarEntry(gnu, 'pkg-1.0.0/info.json'), isNull);
      expect(utf8.decode(tarEntry(gnu, 'info.json')!), 'gnu');
    });

    test('a GNU long name or a pax path names the entry after it', () {
      final long = 'pkg-1.0.0/${'d' * 120}/info.json';
      final gnu = _tar([
        (
          _header('././@LongLink', long.length + 1, type: 0x4c),
          [...utf8.encode(long), 0],
        ),
        _file('truncated', 'gnu'),
      ]);
      expect(utf8.decode(tarEntry(gnu, long)!), 'gnu');

      final record = ' path=$long\n';
      final pax = '${record.length + 3}$record';
      final withPax = _tar([
        (_header('PaxHeader', pax.length, type: 0x78), utf8.encode(pax)),
        _file('truncated', 'pax'),
      ]);
      expect(utf8.decode(tarEntry(withPax, long)!), 'pax');
    });

    test('a truncated archive is an error, not a miss', () {
      final tar = _tar([_file('pkg-1.0.0/info.json', 'x' * 600)]);
      expect(
        () => tarEntry(Uint8List.sublistView(tar, 0, 700), 'none'),
        throwsFormatException,
      );
    });
  });

  group('vcsInfoFromCrate', () {
    test('reads the record out of a gzipped crate', () {
      expect(
        vcsInfoFromCrate(
          _crate('pkg', '1.0.0', vcs: _vcs()),
          crate: 'pkg',
          version: '1.0.0',
        ),
        (sha1: _sha, dirty: false, pathInVcs: 'core'),
      );
    });

    test('is null for a crate packaged without one', () {
      expect(
        vcsInfoFromCrate(
          _crate('pkg', '1.0.0'),
          crate: 'pkg',
          version: '1.0.0',
        ),
        isNull,
      );
    });
  });

  group('upstreamSourceFor', () {
    test('builds the source each answer names', () {
      final git = upstreamSourceFor(
        kind: 'git_tag',
        repo: 'owner/upstream',
        crates: ['upstream-core'],
        tagPrefix: 'upstream-v',
      );
      expect(git, isA<GitTagSource>());
      expect((git as GitTagSource).tagPrefix, 'upstream-v');
      expect(
        upstreamSourceFor(
          kind: 'crates_io',
          repo: 'owner/upstream',
          crates: ['upstream-core'],
          tagPrefix: 'v',
        ),
        isA<CratesIoSource>(),
      );
    });

    test('an answer this checkout does not know is refused', () {
      expect(
        () => upstreamSourceFor(
          kind: 'git_rev',
          repo: 'owner/upstream',
          crates: ['upstream-core'],
          tagPrefix: 'v',
        ),
        throwsArgumentError,
      );
    });
  });

  test('the active source is the one the answers name', () {
    expect(upstreamSource.kind, upstreamSourceKind);
  });

  // The one test that reads this project rather than a fixture: the pin its
  // own rust/Cargo.toml records must be one its own source can read, or the
  // scheduled update check fails on every run — behind a `|| true` in the
  // workflow, which is how a hardcoded `v?` once hid there.
  test('this project pins its upstream in the form its source reads', () {
    expect(getUpstreamVersion, returnsNormally);
  });
}
