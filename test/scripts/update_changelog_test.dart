import 'package:test/test.dart';

import '../../scripts/src/ai_client.dart';
import '../../scripts/src/update_changelog.dart';
import '../../scripts/src/upstream_source.dart';

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

/// Two crates of an upstream repository, as `cargo metadata` resolves them.
const _crates = <UpstreamCrate>[
  (name: 'upstream-core', version: '0.1.0', dir: 'rust/core/'),
  (name: 'upstream-protocol', version: '0.1.0', dir: 'rust/protocol/'),
];

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
  _breakingContradictionTests();
  group('releaseNotesFrom', () {
    // The case that made this function exist. `curl -s` has no `-f`, so a
    // rate-limited reply arrives with exit code 0 and no `tag_name`; before the
    // guard it fell through to an absent `body` and returned the "nothing was
    // published" sentinel, which the changelog was then written from as though
    // it were a fact about the release.
    test('a rate-limited reply is an error, not an empty release', () {
      expect(
        () => releaseNotesFrom({
          'message': 'API rate limit exceeded for 20.1.2.3',
          'documentation_url': 'https://docs.github.com/rest',
        }, 'v1.2.3'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('v1.2.3'), contains('rate limit')),
          ),
        ),
      );
    });

    test('a server error is an error too', () {
      expect(
        () => releaseNotesFrom({'message': 'Server Error'}, 'v1.2.3'),
        throwsA(isA<Exception>()),
      );
    });

    test('an unrecognised payload still refuses rather than inventing', () {
      expect(
        () => releaseNotesFrom(<String, dynamic>{}, 'v1.2.3'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('unrecognised response'),
          ),
        ),
      );
    });

    // Kept distinct from the above: a missing release is a fact about the
    // repository and reads differently to whoever has to act on it.
    test('a missing release keeps its own specific message', () {
      expect(
        () => releaseNotesFrom({'message': 'Not Found'}, 'v9.9.9'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Release v9.9.9 not found'),
          ),
        ),
      );
    });

    // The case the guard must NOT break: some upstreams publish every release
    // with an empty body, and that is ordinary rather than an error.
    test('a real release with an empty body is normal', () {
      expect(
        releaseNotesFrom({'tag_name': 'v1.2.3', 'body': ''}, 'v1.2.3'),
        equals('No release notes were published for this release.'),
      );
      expect(
        releaseNotesFrom({'tag_name': 'v1.2.3', 'body': '   \n  '}, 'v1.2.3'),
        equals('No release notes were published for this release.'),
      );
      expect(
        releaseNotesFrom({'tag_name': 'v1.2.3'}, 'v1.2.3'),
        equals('No release notes were published for this release.'),
      );
    });

    test('a real release with a body returns it', () {
      expect(
        releaseNotesFrom({
          'tag_name': 'v1.2.3',
          'body': 'Fixed a thing.',
        }, 'v1.2.3'),
        equals('Fixed a thing.'),
      );
    });
  });

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

    test('creates #### Changed below #### Added, not above it', () {
      // `#### Added` precedes `#### Changed` in the documented order, so it
      // must not anchor the created one. Before this was handled it did, and
      // the new entry was filed above an Added section — silently, since
      // nothing rereads the order afterwards.
      const withAdded = '''
# Changelog

## [Unreleased]

### For Users

#### Added

- A new public method

#### Fixed

- Bug fix

## [1.4.2] - 2026-07-20

- Prior release
''';
      final result = insertChangelogEntry(
        currentChangelog: withAdded,
        nativeHighlight: '**openmls v0.8.2** — protocol update',
        changed: '- Update openmls native library to v0.8.2',
      );

      final lines = result.split('\n');
      final addedIdx = lines.indexOf('#### Added');
      final changedIdx = lines.indexOf('#### Changed');
      final fixedIdx = lines.indexOf('#### Fixed');

      expect(changedIdx, greaterThan(addedIdx));
      expect(changedIdx, lessThan(fixedIdx));
      expect(result, contains('- A new public method'));
      expect(result, contains('- Bug fix'));
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

void _breakingContradictionTests() {
  group('breakingContradictsNoImpact', () {
    test('flags a breaking bullet alongside the no-impact note', () {
      const changed =
          '- Update openmls native library to v0.100.0 (link)\n'
          '  - **BREAKING:** Remove `require_pq_ratio` from the bound API\n'
          "  - Note: These changes do not affect this library's public API";
      expect(breakingContradictsNoImpact(changed), isTrue);
    });

    test('allows a breaking bullet without the note', () {
      const changed =
          '- Update openmls native library to v0.100.0 (link)\n'
          '  - **BREAKING:** SessionBuilder.process now returns a Result';
      expect(breakingContradictsNoImpact(changed), isFalse);
    });

    test('allows the note without a breaking bullet', () {
      const changed =
          '- Update openmls native library to v0.100.0 (link)\n'
          '  - Upstream changes — none of which this library exposes\n'
          "  - Note: These changes do not affect this library's public API";
      expect(breakingContradictsNoImpact(changed), isFalse);
    });

    test('flags the contradiction when the apostrophe is typographic', () {
      // A model writing prose reaches for ’ whatever the example shows, and
      // matching only the straight quote let the contradiction publish while
      // this check read as though it were guarding against it.
      const changed =
          '- Update openmls native library to v0.100.0 (link)\n'
          '  - **BREAKING:** Remove `require_pq_ratio` from the bound API\n'
          '  - Note: These changes do not affect this library’s public API';
      expect(breakingContradictsNoImpact(changed), isTrue);
    });

    test('flags it with a modifier-letter apostrophe too', () {
      const changed =
          '- **BREAKING:** something moved\n'
          '  - Note: These changes do not affect this libraryʼs public API';
      expect(breakingContradictsNoImpact(changed), isTrue);
    });

    test('a curly apostrophe elsewhere is not enough on its own', () {
      const changed =
          '- Update openmls native library to v0.100.0 (link)\n'
          '  - Upstream changes — none of which this library exposes\n'
          '  - The crate’s internals moved, but nothing this package calls';
      expect(breakingContradictsNoImpact(changed), isFalse);
    });
  });

  group('stripLeadingListMarker', () {
    // The regression. `insertChangelogEntry` writes the line as
    // `'- $nativeHighlight'`, so a marker in the model's own answer renders as
    // a nested list under an empty parent bullet. It reached a pull request
    // that way for real. Every `insertChangelogEntry` test above
    // feeds an already-clean string, which is why the suite stayed green.
    test('strips the marker a model copies from the pasted house style', () {
      expect(
        stripLeadingListMarker(
          '- **openmls v0.102.2** — internal/dependency update',
        ),
        equals('**openmls v0.102.2** — internal/dependency update'),
      );
    });

    test('leaves a correctly formatted line alone', () {
      const clean = '**openmls v0.102.2** — internal/dependency update';
      expect(stripLeadingListMarker(clean), equals(clean));
    });

    test('strips `*` and `+` markers, and a doubled one', () {
      expect(
        stripLeadingListMarker('* **openmls v1.0** — x'),
        equals('**openmls v1.0** — x'),
      );
      expect(
        stripLeadingListMarker('+ **openmls v1.0** — x'),
        equals('**openmls v1.0** — x'),
      );
      expect(
        stripLeadingListMarker('- - **openmls v1.0** — x'),
        equals('**openmls v1.0** — x'),
      );
    });

    // The em-dash the house format puts after the bold summary is not a list
    // marker, and neither is the `*` that opens bold text — only a marker
    // followed by whitespace is one.
    test('does not eat an em-dash or the opening of bold text', () {
      expect(
        stripLeadingListMarker('**openmls v1.0** — x'),
        equals('**openmls v1.0** — x'),
      );
      expect(
        stripLeadingListMarker('*italic* start'),
        equals('*italic* start'),
      );
    });
  });

  group('withStraightQuotes', () {
    // Replayed for real: the typographic apostrophe of the model's prose next
    // to the straight one of the rule-4 phrase, in one paragraph.
    test('straightens apostrophes and quotes, nothing else', () {
      expect(
        withStraightQuotes(
          "this package’s bound crates; “as is”; this library's public API",
        ),
        equals(
          "this package's bound crates; \"as is\"; this library's public API",
        ),
      );
    });

    test('leaves the em-dash and code spans alone', () {
      const clean = '**Bump** — `Timestamp` gains `TryFrom<SystemTime>`';
      expect(withStraightQuotes(clean), equals(clean));
    });
  });

  group('composeChangedEntry', () {
    const paragraph = 'Third-party crates move with it: `cc` 1.8.0.';

    // The replayed entry, cut down: the model's last sentence had no full stop,
    // and the appended paragraph then read as part of it.
    test('closes an open last sentence before appending the paragraph', () {
      expect(
        composeChangedEntry(
          '- **Bump** — detail.\n\n'
          "  So these changes do not affect this library's public API",
          paragraph,
        ),
        equals(
          '- **Bump** — detail.\n\n'
          "  So these changes do not affect this library's public API.\n\n"
          '  $paragraph',
        ),
      );
    });

    test('closes a one-paragraph entry that ends on a code span', () {
      expect(
        composeChangedEntry('- **Bump** — `version.rs` moves to `0.2`', ''),
        equals('- **Bump** — `version.rs` moves to `0.2`.'),
      );
    });

    test('leaves an ending that is already punctuated', () {
      for (final end in ['.', '!', '?', ')', ':']) {
        expect(
          composeChangedEntry('- **Bump** — detail$end', ''),
          equals('- **Bump** — detail$end'),
        );
      }
    });

    test('leaves a nested list item without a full stop', () {
      const entry = '- **Bump** — detail:\n  - `cc` 1.8.0';
      expect(composeChangedEntry(entry, ''), equals(entry));
    });

    test('appends nothing when the lockfile moved nothing', () {
      expect(
        composeChangedEntry('- **Bump** — detail.  \n', ''),
        equals('- **Bump** — detail.'),
      );
    });
  });

  group('inRepoReleaseNotesFrom', () {
    // Some upstreams publish every release with an EMPTY body and keep the
    // notes in `RELEASE_NOTES.md` instead. Without this the prompt is told
    // nothing was published, and the model reports that absence as a fact
    // about the release — which is how "upstream has no published release
    // notes" reached a pull request for a tag whose own file named three
    // changes.
    test('returns the bullets when the file names the tag', () {
      const file =
          'v0.102.2\n'
          '\n'
          '- SVR: Update production SVRB/SVR2 to use 2026Q3.\n'
          '- Backups: Validate the new sharedName field on Contact.\n';
      final notes = inRepoReleaseNotesFrom(file, 'v0.102.2');
      expect(notes, contains('SVR: Update production'));
      expect(notes, contains('Backups: Validate'));
      // The version heading is not part of the notes.
      expect(notes, isNot(startsWith('v0.102.2')));
    });

    // The file is overwritten each release, so a tag whose release commit did
    // not update it would hand back the PREVIOUS release's notes. That is worse
    // than having none — it is wrong rather than missing — so the heading is
    // checked and a mismatch is discarded.
    test('discards a file that names a different release', () {
      const stale = 'v0.102.1\n\n- Allow unknown chunks in webp sanitization\n';
      expect(inRepoReleaseNotesFrom(stale, 'v0.102.2'), isNull);
    });

    test('tolerates a heading that omits or adds the leading v', () {
      expect(
        inRepoReleaseNotesFrom('0.102.2\n\n- A change\n', 'v0.102.2'),
        equals('- A change'),
      );
      expect(
        inRepoReleaseNotesFrom('v0.102.2\n\n- A change\n', '0.102.2'),
        equals('- A change'),
      );
    });

    // `Accept: application/vnd.github.raw` still answers JSON on a miss, and an
    // upstream that keeps no such file must land as "no notes", not as notes
    // reading `{"message":"Not Found"}`.
    test('an API error payload is not release notes', () {
      expect(
        inRepoReleaseNotesFrom('{"message":"Not Found"}', 'v0.102.2'),
        isNull,
      );
    });

    test('a heading with no bullets under it is not release notes', () {
      expect(inRepoReleaseNotesFrom('v0.102.2\n', 'v0.102.2'), isNull);
      expect(inRepoReleaseNotesFrom('', 'v0.102.2'), isNull);
    });
  });

  group('changelogSectionFrom', () {
    const changelog = '''
# Changelog

## [Unreleased]

- Not yet.

## 0.9.10 (2026-11-01)

- Ten.

## 0.9.1 (2026-10-07)

### Fixed

- The fix.

## [0.9.1-rc.1] - 2026-10-01

- Candidate.

## v0.9.0

- Older.
''';

    test('takes the section the version heads, sub-headings included', () {
      expect(
        changelogSectionFrom(changelog, '0.9.1'),
        '### Fixed\n\n- The fix.',
      );
    });

    // Either would hand over another release's notes, which is worse than
    // none: wrong rather than missing.
    test('a longer version, or a pre-release of it, is not it', () {
      final section = changelogSectionFrom(changelog, '0.9.1');
      expect(section, isNot(contains('Ten')));
      expect(section, isNot(contains('Candidate')));
      expect(changelogSectionFrom(changelog, '0.9.1-rc.1'), '- Candidate.');
    });

    test('reads a version after a v as the version', () {
      expect(changelogSectionFrom(changelog, '0.9.0'), '- Older.');
    });

    test('is null when no heading names it, or its section is empty', () {
      expect(changelogSectionFrom(changelog, '1.0.0'), isNull);
      expect(
        changelogSectionFrom('## 1.0.0\n\n## 0.9.0\n- x\n', '1.0.0'),
        isNull,
      );
    });
  });

  group('highlightVersionFor', () {
    // The house format is `**<library> vX.Y.Z**`. A tag carries its own
    // prefix, which written as it is reads `<library> <library>-v1.2.3`, and a
    // registry version carries none; both are written the one way.
    test('names the release v and its version, whatever the pin', () {
      const git = GitTagSource(
        repo: 'owner/upstream',
        crates: ['upstream-core'],
        tagPrefix: 'upstream-v',
      );
      const registry = CratesIoSource(
        repo: 'owner/upstream',
        crates: ['upstream-core'],
      );
      expect(highlightVersionFor(git, 'upstream-v1.2.3'), 'v1.2.3');
      expect(highlightVersionFor(registry, '1.2.3'), 'v1.2.3');
    });

    test('a default line is recognised whatever the version looks like', () {
      for (final version in ['v1.2.3', '1.2.3', 'upstream-v1.2.3']) {
        expect(
          isOwnDefaultHighlight('- ${defaultHighlightFor(version)}'),
          isTrue,
          reason: version,
        );
      }
    });
  });

  group('isOwnDefaultHighlight', () {
    test('matches the prompt default at any version', () {
      expect(
        isOwnDefaultHighlight('- ${defaultHighlightFor('v0.102.1')}'),
        isTrue,
      );
      expect(
        isOwnDefaultHighlight('- ${defaultHighlightFor('v1.2.3')}'),
        isTrue,
      );
    });

    // What it must never match. This entry gets replaced by hand whenever a
    // release deserves more than the default; superseding one of those would
    // delete prose the default cannot reproduce.
    test('does not match a rewritten line', () {
      expect(
        isOwnDefaultHighlight(
          '- **openmls v0.102.1** — upstream bump. Of the four crates from '
          'that',
        ),
        isFalse,
      );
    });

    test('does not match the crate line or a Changed bullet', () {
      expect(
        isOwnDefaultHighlight('- **openmls_frb v1.5.2** — Rust FFI bindings'),
        isFalse,
      );
      expect(isOwnDefaultHighlight('- Update openmls to v0.8.2'), isFalse);
    });
  });

  group('hasRewrittenNativeHighlight', () {
    test('is false when the only native line is the prompt default', () {
      final changelog = _withUnreleased.replaceFirst(
        '- **openmls_frb v1.5.2** — Rust FFI bindings',
        '- ${defaultHighlightFor('v0.8.1')}',
      );
      expect(hasRewrittenNativeHighlight(changelog), isFalse);
    });

    test('is true when a rewritten line is standing', () {
      final changelog = _withUnreleased.replaceFirst(
        '- **openmls_frb v1.5.2** — Rust FFI bindings',
        '- **openmls v0.8.1** — upstream bump. Of the four crates from that\n'
            '  repository in this package, the range changes one file',
      );
      expect(hasRewrittenNativeHighlight(changelog), isTrue);
    });

    // Released sections are immutable and are not the caller's business.
    test('ignores highlights in released sections', () {
      const changelog =
          '# Changelog\n'
          '\n'
          '## [Unreleased]\n'
          '\n'
          '### For Users\n'
          '\n'
          '#### ✨ Highlights\n'
          '\n'
          '- **openmls_frb v1.5.2** — Rust FFI bindings\n'
          '\n'
          '## [1.4.2] - 2026-07-20\n'
          '\n'
          '### For Users\n'
          '\n'
          '#### ✨ Highlights\n'
          '\n'
          '- **openmls v0.8.0** — shipped then, hand-written\n';
      expect(hasRewrittenNativeHighlight(changelog), isFalse);
    });
  });

  group('ciOutputsFor', () {
    // The pull request body is rendered from these keys, so their shape is the
    // contract. Every case here guards a SILENT failure: an absent or malformed
    // key renders as an empty expression in the body, which reads as "nothing
    // to report" rather than as a broken output.
    const model = AiModel('openrouter', 'openai/gpt-5.6-luna');

    test('emits both keys when the section was left stacked', () {
      expect(
        ciOutputsFor(
          const ChangelogUpdate(model: model, highlightsStacked: true),
        ),
        'ai_provider=openrouter/openai/gpt-5.6-luna\n'
        'highlights_stacked=true\n',
      );
    });

    // The case that would otherwise be indistinguishable from a script too old
    // to emit the key at all, which is why it is written rather than omitted.
    test('writes highlights_stacked=false rather than omitting the key', () {
      final outputs = ciOutputsFor(
        const ChangelogUpdate(model: model, highlightsStacked: false),
      );
      expect(outputs, contains('highlights_stacked=false\n'));
      expect(outputs, isNot(contains('highlights_stacked=true')));
    });

    // GITHUB_OUTPUT is one file appended to by several writers in the same
    // step. Without a trailing newline this block joins whatever is appended
    // next, and both the joined keys are then lost rather than one.
    test(
      'terminates every line, so an appended block cannot join the next',
      () {
        for (final stacked in const [true, false]) {
          final outputs = ciOutputsFor(
            ChangelogUpdate(model: model, highlightsStacked: stacked),
          );
          expect(outputs, endsWith('\n'));
          expect(outputs.trimRight().split('\n'), hasLength(2));
        }
      },
    );

    test('publishes the provider half as the id the PR body prints', () {
      expect(
        ciOutputsFor(
          const ChangelogUpdate(
            model: AiModel('anthropic', 'claude-opus-5'),
            highlightsStacked: false,
          ),
        ),
        startsWith('ai_provider=anthropic/claude-opus-5\n'),
      );
    });
  });

  group('insertChangelogEntry supersedes its own native highlight', () {
    // Dependency bumps accumulate on the main branch between releases now, so
    // the second bump in a window meets the first one's Highlights line. That
    // line names the version the section ships, so two of them make the
    // section name two, which has happened for real.
    test('drops the previous default and keeps the new one', () {
      final before = _withUnreleased.replaceFirst(
        '- **openmls_frb v1.5.2** — Rust FFI bindings',
        '- **openmls_frb v1.5.2** — Rust FFI bindings\n'
            '- ${defaultHighlightFor('v0.8.1')}',
      );
      final result = insertChangelogEntry(
        currentChangelog: before,
        nativeHighlight: defaultHighlightFor('v0.8.2'),
        changed: '- **Bumped** — detail',
      );

      expect(result, contains(defaultHighlightFor('v0.8.2')));
      expect(result, isNot(contains(defaultHighlightFor('v0.8.1'))));
      // The crate line is a different Highlights line and stays.
      expect(result, contains('**openmls_frb v1.5.2**'));
    });

    // The safe half of the rule, and the one with the sharp edge: a rewritten
    // highlight runs onto continuation lines, so dropping it by line match
    // would leave those behind as a dangling paragraph. It is not dropped.
    test('keeps a rewritten multi-line highlight intact', () {
      const rewritten =
          '- **openmls v0.8.1** — upstream bump. Of the four crates from that\n'
          '  repository in this package, the range changes exactly one file,\n'
          '  and it is the version string';
      final before = _withUnreleased.replaceFirst(
        '- **openmls_frb v1.5.2** — Rust FFI bindings',
        '- **openmls_frb v1.5.2** — Rust FFI bindings\n$rewritten',
      );
      final result = insertChangelogEntry(
        currentChangelog: before,
        nativeHighlight: defaultHighlightFor('v0.8.2'),
        changed: '- **Bumped** — detail',
      );

      expect(result, contains(rewritten));
      expect(result, contains(defaultHighlightFor('v0.8.2')));
    });

    // Nothing outside [Unreleased] is rewritten, ever.
    test('leaves an identical line in a released section alone', () {
      final before = _withUnreleased.replaceFirst(
        '## [1.4.2] - 2026-07-20',
        '## [1.4.2] - 2026-07-20\n'
            '\n'
            '### For Users\n'
            '\n'
            '#### ✨ Highlights\n'
            '\n'
            '- ${defaultHighlightFor('v0.8.0')}',
      );
      final result = insertChangelogEntry(
        currentChangelog: before,
        nativeHighlight: defaultHighlightFor('v0.8.2'),
        changed: '- **Bumped** — detail',
      );
      expect(result, contains(defaultHighlightFor('v0.8.0')));
    });
  });

  group('upstreamFilesFrom', () {
    Map<String, dynamic> compare(List<Map<String, dynamic>> files) => {
      'commits': <Object?>[],
      'files': files,
    };

    // The whole point of the section. A dependency bump's entry is built on a
    // NEGATIVE claim — "the crates we bind changed only this file" — and that
    // claim is only sound when the list is exhaustive. So the header states it
    // rather than leaving the model to assume.
    test('a short list announces itself COMPLETE and lists every path', () {
      final out = upstreamFilesFrom(
        compare([
          {'filename': 'rust/core/src/version.rs', 'status': 'modified'},
          {'filename': 'rust/net/src/chat.rs', 'status': 'modified'},
        ]),
      );
      expect(out, startsWith('COMPLETE'));
      expect(out, contains('(2)'));
      expect(out, contains('modified rust/core/src/version.rs'));
      expect(out, contains('modified rust/net/src/chat.rs'));
    });

    // The compare API caps `files` at 300 and says so nowhere in the payload,
    // so a list sitting exactly at the ceiling is assumed incomplete. Calling
    // that COMPLETE would licence a false negative claim.
    test('a list at the API ceiling is TRUNCATED, not COMPLETE', () {
      final files = [
        for (var i = 0; i < 300; i++)
          {'filename': 'rust/net/src/f$i.rs', 'status': 'modified'},
      ];
      final out = upstreamFilesFrom(compare(files));
      expect(out, startsWith('TRUNCATED'));
      expect(out, contains('NOT changed'));
    });

    test('299 files is still COMPLETE', () {
      final files = [
        for (var i = 0; i < 299; i++)
          {'filename': 'a/b$i.rs', 'status': 'modified'},
      ];
      expect(upstreamFilesFrom(compare(files)), startsWith('COMPLETE'));
    });

    // The char cap is the other way the list stops being exhaustive, and it
    // has to reach the same verdict as the count cap.
    test('hitting the char cap also downgrades to TRUNCATED', () {
      final files = [
        for (var i = 0; i < 250; i++)
          {
            'filename': 'rust/${'deep/' * 50}module$i/source_file.rs',
            'status': 'modified',
          },
      ];
      final out = upstreamFilesFrom(compare(files));
      expect(out, startsWith('TRUNCATED'));
      // Cut on a line boundary, so no half path is presented as a real one.
      expect(out.split('\n').last, isNot(endsWith('source_file')));
    });

    // The range that made the cap a defect: a 20-commit patch release whose
    // 228 files came to 12 330 characters. The API had returned every file,
    // the old 12 000 cap called the list TRUNCATED anyway, and the entry wrote
    // "the file list is truncated, so it cannot establish…" into the CHANGELOG.
    test('228 files of ordinary length are COMPLETE', () {
      final files = [
        for (var i = 0; i < 228; i++)
          {
            'filename': 'node/ts/net/chat/ChatConnectionTypesFile$i.ts',
            'status': 'modified',
          },
      ];
      final out = upstreamFilesFrom(compare(files));
      expect(out.length, greaterThan(12000));
      expect(out, startsWith('COMPLETE'));
      expect(out, contains('(228)'));
    });

    test('lists the files of the crates it builds apart, first', () {
      final out = upstreamFilesFrom(
        compare([
          {'filename': 'node/ts/index.ts', 'status': 'modified'},
          {'filename': 'rust/protocol/src/timestamp.rs', 'status': 'modified'},
          {'filename': 'rust/net/src/chat.rs', 'status': 'modified'},
          {'filename': 'rust/core/src/version.rs', 'status': 'modified'},
          // A neighbour whose name merely starts like a bound crate's.
          {'filename': 'rust/protocol-ext/src/lib.rs', 'status': 'added'},
        ]),
        crates: _crates,
      );
      expect(out, startsWith('COMPLETE'));
      expect(out, contains('(5)'));
      final bound = out.indexOf(
        'In the upstream crates this package builds (2)',
      );
      final rest = out.indexOf('Everywhere else (3)');
      expect(bound, greaterThan(0));
      expect(rest, greaterThan(bound));
      final boundBlock = out.substring(bound, rest);
      expect(boundBlock, contains('modified rust/protocol/src/timestamp.rs'));
      expect(boundBlock, contains('modified rust/core/src/version.rs'));
      expect(boundBlock, isNot(contains('protocol-ext')));
      expect(
        out.substring(rest),
        contains('added rust/protocol-ext/src/lib.rs'),
      );
    });

    // An empty bound block is a claim, and a strong one, so it is written out
    // rather than left as a missing heading.
    test('says (none) when no bound crate changed', () {
      final out = upstreamFilesFrom(
        compare([
          {'filename': 'java/client/Foo.java', 'status': 'modified'},
        ]),
        crates: _crates,
      );
      expect(
        out,
        contains('In the upstream crates this package builds (0):\n(none)'),
      );
    });

    test('a rename out of a bound crate counts as a change to it', () {
      final out = upstreamFilesFrom(
        compare([
          {
            'filename': 'rust/shared/src/moved.rs',
            'previous_filename': 'rust/core/src/moved.rs',
            'status': 'renamed',
          },
        ]),
        crates: _crates,
      );
      expect(out, contains('In the upstream crates this package builds (1)'));
    });

    test('a rename shows both names', () {
      final out = upstreamFilesFrom(
        compare([
          {
            'filename': 'rust/core/src/new.rs',
            'previous_filename': 'rust/core/src/old.rs',
            'status': 'renamed',
          },
        ]),
      );
      expect(
        out,
        contains('renamed rust/core/src/old.rs -> rust/core/src/new.rs'),
      );
    });

    // No section beats an empty section: a heading with nothing under it reads
    // to a model as "nothing changed", which is the same failure the empty
    // release-notes placeholder exists to prevent.
    test('an absent, empty or malformed list yields no section at all', () {
      expect(upstreamFilesFrom({'commits': <Object?>[]}), isEmpty);
      expect(upstreamFilesFrom(compare([])), isEmpty);
      expect(
        upstreamFilesFrom({'commits': <Object?>[], 'files': 'nope'}),
        isEmpty,
      );
      expect(
        upstreamFilesFrom({
          'commits': <Object?>[],
          'files': [
            {'status': 'modified'},
          ],
        }),
        isEmpty,
      );
    });
  });

  group('upstreamCommitsFrom', () {
    Map<String, dynamic> withCommits(List<String> subjects, {int? total}) => {
      'commits': [
        for (final s in subjects)
          {
            'commit': {'message': '$s\n\nbody line'},
          },
      ],
      'total_commits': ?total,
    };

    test('keeps first lines and drops merge commits', () {
      final out = upstreamCommitsFrom(
        withCommits([
          'Reset for version v1.2.3',
          'Merge pull request #1',
          'Fix a thing',
        ]),
      );
      expect(out, contains('- Reset for version v1.2.3'));
      expect(out, contains('- Fix a thing'));
      expect(out, isNot(contains('Merge pull request')));
    });

    test('says when the compare page did not carry every commit', () {
      final out = upstreamCommitsFrom(withCommits(['One'], total: 260));
      expect(out, contains('and 259 more commits'));
    });
  });

  group('upstreamPatchesFrom', () {
    Map<String, dynamic> compare(List<Map<String, dynamic>> files) => {
      'commits': <Object?>[],
      'files': files,
    };

    test('carries the patches of bound-crate files only', () {
      final out = upstreamPatchesFrom(
        compare([
          {
            'filename': 'rust/protocol/src/timestamp.rs',
            'patch':
                '@@ -34,6 +34,28 @@\n+impl TryFrom<SystemTime> for Timestamp {',
          },
          {'filename': 'rust/net/src/chat.rs', 'patch': '@@ -1 +1 @@\n+net'},
        ]),
        crates: _crates,
      );
      expect(out, contains('### rust/protocol/src/timestamp.rs\n```diff\n'));
      expect(out, contains('impl TryFrom<SystemTime> for Timestamp'));
      expect(out, isNot(contains('rust/net/src/chat.rs')));
    });

    // Named and not explained: a model shown only the path would otherwise
    // reach for a reason.
    test('names a bound file whose patch the payload does not carry', () {
      final out = upstreamPatchesFrom(
        compare([
          {'filename': 'rust/core/src/big.rs'},
        ]),
        crates: _crates,
      );
      expect(out, contains('### rust/core/src/big.rs'));
      expect(out, contains('carries no patch'));
    });

    test('cuts a long patch on a line boundary and says so', () {
      final long = [for (var i = 0; i < 2000; i++) '+line $i'].join('\n');
      final out = upstreamPatchesFrom(
        compare([
          {'filename': 'rust/core/src/big.rs', 'patch': long},
        ]),
        crates: _crates,
      );
      expect(out, contains('(cut at 6000 characters'));
      expect(out, isNot(contains('+line 1999')));
    });

    test('is empty with no crates or no bound file', () {
      final payload = compare([
        {'filename': 'rust/net/src/chat.rs', 'patch': '+x'},
      ]);
      expect(upstreamPatchesFrom(payload, crates: const []), isEmpty);
      expect(upstreamPatchesFrom(payload, crates: _crates), isEmpty);
    });
  });

  group('lockfileChangesFrom', () {
    String lock(List<String> packages) =>
        '# This file is automatically @generated by Cargo.\n'
        'version = 4\n'
        '\n${packages.join('\n')}';
    String reg(String name, String version) =>
        '[[package]]\n'
        'name = "$name"\n'
        'version = "$version"\n'
        'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
        'checksum = "00"\n'
        'dependencies = [\n "other",\n]\n';
    String git(String name, String version, String repo, String rev) =>
        '[[package]]\n'
        'name = "$name"\n'
        'version = "$version"\n'
        'source = "git+https://github.com/$repo?tag=v$version#$rev"\n';
    const own = '[[package]]\nname = "wrapper_frb"\nversion = "7.0.0"\n';

    test('names moves, additions, removals and the git dependencies', () {
      final before = lock([
        own,
        git('upstream-core', '0.1.0', 'owner/upstream', 'aaaaaaa1111'),
        git('ratchet', '1.6.0', 'owner/ratchet', '06959b47'),
        reg('libc', '0.2.189'),
        reg('rand_core', '0.6.4'),
        reg('rand_core', '0.9.3'),
        reg('gone', '1.0.0'),
        reg('same', '2.0.0'),
      ]);
      final after = lock([
        own.replaceFirst('7.0.0', '7.0.1'),
        git('upstream-core', '0.1.0', 'owner/upstream', 'bbbbbbb2222'),
        git('ratchet', '1.6.0', 'owner/ratchet', '06959b47'),
        reg('libc', '0.2.191'),
        reg('rand_core', '0.6.4'),
        reg('rand_core', '0.9.5'),
        reg('fresh', '0.1.0'),
        reg('same', '2.0.0'),
      ]);
      final out = lockfileChangesFrom(before, after);
      expect(
        out,
        contains(
          '- `upstream-core` 0.1.0 (owner/upstream @bbbbbbb), '
          'was 0.1.0 (owner/upstream @aaaaaaa)',
        ),
      );
      expect(
        out,
        contains(
          '- `ratchet` 1.6.0 (owner/ratchet @06959b4), '
          'unchanged',
        ),
      );
      expect(out, contains('Registry crates that moved (2):'));
      expect(out, contains('- `libc` 0.2.189 → 0.2.191'));
      expect(out, contains('- `rand_core` 0.6.4, 0.9.3 → 0.6.4, 0.9.5'));
      expect(out, contains('Registry crates added (1):\n- `fresh` 0.1.0'));
      expect(out, contains('Registry crates removed (1):\n- `gone` 1.0.0'));
      expect(out, isNot(contains('same')));
      // The workspace's own crate is not a dependency move.
      expect(out, isNot(contains('wrapper_frb')));
    });

    test('says (none) for an empty block rather than leaving it out', () {
      final before = lock([reg('libc', '0.2.189')]);
      final after = lock([reg('libc', '0.2.191')]);
      final out = lockfileChangesFrom(before, after);
      expect(out, contains('Registry crates added (0):\n(none)'));
      expect(out, contains('Registry crates removed (0):\n(none)'));
    });

    // The paragraph is the lockfile's, not the model's: every move named, the
    // upstream repository's own crates left to the entry, and a git dependency
    // from another repository stated even when it stayed put.
    test('writes the third-party paragraph itself', () {
      final before = lock([
        git('upstream-core', '0.1.0', 'owner/upstream', 'aaaaaaa1111'),
        git('ratchet', '1.6.0', 'owner/ratchet', '06959b47'),
        reg('libc', '0.2.189'),
        reg('rand_core', '0.6.4'),
        reg('rand_core', '0.9.3'),
        reg('sha2', '0.11.0'),
      ]);
      final after = lock([
        git('upstream-core', '0.1.0', 'owner/upstream', 'bbbbbbb2222'),
        git('ratchet', '1.6.0', 'owner/ratchet', '06959b47'),
        reg('libc', '0.2.191'),
        reg('rand_core', '0.6.4'),
        reg('rand_core', '0.9.5'),
        reg('sha2', '0.11.1'),
      ]);
      expect(
        thirdPartyParagraphFrom(before, after, upstreamRepo: 'owner/upstream'),
        'Third-party crates move with it: `libc` 0.2.191, `rand_core` 0.9.5 '
        'and `sha2` 0.11.1. None is added or removed. `ratchet` stays at '
        '1.6.0 (`06959b4`).',
      );
    });

    test('names additions, removals and a git dependency that moved', () {
      final before = lock([
        git('ratchet', '1.5.3', 'owner/ratchet', 'ccccccc3333'),
        reg('gone', '1.0.0'),
      ]);
      final after = lock([
        git('ratchet', '1.6.0', 'owner/ratchet', '06959b47'),
        reg('fresh', '0.1.0'),
      ]);
      expect(
        thirdPartyParagraphFrom(before, after, upstreamRepo: 'owner/upstream'),
        'No third-party crate moves with it. New to the graph: `fresh` 0.1.0. '
        'Gone from it: `gone` 1.0.0. `ratchet` moves from 1.5.3 (`ccccccc`) '
        'to 1.6.0 (`06959b4`).',
      );
    });

    // With a registry upstream source the upstream crates are registry crates
    // too, and they are the entry's subject: listed apart in the prompt, and
    // never in the third-party paragraph.
    test('keeps registry upstream crates out of the third-party lists', () {
      final before = lock([
        reg('upstream-core', '0.9.0'),
        reg('upstream-traits', '0.6.0'),
        reg('libc', '0.2.189'),
      ]);
      final after = lock([
        reg('upstream-core', '0.9.1'),
        reg('upstream-traits', '0.6.0'),
        reg('upstream-macros', '0.1.0'),
        reg('libc', '0.2.191'),
      ]);
      const upstream = {'upstream-core', 'upstream-traits', 'upstream-macros'};
      final out = lockfileChangesFrom(before, after, upstream: upstream);
      expect(
        out,
        contains(
          'Upstream crates, from the registry:\n'
          '- `upstream-core` 0.9.0 → 0.9.1\n'
          '- `upstream-macros` 0.1.0, added',
        ),
      );
      expect(
        out,
        contains('Registry crates that moved (1):\n- `libc` 0.2.189 → 0.2.191'),
      );
      expect(out, contains('Registry crates added (0):\n(none)'));
      expect(
        thirdPartyParagraphFrom(
          before,
          after,
          upstreamRepo: 'owner/upstream',
          upstream: upstream,
        ),
        'Third-party crates move with it: `libc` 0.2.191. None is added or '
        'removed.',
      );
    });

    test('a bump that moves only upstream crates says no third party did', () {
      final before = lock([
        reg('upstream-core', '0.9.0'),
        reg('libc', '0.2.191'),
      ]);
      final after = lock([
        reg('upstream-core', '0.9.1'),
        reg('libc', '0.2.191'),
      ]);
      expect(
        thirdPartyParagraphFrom(
          before,
          after,
          upstreamRepo: 'owner/upstream',
          upstream: {'upstream-core'},
        ),
        'No third-party crate moves with it. None is added or removed.',
      );
    });

    // Run after the bump is committed, the two sides are equal; no section is
    // better than one saying nothing moved.
    test('is empty when nothing moved', () {
      final same = lock([
        git('ratchet', '1.6.0', 'owner/ratchet', '06959b47'),
        reg('libc', '0.2.191'),
      ]);
      expect(lockfileChangesFrom(same, same), isEmpty);
      expect(
        thirdPartyParagraphFrom(same, same, upstreamRepo: 'owner/upstream'),
        isEmpty,
      );
    });
  });

  group('insertChangelogEntry places the upstream Highlights line', () {
    // The shape of v0.105.0's pull request: the release window already carried
    // two headline bullets, one of them multi-line, and the previous bump's
    // default line below them. The line went in ABOVE the headlines, against
    // the documented order, and was moved back by hand.
    const window = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **A failed call throws a coded exception** —
  **(breaking)** see Changed (Breaking)
- **Async calls no longer hang** — see Fixed
- **openmls v0.104.0** — internal/dependency update, no public-API impact

#### Changed

- **The v0.104.0 bump leaves the surface unchanged** — detail

  Third-party crates move with it.
- **Another change** — detail

#### Fixed

- **A fix** — detail

## [7.4.1] - 2026-09-29

- Prior release
''';

    test('goes after the headline bullets, in place of the old default', () {
      final out = insertChangelogEntry(
        currentChangelog: window,
        nativeHighlight: defaultHighlightFor('v0.105.0'),
        changed: '- **The v0.105.0 bump** — detail',
      );
      final lines = out.split('\n');
      final headline = lines.indexOf(
        '- **Async calls no longer hang** — see Fixed',
      );
      final upstream = lines.indexOf('- ${defaultHighlightFor('v0.105.0')}');
      expect(upstream, headline + 1);
      expect(lines[upstream + 1], isEmpty);
      expect(out, isNot(contains('v0.104.0** — internal')));
    });

    test('goes above the crate line once stage 1 has stamped one', () {
      final out = insertChangelogEntry(
        currentChangelog: window.replaceFirst(
          '- **openmls v0.104.0** — internal/dependency update, no public-API impact',
          '- **openmls_frb v7.1.0** — Rust FFI bindings',
        ),
        nativeHighlight: defaultHighlightFor('v0.105.0'),
        changed: '- **The v0.105.0 bump** — detail',
      );
      final lines = out.split('\n');
      final upstream = lines.indexOf('- ${defaultHighlightFor('v0.105.0')}');
      expect(
        lines[upstream - 1],
        '- **Async calls no longer hang** — see Fixed',
      );
      expect(
        lines[upstream + 1],
        '- **openmls_frb v7.1.0** — Rust FFI bindings',
      );
    });

    // Bumps accumulate between releases; each reads after the one before it.
    test('files the Changed entry last in its block', () {
      final out = insertChangelogEntry(
        currentChangelog: window,
        nativeHighlight: defaultHighlightFor('v0.105.0'),
        changed: '- **The v0.105.0 bump** — detail',
      );
      expect(
        out,
        contains(
          '- **Another change** — detail\n'
          '- **The v0.105.0 bump** — detail\n'
          '\n'
          '#### Fixed',
        ),
      );
      expect(
        out.indexOf('The v0.104.0 bump'),
        lessThan(out.indexOf('The v0.105.0 bump')),
      );
    });

    test('fills an empty Highlights block', () {
      final out = insertChangelogEntry(
        currentChangelog: window.replaceFirst(
          RegExp(r'- \*\*A failed call[\s\S]*?impact\n\n'),
          '',
        ),
        nativeHighlight: defaultHighlightFor('v0.105.0'),
        changed: '- **The v0.105.0 bump** — detail',
      );
      expect(
        out,
        contains(
          '#### ✨ Highlights\n'
          '\n'
          '- ${defaultHighlightFor('v0.105.0')}\n'
          '\n'
          '#### Changed',
        ),
      );
    });

    // A project that has never released has no version heading below
    // [Unreleased]; the link references end the section instead.
    test('stops at the link references when no release follows', () {
      const unreleasedOnly = '''
## [Unreleased]

### For Users

#### Changed

- **First change** — detail

[Unreleased]: https://github.com/owner/repo/commits/main
''';
      final out = insertChangelogEntry(
        currentChangelog: unreleasedOnly,
        nativeHighlight: defaultHighlightFor('v0.1.0'),
        changed: '- **The bump** — detail',
      );
      expect(
        out,
        contains(
          '- **First change** — detail\n'
          '- **The bump** — detail\n'
          '\n'
          '[Unreleased]: https://github.com/owner/repo/commits/main',
        ),
      );
      expect(
        out,
        contains('#### ✨ Highlights\n\n- ${defaultHighlightFor('v0.1.0')}'),
      );
    });
  });
}
