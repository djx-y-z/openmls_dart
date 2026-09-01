import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/update_template.dart';

/// A CHANGELOG shaped like this project's: an `[Unreleased]` section split by
/// audience, above a released section that must never be written into.
String changelog({required String unreleasedBody}) =>
    '''
# Changelog

## [Unreleased]

$unreleasedBody
## [2.0.0] - 2026-07-30

### For Contributors

#### Changed

- **An older entry** — belongs to the released section.
''';

/// The line the released section carries, used to assert nothing was inserted
/// into it. A release is immutable once cut.
const releasedMarker =
    '- **An older entry** — belongs to the released section.';

/// Index of [needle] in [haystack]'s lines, or -1.
int lineOf(String haystack, String needle) =>
    haystack.split('\n').indexWhere((l) => l.trim() == needle.trim());

void main() {
  group('parseUnmergedPaths', () {
    test('collapses the three conflict stages into one path', () {
      // What `git ls-files -u` prints for a single unmerged file: base, ours
      // and theirs. Reporting it three times would inflate the conflict count
      // the pull request shows.
      const output =
          '100644 263041c 1\tCONTRIBUTING.md\n'
          '100644 51013f5 2\tCONTRIBUTING.md\n'
          '100644 2fce9be 3\tCONTRIBUTING.md';
      expect(parseUnmergedPaths(output), ['CONTRIBUTING.md']);
    });

    test('keeps a path containing spaces intact', () {
      // The path is the only field that may contain whitespace, so it is taken
      // from the tab onwards rather than by splitting on spaces.
      const output = '100644 263041c 1\tdocs/my notes.md';
      expect(parseUnmergedPaths(output), ['docs/my notes.md']);
    });

    test('returns nothing for a clean tree', () {
      expect(parseUnmergedPaths(''), isEmpty);
      expect(parseUnmergedPaths('\n\n'), isEmpty);
    });

    test('skips a line with no tab rather than misreading it', () {
      expect(parseUnmergedPaths('garbage without a tab'), isEmpty);
    });

    test('sorts, so the reported order does not depend on git', () {
      const output = '100644 a 1\tz.md\n100644 b 1\ta.md';
      expect(parseUnmergedPaths(output), ['a.md', 'z.md']);
    });
  });

  group('hasConflictMarkers', () {
    test('detects a marker copier wrote', () {
      expect(
        hasConflictMarkers('intro\n<<<<<<< before updating\nours\n'),
        isTrue,
      );
    });

    test('ignores prose that merely mentions markers', () {
      // This repository documents the update procedure, including how to grep
      // for conflicts. An unanchored match would flag its own documentation —
      // and, through it, every future update as conflicted.
      const doc =
          'Check for conflict markers:\n'
          '```bash\n'
          'grep -r "<<<<<<" . --include="*.md"\n'
          '```\n'
          'Then resolve each one.';
      expect(hasConflictMarkers(doc), isFalse);
    });

    test('ignores a marker that is not at line start', () {
      expect(hasConflictMarkers('the marker is <<<<<<< here'), isFalse);
    });

    test('returns false for ordinary content', () {
      expect(hasConflictMarkers('# Title\n\nSome text.\n'), isFalse);
    });
  });

  group('insertContributorChangelogEntry', () {
    const entry = '- **new template entry** — what changed.';

    test('inserts at the top of an existing For Contributors → Changed', () {
      final result = insertContributorChangelogEntry(
        currentChangelog: changelog(
          unreleasedBody: '''
### For Contributors

#### Changed

- **An existing unreleased entry** — stays.

''',
        ),
        entry: entry,
      );

      final newIdx = lineOf(result, entry);
      final oldIdx = lineOf(
        result,
        '- **An existing unreleased entry** — stays.',
      );
      expect(newIdx, greaterThan(-1));
      // Newest first, matching how the section is written by hand.
      expect(newIdx, lessThan(oldIdx));
      // The existing heading was reused, not duplicated. Counted within
      // Unreleased only — the released section below carries one of its own.
      final unreleased = result.substring(
        0,
        result.indexOf('## [2.0.0] - 2026-07-30'),
      );
      expect('#### Changed\n'.allMatches(unreleased).length, 1);
    });

    test('creates a missing Changed subsection inside For Contributors', () {
      final result = insertContributorChangelogEntry(
        currentChangelog: changelog(
          unreleasedBody: '''
### For Contributors

#### Fixed

- **A fix** — stays.

''',
        ),
        entry: entry,
      );

      expect(result, contains('#### Changed'));
      expect(
        lineOf(result, entry),
        greaterThan(lineOf(result, '#### Changed')),
      );
      // Appended after the existing subsection rather than reordering it.
      expect(
        lineOf(result, entry),
        greaterThan(lineOf(result, '- **A fix** — stays.')),
      );
    });

    test('never files the entry under Changed (Breaking)', () {
      // A prefix match would announce a routine template adoption as a
      // breaking change.
      final result = insertContributorChangelogEntry(
        currentChangelog: changelog(
          unreleasedBody: '''
### For Contributors

#### Changed (Breaking)

- **A breaking change** — stays.

''',
        ),
        entry: entry,
      );

      final breakingIdx = lineOf(result, '#### Changed (Breaking)');
      final entryIdx = lineOf(result, entry);
      final plainChangedIdx = result
          .split('\n')
          .indexWhere((l) => l.trimRight() == '#### Changed');

      expect(plainChangedIdx, greaterThan(breakingIdx));
      expect(entryIdx, greaterThan(plainChangedIdx));
    });

    test('creates For Contributors after For Users when it is absent', () {
      final result = insertContributorChangelogEntry(
        currentChangelog: changelog(
          unreleasedBody: '''
### For Users

#### Security

- **A user-facing fix** — stays.

''',
        ),
        entry: entry,
      );

      final usersIdx = lineOf(result, '### For Users');
      final contributorsIdx = lineOf(result, '### For Contributors');
      expect(contributorsIdx, greaterThan(usersIdx));
      expect(lineOf(result, entry), greaterThan(contributorsIdx));
      // The user-facing entry keeps its place.
      expect(result, contains('- **A user-facing fix** — stays.'));
    });

    test('does not write into the released section', () {
      // The one failure that cannot be undone by editing forward: a released
      // heading is immutable, and every insertion point here is bounded by the
      // next `## [` heading for that reason.
      final result = insertContributorChangelogEntry(
        currentChangelog: changelog(
          unreleasedBody: '''
### For Users

#### Security

- **A user-facing fix** — stays.

''',
        ),
        entry: entry,
      );

      expect(
        lineOf(result, entry),
        lessThan(lineOf(result, '## [2.0.0] - 2026-07-30')),
      );
      expect(
        lineOf(result, releasedMarker),
        greaterThan(lineOf(result, entry)),
      );
    });

    test('creates an Unreleased section when there is none', () {
      // The state a release leaves behind: it no longer leaves an empty
      // `## [Unreleased]` for the next entry to land in.
      const released = '''
# Changelog

## [2.0.0] - 2026-07-30

### For Contributors

#### Changed

- **An older entry** — belongs to the released section.
''';

      final result = insertContributorChangelogEntry(
        currentChangelog: released,
        entry: entry,
      );

      expect(result, contains('## [Unreleased]'));
      expect(
        lineOf(result, '## [Unreleased]'),
        lessThan(lineOf(result, '## [2.0.0] - 2026-07-30')),
      );
      expect(lineOf(result, entry), lessThan(lineOf(result, releasedMarker)));
    });
  });

  // `copier copy` ends with a `dart format .` task, because the template
  // hard-wraps Dart whose rendered width depends on the answers. `copier
  // update` runs no tasks, so this stands in for that one — and it has to
  // survive the state an update most often leaves behind.
  group('formatAfterUpdate', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('fmt_after_update'));
    tearDown(() => dir.deleteSync(recursive: true));

    File write(String name, String content) =>
        File('${dir.path}/$name')..writeAsStringSync(content);

    test('formats what copier left unformatted', () async {
      final file = write('ugly.dart', 'void main(){final x=1;   print(x);}\n');

      await formatAfterUpdate(workingDirectory: dir.path);

      expect(
        file.readAsStringSync(),
        'void main() {\n  final x = 1;\n  print(x);\n}\n',
      );
    });

    test('leaves a conflicted file alone and does not throw', () async {
      const marked =
          '<<<<<<< before updating\n'
          "void main() { print('ours'); }\n"
          '=======\n'
          "void main() { print('theirs'); }\n"
          '>>>>>>> after updating\n';
      final conflicted = write('conflicted.dart', marked);
      final ugly = write('ugly.dart', 'void main(){final x=1;   print(x);}\n');

      // The formatter exits non-zero here, because a file carrying conflict
      // markers cannot be parsed. That is expected — findConflicts has already
      // reported it — and must not fail the update.
      await expectLater(
        formatAfterUpdate(
          conflicts: const ['conflicted.dart'],
          workingDirectory: dir.path,
        ),
        completes,
      );

      expect(conflicted.readAsStringSync(), marked);
      expect(ugly.readAsStringSync(), contains('  final x = 1;'));
    });

    test('is a no-op on an already formatted tree', () async {
      const formatted = 'void main() {}\n';
      final file = write('fine.dart', formatted);

      await formatAfterUpdate(workingDirectory: dir.path);

      expect(file.readAsStringSync(), formatted);
    });
  });
}
