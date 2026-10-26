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

  group('resolveConflictsBothWays', () {
    test('keeps each side of a block once, and the markers never', () {
      const content =
          'top\n'
          '<<<<<<< before updating\n'
          'ours\n'
          '=======\n'
          'theirs\n'
          '>>>>>>> after updating\n'
          'bottom';
      final resolved = resolveConflictsBothWays(content);
      expect(resolved.before, ['top', 'ours', 'bottom']);
      expect(resolved.after, ['top', 'theirs', 'bottom']);
    });

    test('reads a file with no conflict as itself, both ways', () {
      // `=======` outside a block is content — a Markdown heading underline —
      // and must not open a block that swallows the rest of the file.
      const content = 'Title\n=======\n\ntext';
      final resolved = resolveConflictsBothWays(content);
      expect(resolved.before, content.split('\n'));
      expect(resolved.after, content.split('\n'));
    });
  });

  group('findDuplicatedLines', () {
    // Long enough to count; the threshold keeps `});` and friends out.
    const groupA = [
      "  group('describeFrbTreeDrift', () {",
      "    test('reports a file that differs between the trees', () {",
      '      expect(describeFrbTreeDrift(local, remote), isNotEmpty);',
      '    });',
      '  });',
    ];
    const groupB = [
      "  group('parseLsTree', () {",
      "    test('reads the mode, type, sha and path of each entry', () {",
      '      expect(parseLsTree(listing), hasLength(2));',
      '    });',
      '  });',
    ];
    String file(List<List<String>> blocks) =>
        ['void main() {', for (final b in blocks) ...b, '}', ''].join('\n');

    test('flags a block both sides added, in different places', () {
      // The shape of the real case: the project had group A at the top, the
      // template took it and filed it after group B, and the merge kept both.
      final found = findDuplicatedLines(
        before: file([groupA, groupB]),
        updated: file([groupA, groupB, groupA]),
        rendered: file([groupB, groupA]),
      );
      expect(found, [
        "  group('describeFrbTreeDrift', () {",
        "    test('reports a file that differs between the trees', () {",
        '      expect(describeFrbTreeDrift(local, remote), isNotEmpty);',
      ]);
    });

    test('passes a block the template itself repeats', () {
      // Workflows repeat steps job after job; the render shows the same count.
      final found = findDuplicatedLines(
        before: file([groupA]),
        updated: file([groupA, groupA]),
        rendered: file([groupA, groupA]),
      );
      expect(found, isEmpty);
    });

    test('passes what only one side has, however often', () {
      // Only the project has group A twice: its own choice, not the merge's.
      expect(
        findDuplicatedLines(
          before: file([groupA, groupA]),
          updated: file([groupA, groupA, groupB]),
          rendered: file([groupB]),
        ),
        isEmpty,
      );
      // Only the template has group B twice: a change it made.
      expect(
        findDuplicatedLines(
          before: file([groupA]),
          updated: file([groupA, groupB, groupB]),
          rendered: file([groupA, groupB, groupB]),
        ),
        isEmpty,
      );
    });

    test('ignores lines too short to say anything', () {
      // Both sides have one `});` and the update two, which is more than
      // either — but `});` closes every group there is, and says nothing.
      final found = findDuplicatedLines(
        before: file([groupA]),
        updated: file([groupA, groupB]),
        rendered: file([groupB]),
      );
      expect(found, isEmpty);
    });

    test('in a conflicted file, flags only what every resolution repeats', () {
      final before = file([groupA]);
      final rendered = file([groupB, groupA]);
      // Group A sits in the "after updating" side of the conflict and again
      // below it: keeping "before updating" leaves one copy, so whoever
      // resolves the conflict decides, and nothing is reported.
      final oneWay = [
        'void main() {',
        '<<<<<<< before updating',
        ...groupB,
        '=======',
        ...groupA,
        '>>>>>>> after updating',
        ...groupA,
        '}',
      ].join('\n');
      expect(
        findDuplicatedLines(
          before: before,
          updated: oneWay,
          rendered: rendered,
        ),
        isEmpty,
      );
      // Here both copies are outside the block, so any resolution keeps both.
      final everyWay = [
        'void main() {',
        ...groupA,
        '<<<<<<< before updating',
        '  // ours',
        '=======',
        '  // theirs',
        '>>>>>>> after updating',
        ...groupA,
        '}',
      ].join('\n');
      expect(
        findDuplicatedLines(
          before: before,
          updated: everyWay,
          rendered: rendered,
        ),
        hasLength(3),
      );
    });
  });

  group('copierDataFromAnswers', () {
    test("drops copier's own keys and the header, and keeps every answer", () {
      const answers =
          '# Changes here will be overwritten by Copier; NEVER EDIT MANUALLY\n'
          '_commit: v4.17.0\n'
          '_src_path: https://github.com/example/template.git\n'
          'description: A long description that the YAML writer folded onto\n'
          '    a second line.\n'
          'package_name: example\n';
      expect(
        copierDataFromAnswers(answers),
        'description: A long description that the YAML writer folded onto\n'
        '    a second line.\n'
        'package_name: example\n',
      );
    });
  });

  // The I/O half: which files are compared, against what, and how a finding
  // is reported. A real render needs copier and the network, so the render
  // here is a directory written by hand.
  group('findDuplicatedText', () {
    late Directory repo;
    late Directory render;

    // With an identity of its own and no signing, so it runs the same on a CI
    // runner that has no git configuration at all.
    Future<ProcessResult> git(List<String> args, {bool check = true}) async {
      final result = await Process.run('git', [
        '-c',
        'user.name=test',
        '-c',
        'user.email=test@example.com',
        '-c',
        'commit.gpgsign=false',
        ...args,
      ], workingDirectory: repo.path);
      if (check && result.exitCode != 0) fail('git $args: ${result.stderr}');
      return result;
    }

    void write(Directory root, String name, String content) =>
        File('${root.path}/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    const block =
        '  final first = loadTheFirstThingThisTestNeeds();\n'
        '  final second = loadTheSecondThingThisTestNeeds();\n';

    setUp(() async {
      repo = Directory.systemTemp.createTempSync('dup_repo');
      render = Directory.systemTemp.createTempSync('dup_render');
      await git(['init', '-q', '-b', 'main']);
      write(repo, 'test/a_test.dart', 'void main() {\n${block}x();\n}\n');
      write(repo, 'README.md', '# Title\n');
      await git(['add', '-A']);
      await git(['commit', '-q', '-m', 'base']);
    });

    tearDown(() {
      repo.deleteSync(recursive: true);
      render.deleteSync(recursive: true);
    });

    test('reports a modified file with a block merged in twice', () async {
      write(repo, 'test/a_test.dart', 'void main() {\n${block}x();\n$block}\n');
      write(render, 'test/a_test.dart', 'void main() {\nx();\n$block}\n');
      write(repo, 'README.md', '# Title\n\nMore.\n');
      write(render, 'README.md', '# Title\n\nMore.\n');
      // Added by the update: nothing to merge, so never compared.
      write(repo, 'NEW.md', '$block$block');
      write(render, 'NEW.md', block);

      final paths = await modifiedPaths(workingDirectory: repo.path);
      expect(paths, ['README.md', 'test/a_test.dart']);

      final found = await findDuplicatedText(
        paths: paths,
        renderDirectory: render.path,
        workingDirectory: repo.path,
      );
      expect(found, hasLength(1));
      expect(found.single.path, 'test/a_test.dart');
      expect(found.single.lines, hasLength(2));
      expect(found.single.firstAt, [2, 5]);
      expect(
        found.single.describe(),
        '`test/a_test.dart` — 2 line(s) repeated, the first at lines 2, 5',
      );
    });

    test('lists a file copier left unmerged', () async {
      // The files a conflict left behind are where the merge has been
      // busiest, and the ones a different question to git loses: asked about
      // the index (`--cached`), git reports them as `U`, which `M` drops.
      await git(['checkout', '-q', '-b', 'side']);
      write(repo, 'README.md', '# Side\n');
      await git(['commit', '-q', '-am', 'side']);
      await git(['checkout', '-q', 'main']);
      write(repo, 'README.md', '# Main\n');
      await git(['commit', '-q', '-am', 'main']);
      final merge = await git(['merge', 'side'], check: false);
      expect(merge.exitCode, isNot(0), reason: 'the merge has to conflict');

      expect(await modifiedPaths(workingDirectory: repo.path), ['README.md']);
    });
  });

  group('writeUpdateGitHubOutputs', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('update_outputs'));
    tearDown(() => dir.deleteSync(recursive: true));

    String outputsFor(TemplateUpdateResult result) {
      final path = '${dir.path}/out';
      writeUpdateGitHubOutputs(result: result, outputPath: path);
      return File(path).readAsStringSync();
    }

    TemplateUpdateResult result({
      List<DuplicatedText> duplicates = const [],
      String duplicatesError = '',
    }) => TemplateUpdateResult(
      fromVersion: 'v1.0.0',
      toVersion: 'v1.1.0',
      commitLanded: true,
      conflicts: const [],
      changelogUpdated: false,
      duplicates: duplicates,
      duplicatesError: duplicatesError,
    );

    test('reports the duplicate keys when nothing was found', () {
      // Present on both outcomes: a key that appears only when true cannot be
      // told apart from a script too old to write it.
      final out = outputsFor(result());
      expect(out, contains('has_duplicates=false\n'));
      expect(out, contains('duplicate_count=0\n'));
      expect(out, contains('duplicates_checked=true\n'));
      expect(out, contains('duplicate_files=\n'));
    });

    test('lists each file found, one Markdown item apiece', () {
      final out = outputsFor(
        result(
          duplicates: const [
            DuplicatedText(
              path: 'test/a_test.dart',
              lines: ['a', 'b'],
              firstAt: [2, 5],
            ),
          ],
        ),
      );
      expect(out, contains('has_duplicates=true\n'));
      expect(out, contains('duplicate_count=1\n'));
      expect(
        out,
        contains(
          'duplicate_files<<DUPLICATES_EOF\n'
          '- `test/a_test.dart` — 2 line(s) repeated, the first at lines 2, 5\n'
          'DUPLICATES_EOF\n',
        ),
      );
    });

    test('says the check did not run, on one line', () {
      final out = outputsFor(result(duplicatesError: 'no network\nat all'));
      expect(out, contains('duplicates_checked=false\n'));
      expect(out, contains('duplicates_error=no network at all\n'));
    });
  });

  group('parseCopierData', () {
    test('collects both spellings, a later answer to a key winning', () {
      expect(
        parseCopierData([
          '--version',
          'v4.18.0',
          '--data',
          'upstream_source=crates_io',
          '--data=enable_fuzzing=false',
          '--data',
          'enable_fuzzing=true',
        ]),
        {'upstream_source': 'crates_io', 'enable_fuzzing': 'true'},
      );
    });

    test('keeps an empty value, and an equals sign inside one', () {
      expect(
        parseCopierData([
          '--data',
          'upstream_crates=',
          '--data',
          'forbidden_features=upstream=test-utils',
        ]),
        {'upstream_crates': '', 'forbidden_features': 'upstream=test-utils'},
      );
    });

    test('is empty when nothing is answered', () {
      expect(parseCopierData(['--version', 'v4.18.0', '--json']), isEmpty);
    });

    test('refuses a --data with nothing after it', () {
      expect(() => parseCopierData(['--data']), throwsFormatException);
    });

    test('refuses a key that cannot name a question', () {
      for (final raw in ['upstream-source=crates_io', '=x', 'no_value']) {
        expect(
          () => parseCopierData(['--data', raw]),
          throwsFormatException,
          reason: raw,
        );
      }
    });
  });

  group('copierUpdateArguments', () {
    test('is the plain update when nothing is answered', () {
      expect(copierUpdateArguments(version: 'v4.18.0'), [
        'update',
        '--trust',
        '--defaults',
        '--skip-tasks',
        '--vcs-ref=v4.18.0',
      ]);
    });

    test('hands each answer to copier as --data, after the fixed flags', () {
      expect(
        copierUpdateArguments(
          version: 'v4.18.0',
          data: {'upstream_source': 'crates_io', 'upstream_crates': ''},
        ),
        [
          'update',
          '--trust',
          '--defaults',
          '--skip-tasks',
          '--vcs-ref=v4.18.0',
          '--data',
          'upstream_source=crates_io',
          '--data',
          'upstream_crates=',
        ],
      );
    });
  });

  group('unrecordedData', () {
    const answers =
        '# Changes here will be overwritten by Copier; NEVER EDIT MANUALLY\n'
        '_commit: v4.18.0\n'
        '_src_path: https://github.com/example/template.git\n'
        "description: 'A: quoted, and it''s escaped'\n"
        'enable_fuzzing: false\n'
        "upstream_crates: ''\n"
        'upstream_source: crates_io\n';

    test('is empty when every answer was recorded as given', () {
      expect(
        unrecordedData(
          answers: answers,
          data: {
            'description': "A: quoted, and it's escaped",
            'enable_fuzzing': 'false',
            'upstream_crates': '',
            'upstream_source': 'crates_io',
          },
        ),
        isEmpty,
      );
    });

    // `version_tag_prefix` is what copier drops once `upstream_source` is
    // `crates_io`: its `when:` is false, so it is never recorded.
    test('names a key never recorded, and one recorded differently', () {
      expect(
        unrecordedData(
          answers: answers,
          data: {
            'version_tag_prefix': 'upstream-v',
            'upstream_source': 'git_tag',
          },
        ),
        ['upstream_source', 'version_tag_prefix'],
      );
    });
  });
}
