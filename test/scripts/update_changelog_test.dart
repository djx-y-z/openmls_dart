import 'package:test/test.dart';

import '../../scripts/src/update_changelog.dart';

/// A released CHANGELOG with NO `## [Unreleased]` section — the normal state
/// right after `make release` finalized the previous version (it no longer
/// leaves an empty `## [Unreleased]` behind). The next native-update PR lands on
/// top of this shape, so `insertChangelogEntry` must create the section.
const _noUnreleased = '''
# Changelog

## [1.4.2] - 2026-07-20

### For Users

- Prior release

## [1.4.1] - 2026-07-14

- Older release

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.1...v1.4.2
''';

/// The same CHANGELOG but with an in-progress `## [Unreleased]` section already
/// open (a second native update within the same release cycle).
const _withUnreleased = '''
# Changelog

## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls_frb v1.5.2** — Rust FFI bindings

#### Changed

- Update openmls native library to v0.8.1

## [1.4.2] - 2026-07-20

- Prior release

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.1...v1.4.2
''';

void main() {
  group('insertChangelogEntry', () {
    test('creates the [Unreleased] section when none exists', () {
      final result = insertChangelogEntry(
        currentChangelog: _noUnreleased,
        nativeHighlight: '**openmls v0.8.2** — protocol update',
        changed: '- Update openmls native library to v0.8.2',
      );

      final lines = result.split('\n');

      // Exactly one [Unreleased] heading is created (no duplication).
      expect(
        lines.where((l) => l.startsWith('## [Unreleased]')).length,
        equals(1),
      );

      // It sits above the topmost released version.
      final unreleasedIdx = lines.indexWhere(
        (l) => l.startsWith('## [Unreleased]'),
      );
      final firstVersionIdx = lines.indexWhere(
        (l) => l.startsWith('## [1.4.2]'),
      );
      expect(unreleasedIdx, greaterThanOrEqualTo(0));
      expect(unreleasedIdx, lessThan(firstVersionIdx));

      // The new entry landed inside the created section.
      expect(result, contains('**openmls v0.8.2** — protocol update'));
      expect(result, contains('- Update openmls native library to v0.8.2'));

      // The released sections and the footer link are preserved.
      expect(result, contains('## [1.4.2] - 2026-07-20'));
      expect(
        result,
        contains(
          '[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare',
        ),
      );
    });

    test('inserts into the existing [Unreleased] without duplicating it', () {
      final result = insertChangelogEntry(
        currentChangelog: _withUnreleased,
        nativeHighlight: '**openmls v0.8.2** — protocol update',
        changed: '- Update openmls native library to v0.8.2',
      );

      // Still exactly one [Unreleased] heading — it was reused, not recreated.
      expect(
        result.split('\n').where((l) => l.startsWith('## [Unreleased]')).length,
        equals(1),
      );

      // The new entry is present alongside the pre-existing one.
      expect(result, contains('**openmls v0.8.2** — protocol update'));
      expect(result, contains('**openmls_frb v1.5.2**'));
    });

    test('creates For Users at the top of an [Unreleased] that only has For '
        'Contributors', () {
      // The shape [Unreleased] has whenever the accumulated changes are CI or
      // tooling only. Appending at the end of the section would file the
      // user-facing entry below For Contributors, which no released section does.
      const contributorsOnly = '''
# Changelog

## [Unreleased]

### For Contributors

#### Fixed

- Something in CI

## [1.4.2] - 2026-07-20

- Prior release

[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/djx-y-z/openmls_dart/compare/v1.4.1...v1.4.2
''';
      final result = insertChangelogEntry(
        currentChangelog: contributorsOnly,
        nativeHighlight: '**openmls v0.8.2** — protocol update',
        changed: '- Update openmls native library to v0.8.2',
      );

      final lines = result.split('\n');
      final unreleasedIdx = lines.indexWhere(
        (l) => l.startsWith('## [Unreleased]'),
      );
      final forUsersIdx = lines.indexWhere(
        (l) => l.startsWith('### For Users'),
      );
      final contributorsIdx = lines.indexWhere(
        (l) => l.startsWith('### For Contributors'),
      );
      final highlightIdx = lines.indexWhere(
        (l) => l.contains('openmls v0.8.2'),
      );

      expect(
        lines.where((l) => l.startsWith('### For Users')).length,
        equals(1),
        reason: 'no duplicate For Users heading',
      );
      expect(forUsersIdx, greaterThan(unreleasedIdx));
      expect(forUsersIdx, lessThan(contributorsIdx));
      expect(highlightIdx, lessThan(contributorsIdx));
      // The pre-existing subsection survives intact.
      expect(result, contains('- Something in CI'));
    });

    test('files the bump under #### Changed, never under the breaking one', () {
      // `#### Changed (Breaking)` starts with `#### Changed`, so a prefix match
      // files a routine native-library bump as a breaking change — and, because
      // the branch fires per heading, files it a second time under the real
      // `#### Changed` as well.
      const withBreaking = '''
# Changelog

## [Unreleased]

### For Users

#### Changed (Breaking)

- Something breaking

#### Changed

- Existing change

#### Fixed

- Bug fix

## [1.4.2] - 2026-07-20

- Prior release
''';
      final result = insertChangelogEntry(
        currentChangelog: withBreaking,
        nativeHighlight: '**openmls v0.8.2** — protocol update',
        changed: '- Update openmls native library to v0.8.2',
      );

      final lines = result.split('\n');
      const bump = '- Update openmls native library to v0.8.2';
      final bumpIdx = lines.indexOf(bump);
      final breakingIdx = lines.indexOf('#### Changed (Breaking)');
      final changedIdx = lines.indexOf('#### Changed');
      final highlightsIdx = lines.indexWhere(
        (l) => l.startsWith('#### ✨ Highlights'),
      );

      // Exactly once, and under the plain `#### Changed`.
      expect(lines.where((l) => l == bump).length, equals(1));
      expect(bumpIdx, greaterThan(changedIdx));
      expect(changedIdx, greaterThan(breakingIdx));
      // The created Highlights block leads the section, ahead of the breaking
      // subsection — the order every released section uses.
      expect(highlightsIdx, lessThan(breakingIdx));
      expect(
        lines.where((l) => l.startsWith('#### ✨ Highlights')).length,
        equals(1),
      );
      // Pre-existing content is untouched.
      expect(result, contains('- Something breaking'));
      expect(result, contains('- Existing change'));
    });

    test('creates #### Changed after the breaking one, before #### Fixed', () {
      // Only the breaking variant exists, so `#### Changed` has to be created.
      // It belongs between them, per the documented subsection order.
      const breakingOnly = '''
# Changelog

## [Unreleased]

### For Users

#### Changed (Breaking)

- Something breaking

#### Fixed

- Bug fix

## [1.4.2] - 2026-07-20

- Prior release
''';
      final result = insertChangelogEntry(
        currentChangelog: breakingOnly,
        nativeHighlight: '**openmls v0.8.2** — protocol update',
        changed: '- Update openmls native library to v0.8.2',
      );

      final lines = result.split('\n');
      final breakingIdx = lines.indexOf('#### Changed (Breaking)');
      final changedIdx = lines.indexOf('#### Changed');
      final fixedIdx = lines.indexOf('#### Fixed');

      expect(changedIdx, greaterThan(breakingIdx));
      expect(changedIdx, lessThan(fixedIdx));
      expect(result, contains('- Bug fix'));
    });
  });
}
