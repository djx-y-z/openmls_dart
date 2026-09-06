import 'package:test/test.dart';

import '../../scripts/src/release.dart';

/// A CHANGELOG shaped like the real one: an `[Unreleased]` section with
/// in-progress content, two released sections, and compare links at the bottom.
const _changelog = '''
# Changelog

## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls v0.97.3** — internal/dependency update, no public-API impact

#### Changed

- Update openmls native library to v0.97.3

## [6.0.0] - 2026-07-14

### For Users

- Identity-trust enforcement

## [5.0.9] - 2026-06-01

- Older release

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v6.0.0...HEAD
[6.0.0]: https://github.com/djx-y-z/openmls_dart/compare/v5.0.9...v6.0.0
[5.0.9]: https://github.com/djx-y-z/openmls_dart/compare/v5.0.8...v5.0.9
''';

const _repoUrl = 'https://github.com/djx-y-z/openmls_dart';

/// Index of the line that starts with [prefix]; -1 if none.
int _lineStarting(String content, String prefix) =>
    content.split('\n').indexWhere((l) => l.startsWith(prefix));

void main() {
  group('finalizeChangelog', () {
    test('renames [Unreleased] to the dated version heading', () {
      final result = finalizeChangelog(
        _changelog,
        version: '6.1.0',
        date: '2026-07-16',
      );
      expect(result, contains('## [6.1.0] - 2026-07-16'));
    });

    test('leaves NO empty [Unreleased] heading; the version is topmost', () {
      final result = finalizeChangelog(
        _changelog,
        version: '6.1.0',
        date: '2026-07-16',
      );

      // The `## [Unreleased]` *heading* is gone (the next unreleased change
      // recreates it). Note: the footer `[Unreleased]:` compare link stays, so
      // match the heading form specifically, not a bare `[Unreleased]`.
      expect(
        '## [Unreleased]'.allMatches(result).length,
        equals(0),
        reason: 'no empty [Unreleased] section should remain after a release',
      );

      // The dated version heading is now the topmost `## [` section heading.
      final lines = result.split('\n');
      final firstSection = lines.firstWhere((l) => l.startsWith('## ['));
      expect(firstSection, equals('## [6.1.0] - 2026-07-16'));
    });

    test('moves in-progress content under the released heading', () {
      final result = finalizeChangelog(
        _changelog,
        version: '6.1.0',
        date: '2026-07-16',
      );
      final lines = result.split('\n');
      final versionIdx = lines.indexWhere((l) => l.startsWith('## [6.1.0]'));
      final prevIdx = lines.indexWhere((l) => l.startsWith('## [6.0.0]'));
      final highlightIdx = lines.indexWhere(
        (l) => l.contains('**openmls v0.97.3**'),
      );
      // The formerly-unreleased highlight now sits inside the [6.1.0] section.
      expect(highlightIdx, greaterThan(versionIdx));
      expect(highlightIdx, lessThan(prevIdx));
    });

    test('rewrites the [Unreleased] compare link to the new version', () {
      final result = finalizeChangelog(
        _changelog,
        version: '6.1.0',
        date: '2026-07-16',
      );
      expect(result, contains('[Unreleased]: $_repoUrl/compare/v6.1.0...HEAD'));
      expect(
        result,
        isNot(contains('/compare/v6.0.0...HEAD')),
        reason: 'the old Unreleased range must be replaced',
      );
    });

    test('inserts the new version compare link spanning previous...new', () {
      final result = finalizeChangelog(
        _changelog,
        version: '6.1.0',
        date: '2026-07-16',
      );
      expect(result, contains('[6.1.0]: $_repoUrl/compare/v6.0.0...v6.1.0'));
      // The new link sits directly under the Unreleased link.
      final unreleasedLinkIdx = _lineStarting(result, '[Unreleased]:');
      final newLinkIdx = _lineStarting(result, '[6.1.0]:');
      expect(newLinkIdx, equals(unreleasedLinkIdx + 1));
    });

    test('derives the base URL and previous version from the link, not a '
        'hardcoded slug', () {
      const forked = '''
## [Unreleased]

- pending

## [2.0.0] - 2026-01-01

- prior

[Unreleased]: https://example.com/acme/widget/compare/v2.0.0...HEAD
[2.0.0]: https://example.com/acme/widget/compare/v1.9.0...v2.0.0
''';
      final result = finalizeChangelog(
        forked,
        version: '2.1.0',
        date: '2026-02-02',
      );
      expect(
        result,
        contains(
          '[Unreleased]: https://example.com/acme/widget/compare/v2.1.0...HEAD',
        ),
      );
      expect(
        result,
        contains(
          '[2.1.0]: https://example.com/acme/widget/compare/v2.0.0...v2.1.0',
        ),
      );
    });

    test('keeps the version heading awk-extractable and the [Unreleased] '
        'heading skipped', () {
      // publish.yml extracts the release notes with an awk pattern that keys on
      // `^## \\[?[0-9]...`: the dated version heading must match, and no
      // `## [Unreleased]` heading must match (there no longer is one after a
      // release — this guards against a regression that reintroduces it).
      final result = finalizeChangelog(
        _changelog,
        version: '6.1.0',
        date: '2026-07-16',
      );
      final versionHeadings = result
          .split('\n')
          .where((l) => RegExp(r'^## \[?[0-9]+\.[0-9]+\.[0-9]+\]?').hasMatch(l))
          .toList();
      expect(versionHeadings, contains('## [6.1.0] - 2026-07-16'));
      expect(versionHeadings.any((l) => l.contains('Unreleased')), isFalse);
    });

    test('throws when there is no [Unreleased] heading', () {
      const noUnreleased = '''
## [6.0.0] - 2026-07-14

- something

[6.0.0]: https://github.com/djx-y-z/openmls_dart/compare/v5.0.9...v6.0.0
''';
      expect(
        () => finalizeChangelog(
          noUnreleased,
          version: '6.1.0',
          date: '2026-07-16',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when there is no [Unreleased] compare link', () {
      const noLink = '''
## [Unreleased]

- pending

## [6.0.0] - 2026-07-14

- something
''';
      expect(
        () => finalizeChangelog(noLink, version: '6.1.0', date: '2026-07-16'),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'throws when the version is already finalized (no double-finalize)',
      () {
        final once = finalizeChangelog(
          _changelog,
          version: '6.1.0',
          date: '2026-07-16',
        );
        expect(
          () => finalizeChangelog(once, version: '6.1.0', date: '2026-07-16'),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('throws on a non X.Y.Z version', () {
      expect(
        () =>
            finalizeChangelog(_changelog, version: 'v6.1', date: '2026-07-16'),
        throwsA(isA<Exception>()),
      );
    });

    test('throws on a malformed date (not YYYY-MM-DD)', () {
      // A typo or a flag accidentally consumed as the value must not be stamped
      // into the immutable released heading.
      for (final bad in ['19/07/2026', '--yes', '2026-7-1', 'today']) {
        expect(
          () => finalizeChangelog(_changelog, version: '6.1.0', date: bad),
          throwsA(isA<Exception>()),
          reason: 'date "$bad" should be rejected',
        );
      }
    });
  });

  group('describeFrbReleaseDrift', () {
    // Shaped like the real files, trimmed to the lines that decide whether the
    // published native binary matches the bindings shipped against it.
    String bindings(String codegen) =>
        "  @override\n  String get codegenVersion => '$codegen';\n"
        '  @override\n  int get rustContentHash => 450650216;\n';
    String cargo(String upstream) =>
        '[dependencies]\n'
        'openmls = { git = "https://example.invalid/upstream", '
        'tag = "$upstream" }\n';

    List<String> drift({
      required String ourCodegen,
      required String theirCodegen,
      String ourUpstream = 'v1.2.3',
      String theirUpstream = 'v1.2.3',
    }) => describeFrbReleaseDrift(
      tag: 'openmls_frb-1.0.0',
      ourBindings: bindings(ourCodegen),
      theirBindings: bindings(theirCodegen),
      ourCargo: cargo(ourUpstream),
      theirCargo: cargo(theirUpstream),
    );

    test('is silent when the tag was built from this tree', () {
      // The ordinary post-stage-1 state: stage 2 adds commits, but neither the
      // bindings nor the upstream pin move between the two stages.
      expect(drift(ourCodegen: '2.13.0', theirCodegen: '2.13.0'), isEmpty);
    });

    test('a moved codegen version alone is enough to refuse', () {
      // The hazard the existence check cannot see: a release carrying the right
      // version string, built by a different generator. `rustContentHash`
      // compares the FFI surface, which such a move need not touch, so nothing
      // else catches it.
      final reported = drift(ourCodegen: '2.13.0', theirCodegen: '2.12.0');
      expect(reported, hasLength(1));
      expect(
        reported.single,
        allOf(
          contains('flutter_rust_bridge codegen'),
          contains('2.13.0'),
          contains('2.12.0'),
        ),
      );
    });

    test('a moved upstream pin alone is enough to refuse', () {
      final reported = drift(
        ourCodegen: '2.13.0',
        theirCodegen: '2.13.0',
        theirUpstream: 'v1.0.0',
      );
      expect(reported, hasLength(1));
      expect(
        reported.single,
        allOf(contains('openmls:'), contains('v1.2.3'), contains('v1.0.0')),
      );
    });

    test('both moving is reported as both, not as one', () {
      expect(
        drift(
          ourCodegen: '2.13.0',
          theirCodegen: '2.12.0',
          theirUpstream: 'v1.0.0',
        ),
        hasLength(2),
      );
    });
  });
}
