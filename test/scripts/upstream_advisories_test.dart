import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../scripts/src/upstream_advisories.dart';
import '../../scripts/src/upstream_source.dart';

/// An answer of `GET /repos/{owner}/{repo}/security-advisories?state=published`
/// in the shape GitHub returned it on 2026-10-21 — ranges written both as
/// `< X` and as a bare version, one advisory naming the same crate twice, one
/// per release line it was fixed on — with the names made neutral and the
/// fields this check does not read left out.
const publishedAdvisories = '''
[
  {
    "ghsa_id": "GHSA-gc79-23g3-8g52",
    "html_url": "https://github.com/example/upstream/security/advisories/GHSA-gc79-23g3-8g52",
    "summary": "Unbounded recursion while decoding nested input",
    "severity": "high",
    "state": "published",
    "withdrawn_at": null,
    "vulnerabilities": [
      {
        "package": {"ecosystem": "rust", "name": "upstream-core"},
        "vulnerable_version_range": "< 0.8.2",
        "patched_versions": "0.8.2",
        "vulnerable_functions": []
      },
      {
        "package": {"ecosystem": "rust", "name": "upstream-core"},
        "vulnerable_version_range": "0.9.0",
        "patched_versions": "0.9.1",
        "vulnerable_functions": []
      }
    ]
  },
  {
    "ghsa_id": "GHSA-w62v-gv48-63rh",
    "html_url": "https://github.com/example/upstream/security/advisories/GHSA-w62v-gv48-63rh",
    "summary": "A panic on malformed input",
    "severity": "medium",
    "state": "published",
    "withdrawn_at": null,
    "vulnerabilities": [
      {
        "package": {"ecosystem": "rust", "name": "upstream-core"},
        "vulnerable_version_range": "< 0.9.0",
        "patched_versions": "0.9.0",
        "vulnerable_functions": []
      }
    ]
  },
  {
    "ghsa_id": "GHSA-qr9h-x63w-vqfm",
    "html_url": "https://github.com/example/upstream/security/advisories/GHSA-qr9h-x63w-vqfm",
    "summary": "One release only",
    "severity": "medium",
    "state": "published",
    "withdrawn_at": null,
    "vulnerabilities": [
      {
        "package": {"ecosystem": "rust", "name": "upstream-core"},
        "vulnerable_version_range": "0.7.0",
        "patched_versions": "0.7.1",
        "vulnerable_functions": []
      }
    ]
  }
]''';

List<UpstreamAdvisory> parse(String json) => [
  for (final a in jsonDecode(json) as List<dynamic>)
    UpstreamAdvisory.fromJson(a as Map<String, dynamic>),
];

/// One advisory covering [range] of [package] in [ecosystem].
UpstreamAdvisory advisory({
  String id = 'GHSA-aaaa-bbbb-cccc',
  String ecosystem = 'rust',
  String package = 'upstream-core',
  required String range,
  bool withdrawn = false,
}) => UpstreamAdvisory(
  ghsaId: id,
  summary: 'summary',
  severity: 'high',
  url: 'https://github.com/example/upstream/security/advisories/$id',
  withdrawn: withdrawn,
  vulnerabilities: [
    AdvisoryVulnerability(
      ecosystem: ecosystem,
      package: package,
      range: range,
      patched: '9.9.9',
    ),
  ],
);

List<String> idsOf(List<AdvisoryHit> hits) => [
  for (final h in hits) '${h.advisory.ghsaId} ${h.version}',
];

/// Answers each request with the next of [responses]: a body, or an error to
/// throw. Records every URL asked for.
class FakeHttp implements UpstreamHttp {
  FakeHttp(this.responses);

  final List<Object> responses;
  final requested = <Uri>[];

  @override
  Future<String> getJson(Uri url) async {
    requested.add(url);
    final next = responses.removeAt(0);
    if (next is Exception) throw next;
    return next as String;
  }

  @override
  Future<Uint8List> getBytes(Uri url) => throw UnimplementedError();
}

void main() {
  group('versionInRange', () {
    test('reads the forms GitHub writes', () {
      expect(versionInRange('0.8.1', '< 0.8.2'), isTrue);
      expect(versionInRange('0.8.2', '< 0.8.2'), isFalse);
      expect(versionInRange('0.9.0', '0.9.0'), isTrue);
      expect(versionInRange('0.9.1', '0.9.0'), isFalse);
      expect(versionInRange('1.1.5', '>= 1.0.0, < 1.2.0'), isTrue);
      expect(versionInRange('1.2.0', '>= 1.0.0, < 1.2.0'), isFalse);
      expect(versionInRange('0.9.9', '>= 1.0.0, < 1.2.0'), isFalse);
      expect(versionInRange('2.0.0', '= 2.0.0'), isTrue);
      expect(versionInRange('2.0.0', '<= 2.0.0'), isTrue);
      expect(versionInRange('2.0.1', '> 2.0.0'), isTrue);
    });

    test('orders prereleases as SemVer does', () {
      expect(versionInRange('1.0.0-beta.2', '< 1.0.0-beta.10'), isTrue);
      expect(versionInRange('1.0.0-rc.1', '< 1.0.0'), isTrue);
    });

    // A range this cannot read is a reason to look, not to stay quiet — so
    // no constraint is applied before every one has been read.
    test(
      'cannot say for a range it cannot read, even one it could rule out',
      () {
        for (final range in ['', '~> 0.9', '0.9.0 || 1.0.0', '>= 1.0.0,']) {
          expect(versionInRange('0.9.0', range), isNull, reason: range);
        }
        expect(versionInRange('0.1.0', '>= 1.0.0, nonsense'), isNull);
      },
    );
  });

  group('lockedVersions', () {
    test('collects every version of each crate, keyed as Cargo compares', () {
      const lock = '''
# This file is automatically @generated by Cargo.
version = 4

[[package]]
name = "upstream-core"
version = "0.8.1"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "upstream_core"
version = "0.9.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "other"
version = "1.0.0"
''';
      expect(lockedVersions(lock), {
        'upstream_core': {'0.8.1', '0.9.0'},
        'other': {'1.0.0'},
      });
    });
  });

  group('advisoryHits', () {
    test('a lock on the affected release finds it, once', () {
      final hits = advisoryHits(
        advisories: parse(publishedAdvisories),
        locked: {
          'upstream_core': {'0.9.0'},
        },
      );
      expect(idsOf(hits), ['GHSA-gc79-23g3-8g52 0.9.0']);
      expect(hits.single.vulnerability.patched, '0.9.1');
      expect(hits.single.rangeUnparsed, isFalse);
    });

    test('a lock on the fixed release is clean', () {
      expect(
        advisoryHits(
          advisories: parse(publishedAdvisories),
          locked: {
            'upstream_core': {'0.9.1'},
          },
        ),
        isEmpty,
      );
    });

    test('an older lock finds every advisory that covers it', () {
      expect(
        idsOf(
          advisoryHits(
            advisories: parse(publishedAdvisories),
            locked: {
              'upstream_core': {'0.8.1'},
            },
          ),
        ),
        ['GHSA-gc79-23g3-8g52 0.8.1', 'GHSA-w62v-gv48-63rh 0.8.1'],
      );
    });

    test('reports each locked version of a crate', () {
      expect(
        idsOf(
          advisoryHits(
            advisories: [advisory(range: '< 1.0.0')],
            locked: {
              'upstream_core': {'0.9.0', '0.8.1'},
            },
          ),
        ),
        ['GHSA-aaaa-bbbb-cccc 0.8.1', 'GHSA-aaaa-bbbb-cccc 0.9.0'],
      );
    });

    test('compares names as Cargo does', () {
      expect(
        advisoryHits(
          advisories: [advisory(package: 'Upstream_Core', range: '0.9.0')],
          locked: lockedVersions(
            '[[package]]\nname = "upstream-core"\n'
            'version = "0.9.0"\n',
          ),
        ),
        hasLength(1),
      );
    });

    test('skips a withdrawn advisory and another ecosystem', () {
      expect(
        advisoryHits(
          advisories: [
            advisory(range: '0.9.0', withdrawn: true),
            advisory(ecosystem: 'npm', range: '0.9.0'),
          ],
          locked: {
            'upstream_core': {'0.9.0'},
          },
        ),
        isEmpty,
      );
    });

    test('counts a range it cannot read as covering the version', () {
      final hits = advisoryHits(
        advisories: [advisory(range: '~> 0.9')],
        locked: {
          'upstream_core': {'0.9.0'},
        },
      );
      expect(hits.single.rangeUnparsed, isTrue);
      expect(hits.single.describe(), contains('could not be read'));
    });
  });

  group('fetchUpstreamAdvisories', () {
    test('asks for published advisories only, a page at a time', () async {
      final full = jsonEncode([
        for (var i = 0; i < advisoriesPerPage; i++)
          {'ghsa_id': 'GHSA-$i', 'vulnerabilities': <Object>[]},
      ]);
      final http = FakeHttp([full, '[{"ghsa_id": "GHSA-last"}]']);
      final advisories = await fetchUpstreamAdvisories(
        repo: 'example/upstream',
        http: http,
      );
      expect(advisories, hasLength(advisoriesPerPage + 1));
      expect(advisories.last.ghsaId, 'GHSA-last');
      expect(
        [for (final u in http.requested) u.queryParameters['page']],
        ['1', '2'],
      );
      for (final url in http.requested) {
        expect(url.host, 'api.github.com');
        expect(url.path, '/repos/example/upstream/security-advisories');
        expect(url.queryParameters['state'], 'published');
      }
    });

    test('retries a failed page', () async {
      final http = FakeHttp([
        Exception('reset'),
        Exception('reset'),
        publishedAdvisories,
      ]);
      final advisories = await fetchUpstreamAdvisories(
        repo: 'example/upstream',
        http: http,
        retryDelay: Duration.zero,
      );
      expect(advisories, hasLength(3));
      expect(http.requested, hasLength(3));
    });

    test(
      'throws once every attempt has failed, rather than finding nothing',
      () async {
        final http = FakeHttp([
          Exception('rate limited'),
          Exception('rate limited'),
          Exception('rate limited'),
        ]);
        await expectLater(
          fetchUpstreamAdvisories(
            repo: 'example/upstream',
            http: http,
            retryDelay: Duration.zero,
          ),
          throwsA(isA<Exception>()),
        );
      },
    );
  });

  group('escapeWorkflowCommand', () {
    test('keeps advisory text from starting a workflow command of its own', () {
      expect(
        escapeWorkflowCommand('50% off\n::set-output name=x::y\r'),
        '50%25 off%0A::set-output name=x::y%0D',
      );
    });
  });
}
