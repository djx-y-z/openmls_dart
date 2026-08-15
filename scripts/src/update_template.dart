// Apply a copier template update and record it in CHANGELOG.md.
//
// This is the write half of the template automation; `check_template_updates`
// is the read half that decides whether there is anything to do. Everything
// here is driven by `.copier-answers.yml`, so nothing in this file names the
// project or its upstream library — it renders unchanged into any project
// generated from the same template.
//
// The two failure modes worth naming, because they are independent and only
// one of them is loud:
//
//   * A **conflict** — copier could not merge a hunk and left the file with
//     both sides in it, and the path unmerged (`UU`) in the index. Conflicts
//     are not confined to any one file type: a single real update left them in
//     `Makefile`, `pubspec.yaml`, `rust/Cargo.toml`, `rust/src/frb_generated.rs`
//     and two Dart scripts. Some of those would eventually fall over in a
//     later gate, but the ones in `Makefile` and Markdown pass every gate this
//     project has, and none of them names the update as the cause. Detection
//     here is the only signal that points at the right thing.
//   * **`_commit` not landing** — copier applied files but left
//     `.copier-answers.yml` pointing at the old version. That one is quiet and
//     self-perpetuating: the next scheduled run sees the same update pending
//     and opens the same pull request again, forever.
//
// A conflict does not imply the second: verified against a real update where
// `_commit` moved to the new version while `CONTRIBUTING.md` was still
// unmerged. They are reported separately for that reason.
library;

import 'dart:convert';
import 'dart:io';

import 'check_template_updates.dart';
import 'common.dart';

/// Marker copier writes at the start of the "before" side of a conflict.
///
/// Anchored at line start and matched with copier's own wording rather than a
/// bare `<<<<<<<`, so prose *about* conflicts — this repository documents the
/// update procedure, including how to grep for them — cannot register as one.
const _conflictMarker = '<<<<<<< ';

/// Outcome of applying a template update.
class TemplateUpdateResult {
  const TemplateUpdateResult({
    required this.fromVersion,
    required this.toVersion,
    required this.commitLanded,
    required this.conflicts,
    required this.changelogUpdated,
    this.changelogError = '',
  });

  /// Template version recorded before the update ran.
  final String fromVersion;

  /// Template version requested.
  final String toVersion;

  /// Whether `.copier-answers.yml` now records [toVersion].
  final bool commitLanded;

  /// Repository-relative paths copier could not merge, sorted.
  final List<String> conflicts;

  /// Whether a CHANGELOG entry was generated and inserted.
  final bool changelogUpdated;

  /// Why the CHANGELOG step did not run, when it did not.
  final String changelogError;

  bool get hasConflicts => conflicts.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'from_version': fromVersion,
    'to_version': toVersion,
    'commit_landed': commitLanded,
    'has_conflicts': hasConflicts,
    'conflicts': conflicts,
    'changelog_updated': changelogUpdated,
    'changelog_error': changelogError,
  };
}

/// Parses the output of `git ls-files -u` into the set of unmerged paths.
///
/// That command prints one line per conflict *stage*, so a single unmerged
/// file appears up to three times (base, ours, theirs). Pure; exposed for
/// testing.
List<String> parseUnmergedPaths(String lsFilesOutput) {
  final paths = <String>{};
  for (final line in lsFilesOutput.split('\n')) {
    if (line.trim().isEmpty) continue;
    // `<mode> <sha> <stage>\t<path>` — the path is everything after the tab,
    // and is the only field that may itself contain whitespace.
    final tab = line.indexOf('\t');
    if (tab == -1) continue;
    final path = line.substring(tab + 1).trim();
    if (path.isNotEmpty) paths.add(path);
  }
  final sorted = paths.toList()..sort();
  return sorted;
}

/// Whether [content] carries a copier conflict marker. Pure; exposed for
/// testing.
bool hasConflictMarkers(String content) {
  for (final line in content.split('\n')) {
    if (line.startsWith(_conflictMarker)) return true;
  }
  return false;
}

/// Every path copier left in a conflicted state, from both signals.
///
/// The unmerged index is authoritative for a fresh update, but it is also
/// erasable — anything that stages the tree (`git add -A`, which the pull
/// request action runs) resolves the index while leaving the markers in the
/// file. Scanning tracked file content as well means a re-run over an already
/// staged tree still reports the conflict instead of declaring it merged.
Future<List<String>> findConflicts({String? workingDirectory}) async {
  final dir = workingDirectory ?? getPackageDir().path;

  final unmerged = await Process.run('git', [
    'ls-files',
    '-u',
  ], workingDirectory: dir);
  final found = <String>{
    if (unmerged.exitCode == 0)
      ...parseUnmergedPaths(unmerged.stdout as String),
  };

  // `git grep` searches tracked files only, which is what we want: build
  // output and dependencies are neither ours nor conflicted. `-I` skips
  // binary files, whose bytes could match the marker by coincidence.
  final grep = await Process.run('git', [
    'grep',
    '-lI',
    '-e',
    '^$_conflictMarker',
  ], workingDirectory: dir);
  // Exit 1 means "no matches", which is the good case, not an error.
  if (grep.exitCode == 0) {
    for (final line in (grep.stdout as String).split('\n')) {
      final path = line.trim();
      if (path.isNotEmpty) found.add(path);
    }
  }

  final sorted = found.toList()..sort();
  return sorted;
}

/// Paths that make the working tree dirty, in `git status --porcelain` form.
///
/// Copier refuses to update a dirty destination, and its own message names
/// nothing: "Destination repository is dirty; cannot continue." Untracked files
/// count — verified with a tree whose only change was one new file, which
/// copier still refused. So this cannot be narrowed to modifications.
Future<List<String>> dirtyPaths({String? workingDirectory}) async {
  final dir = workingDirectory ?? getPackageDir().path;
  final status = await Process.run('git', [
    'status',
    '--porcelain',
  ], workingDirectory: dir);
  if (status.exitCode != 0) return const [];
  return (status.stdout as String)
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// Runs `copier update` for [version], streaming its output to this process.
///
/// `--defaults` is what makes the run non-interactive: without it copier
/// re-asks every question and blocks forever on a runner. `--trust` is still
/// required even though tasks are skipped, because the template also declares
/// `_jinja_extensions`, and because on an update copier inspects the *old*
/// template's `_tasks` too — neither is waived by `--skip-tasks`.
///
/// `--skip-tasks` is about cost and robustness, not correctness. A single
/// `copier update` renders the template three times — into a temporary copy of
/// the old version, into this working tree, and into a temporary copy of the
/// new one — and runs `_tasks` in every one of them. Those tasks exist to
/// *create* a project (`flutter create`, `dart create`, `dart pub get`,
/// `dart format .`); on a project that already exists they only redo work.
/// Measured on a freshly generated project, skipping them took the update from
/// 22s to 7s, and the gap widens with the size of the example apps.
///
/// It also closes the one way an update can damage this tree. Where a failing
/// task lands depends on where its trigger lives. One that fails identically
/// everywhere — `dart pub get` with no network — stops the run in the *first*
/// of the three renders, so this tree is never reached and stays clean with
/// `_commit` unmoved. One whose trigger lives in the **project** passes that
/// render and fails the next, which is this tree. `dart format .` over a
/// locally broken Dart file is that shape, and it was measured: it left the
/// template's version of a customized file in place of the project's, the
/// local change gone from the worktree, and `_commit` bumped as though the
/// update had succeeded. Copier renders here and runs the tasks before it
/// replays the project's diff, so a task dying in between leaves that gap.
///
/// What this is *not*: running the tasks does not eat local edits. Copier's
/// update replays the project's own diff over the freshly rendered tree, and a
/// task that overwrites `example/lib/main.dart` is undone by that replay — a
/// generate/edit/update cycle on this template preserved the edits, and where
/// the template had changed the same file the collision surfaced as an ordinary
/// merge conflict. Worth stating because the obvious "fix" is worse than the
/// problem: gating `_tasks` on
/// `when: "{{ _copier_operation == 'copy' }}"` in `copier.yml` makes the *first*
/// update after that release delete the task-generated example apps —
/// `example/lib`, `example/test`, `example/ios`, `example/android`,
/// `example/pubspec.yaml`, `example_cli/bin/main.dart` — from the tree. The
/// old template version still runs its tasks while the new one does not, so
/// the example apps exist in copier's render of the old version and not in its
/// render of the new one, and copier removes exactly that difference as files
/// the template dropped. Skip the tasks at the call site, where it applies to
/// all three renders at once; do not guard them in `copier.yml`.
Future<int> runCopierUpdate({
  required String version,
  String? workingDirectory,
}) async {
  await requireCommand('copier');
  final dir = workingDirectory ?? getPackageDir().path;

  logStep('Running copier update --vcs-ref=$version ...');
  final process = await Process.start(
    'copier',
    ['update', '--trust', '--defaults', '--skip-tasks', '--vcs-ref=$version'],
    workingDirectory: dir,
    mode: ProcessStartMode.inheritStdio,
  );

  return process.exitCode;
}

/// Reads the template version currently recorded in `.copier-answers.yml`.
String readRecordedTemplateVersion() => readCopierAnswers()['_commit']!;

/// A compact description of what the update changed, for the AI prompt.
///
/// Both halves matter and neither substitutes for the other: the name-status
/// list names files copier *added*, which a diffstat of tracked changes does
/// not show, while the diffstat carries the size of each change.
Future<String> collectUpdateDiff({String? workingDirectory}) async {
  final dir = workingDirectory ?? getPackageDir().path;
  final buffer = StringBuffer();

  final status = await Process.run('git', [
    'status',
    '--porcelain',
  ], workingDirectory: dir);
  if (status.exitCode == 0) {
    buffer
      ..writeln('Working tree status:')
      ..writeln((status.stdout as String).trim());
  }

  final stat = await Process.run('git', [
    'diff',
    '--stat',
  ], workingDirectory: dir);
  if (stat.exitCode == 0 && (stat.stdout as String).trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Diffstat of modified tracked files:')
      ..writeln((stat.stdout as String).trim());
  }

  const maxChars = 6000;
  final text = buffer.toString();
  return text.length > maxChars
      ? '${text.substring(0, maxChars)}\n... (truncated)'
      : text;
}

/// Inserts [entry] under `### For Contributors` → `#### Changed` in
/// `## [Unreleased]`, creating whichever headings are missing. Pure; exposed
/// for testing.
///
/// Adopting a template is a contributor-facing change: it moves CI, tooling
/// and developer setup, and every template adoption recorded in this project's
/// history lives in that subsection. When an adoption *does* change what the
/// published package does, that is a judgement the reviewer makes and moves —
/// the pull request body asks for exactly that — rather than something guessed
/// here from release notes.
///
/// A missing subsection is appended to the end of its block rather than sorted
/// into place. `#### Changed` is last in the For Contributors blocks this
/// project writes, and appending cannot reorder anything that already exists.
String insertContributorChangelogEntry({
  required String currentChangelog,
  required String entry,
}) {
  final lines = currentChangelog.split('\n');

  final unreleasedIdx = lines.indexWhere(
    (l) => l.startsWith('## [Unreleased]'),
  );
  if (unreleasedIdx == -1) {
    return _createUnreleasedWithEntry(lines, entry);
  }

  // The Unreleased block runs to the next release heading, or to EOF.
  var unreleasedEnd = lines.length;
  for (var i = unreleasedIdx + 1; i < lines.length; i++) {
    if (lines[i].startsWith('## [') && !lines[i].contains('Unreleased')) {
      unreleasedEnd = i;
      break;
    }
  }

  final contributorsIdx = _indexIn(
    lines,
    unreleasedIdx + 1,
    unreleasedEnd,
    (l) => l.startsWith('### For Contributors'),
  );

  if (contributorsIdx == -1) {
    // No For Contributors block: create it at the end of Unreleased, which is
    // where the documented section order puts it — after For Users.
    final at = _trimmedEnd(lines, unreleasedEnd);
    return (List<String>.from(lines)..insertAll(at, [
          '',
          '### For Contributors',
          '',
          '#### Changed',
          '',
          entry,
        ]))
        .join('\n');
  }

  // The For Contributors block runs to the next `###`/`##` heading.
  var contributorsEnd = unreleasedEnd;
  for (var i = contributorsIdx + 1; i < unreleasedEnd; i++) {
    if (lines[i].startsWith('## ') ||
        (lines[i].startsWith('### ') &&
            !lines[i].startsWith('### For Contributors'))) {
      contributorsEnd = i;
      break;
    }
  }

  // `#### Changed` matched exactly: `#### Changed (Breaking)` is a different
  // subsection, and a prefix match would file the entry under it.
  final changedIdx = _indexIn(
    lines,
    contributorsIdx + 1,
    contributorsEnd,
    (l) => l.trimRight() == '#### Changed',
  );

  if (changedIdx == -1) {
    final at = _trimmedEnd(lines, contributorsEnd);
    return (List<String>.from(
      lines,
    )..insertAll(at, ['', '#### Changed', '', entry])).join('\n');
  }

  // Insert at the top of the existing subsection, ahead of older entries.
  var at = changedIdx + 1;
  while (at < contributorsEnd && lines[at].trim().isEmpty) {
    at++;
  }
  return (List<String>.from(lines)..insertAll(at, [entry, ''])).join('\n');
}

/// Index of the first line in `[start, end)` satisfying [test], or -1.
int _indexIn(
  List<String> lines,
  int start,
  int end,
  bool Function(String) test,
) {
  for (var i = start; i < end && i < lines.length; i++) {
    if (test(lines[i])) return i;
  }
  return -1;
}

/// [end], backed up over trailing blank lines, so an insertion there keeps the
/// blank line that separates the block from whatever follows it.
int _trimmedEnd(List<String> lines, int end) {
  var at = end;
  while (at > 0 && lines[at - 1].trim().isEmpty) {
    at--;
  }
  return at;
}

/// Creates an `## [Unreleased]` section holding [entry], above the newest
/// release. Reached after a release, which deliberately leaves no empty
/// `## [Unreleased]` behind.
String _createUnreleasedWithEntry(List<String> lines, String entry) {
  var insertIndex = lines.length;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## [') && !lines[i].contains('Unreleased')) {
      insertIndex = i;
      break;
    }
  }

  return (List<String>.from(lines)..insertAll(insertIndex, [
        '## [Unreleased]',
        '',
        '### For Contributors',
        '',
        '#### Changed',
        '',
        entry,
        '',
      ]))
      .join('\n');
}

/// Asks GitHub Models to write the CHANGELOG entry for this adoption.
///
/// The prompt is given the template's own changelog *and* the diff the update
/// produced here. The second is what keeps the entry honest: a template
/// release describes everything it changed for every project generated from
/// it, while the diff shows the subset that actually landed in this one — the
/// rest arrives as a no-op and must not be announced as a change.
Future<String> generateTemplateChangelogEntry({
  required String fromVersion,
  required String toVersion,
  required String templateRepo,
  required String templateChangelog,
  required String updateDiff,
  required String currentChangelog,
  required String token,
}) async {
  final styleContext = currentChangelog.split('\n').take(200).join('\n');
  final compareUrl =
      'https://github.com/$templateRepo/compare/$fromVersion...$toVersion';

  final prompt =
      '''
You are writing one CHANGELOG.md entry for a Dart package that is generated
from a copier template. The project just adopted template $fromVersion -> $toVersion.

## The template's own changelog for this range:
$templateChangelog

## The diff this update actually produced in THIS project:
$updateDiff

## Existing CHANGELOG.md, for tone and formatting:
$styleContext

## Your task
Return a JSON object with EXACTLY ONE string field, "entry": a single Markdown
list item to file under "### For Contributors" -> "#### Changed".

## Rules
1. The first line must start exactly with:
   "- **copier template adopted: $fromVersion -> $toVersion** — "
   using a real em-dash, then a short summary of what the adoption changes here.
2. Wrap lines at 80 characters. Continuation lines are indented by two spaces.
3. Describe ONLY what appears in the diff above. A template release covers every
   project generated from it; anything that did not land here is not a change
   here. This is the single most common failure of this step.
4. When a part of the release arrives byte-identical because this project
   already had it, say so plainly instead of claiming it as new.
5. Name concrete files and settings, in backticks. Explain WHY a change matters,
   not just what moved — match the density of the existing entries above.
6. No headings, no nested bullet list, no trailing blank line. One list item.
7. Do not invent verification you did not see, and do not use the words
   "verified" or "tested" about anything not visible in the diff.

Return ONLY valid JSON, no markdown code fences.
''';

  final requestBody = jsonEncode({
    'model': 'gpt-4o-mini',
    'messages': [
      {'role': 'user', 'content': prompt},
    ],
    'temperature': 0.3,
    'max_tokens': 1200,
  });

  final result = await Process.run('curl', [
    '-s',
    '-X',
    'POST',
    'https://models.github.ai/inference/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer $token',
    '-d',
    requestBody,
  ]);

  if (result.exitCode != 0) {
    throw Exception('GitHub Models API request failed');
  }

  final response = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  if (response.containsKey('error')) {
    final error = response['error'] as Map<String, dynamic>;
    throw Exception('API error: ${error['message']}');
  }

  final choices = response['choices'] as List<Object?>?;
  if (choices == null || choices.isEmpty) {
    throw Exception('No response from AI');
  }
  final firstChoice = choices[0];
  if (firstChoice is! Map<String, dynamic>) {
    throw Exception('Invalid response format from AI');
  }
  final message = firstChoice['message'] as Map<String, dynamic>?;
  if (message == null) {
    throw Exception('No message in AI response');
  }
  final content = (message['content'] as String).trim();

  String? entryFrom(String raw) {
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final entry = parsed['entry'];
      if (entry is String && entry.trim().isNotEmpty) return entry.trimRight();
    } catch (_) {
      // Fall through to the brace-extraction attempt below.
    }
    return null;
  }

  final direct = entryFrom(content);
  if (direct != null) return direct;

  final braces = RegExp(r'\{[\s\S]*\}').firstMatch(content);
  if (braces != null) {
    final extracted = entryFrom(braces.group(0)!);
    if (extracted != null) return extracted;
  }

  // A fixed, honest entry beats a malformed one: the adoption is real even
  // when the model's output is not usable, and the pull request says the entry
  // needs writing.
  return '- **copier template adopted: $fromVersion → $toVersion** — see the '
      'template changelog for this range ([compare]($compareUrl)). This entry '
      'was not generated automatically and needs writing.';
}

/// Applies the update end to end and returns what happened.
///
/// Ordering is load-bearing in two places. The current version is read *before*
/// copier runs, because copier rewrites the answers file that holds it. The
/// diff is collected before the CHANGELOG is edited, so the prompt describes
/// the update rather than this function's own edit.
Future<TemplateUpdateResult> applyTemplateUpdate({
  required String toVersion,
  String? aiToken,
  bool skipChangelog = false,
}) async {
  final packageDir = getPackageDir().path;

  final fromVersion = readRecordedTemplateVersion();
  logInfo('Current template version: $fromVersion');
  logInfo('Updating to: $toVersion');

  if (fromVersion == toVersion) {
    logWarn('Template already records $toVersion — running copier anyway.');
  }

  // Checked here rather than left to copier, which names nothing it objected
  // to. In CI this is also the tripwire for anything that dirties the tree
  // before this step: `fvm install` used to rewrite `.fvmrc` on every run,
  // which would have blocked every automated update outright.
  final dirty = await dirtyPaths(workingDirectory: packageDir);
  if (dirty.isNotEmpty) {
    throw Exception(
      'Working tree is not clean — copier refuses to update a dirty '
      'destination, including for untracked files.\n'
      '${dirty.map((l) => '  $l').join('\n')}\n'
      'Commit or stash these and retry.',
    );
  }

  // Fetched before the update, while the answers file still names the version
  // this project is coming from.
  var templateChangelog = '';
  var templateRepo = extractGitHubRepo(readCopierAnswers()['_src_path']!);
  try {
    final check = await checkForTemplateUpdates(
      targetVersion: toVersion,
      silent: true,
    );
    templateChangelog = check.changelog;
    templateRepo = check.templateRepo;
  } catch (e) {
    logWarn('Could not fetch the template changelog: $e');
  }

  final exitCode = await runCopierUpdate(
    version: toVersion,
    workingDirectory: packageDir,
  );
  if (exitCode != 0) {
    throw Exception('copier update failed with exit code $exitCode');
  }

  final conflicts = await findConflicts(workingDirectory: packageDir);
  if (conflicts.isEmpty) {
    logSuccess('copier merged everything cleanly.');
  } else {
    logWarn('copier left ${conflicts.length} file(s) conflicted:');
    for (final path in conflicts) {
      logWarn('  $path');
    }
  }

  final recorded = readRecordedTemplateVersion();
  final commitLanded = recorded == toVersion;
  if (!commitLanded) {
    logError(
      '.copier-answers.yml still records "$recorded", not "$toVersion". '
      'Without the bump the next run repeats this same update.',
    );
  }

  var changelogUpdated = false;
  var changelogError = '';

  if (skipChangelog) {
    changelogError = 'skipped by request';
  } else if (aiToken == null || aiToken.isEmpty) {
    changelogError = 'no AI token provided';
    logWarn('No AI token — skipping the CHANGELOG entry.');
  } else if (conflicts.contains('CHANGELOG.md')) {
    // Editing a file that still holds both sides of a conflict would bury the
    // markers inside a new entry and make the resolution harder to see.
    changelogError = 'CHANGELOG.md is conflicted';
    logWarn('CHANGELOG.md is conflicted — leaving it alone.');
  } else {
    try {
      final updateDiff = await collectUpdateDiff(workingDirectory: packageDir);
      final changelogFile = File('$packageDir/CHANGELOG.md');
      final currentChangelog = changelogFile.readAsStringSync();

      logStep('Generating the CHANGELOG entry...');
      final entry = await generateTemplateChangelogEntry(
        fromVersion: fromVersion,
        toVersion: toVersion,
        templateRepo: templateRepo,
        templateChangelog: templateChangelog,
        updateDiff: updateDiff,
        currentChangelog: currentChangelog,
        token: aiToken,
      );

      changelogFile.writeAsStringSync(
        insertContributorChangelogEntry(
          currentChangelog: currentChangelog,
          entry: entry,
        ),
      );
      changelogUpdated = true;
      logSuccess('CHANGELOG.md updated.');
    } catch (e) {
      changelogError = '$e';
      logWarn('CHANGELOG entry failed: $e');
    }
  }

  return TemplateUpdateResult(
    fromVersion: fromVersion,
    toVersion: toVersion,
    commitLanded: commitLanded,
    conflicts: conflicts,
    changelogUpdated: changelogUpdated,
    changelogError: changelogError,
  );
}

/// Appends the result to a GitHub Actions outputs file.
void writeUpdateGitHubOutputs({
  required TemplateUpdateResult result,
  required String outputPath,
}) {
  final buffer = StringBuffer()
    ..writeln('from_version=${result.fromVersion}')
    ..writeln('to_version=${result.toVersion}')
    ..writeln('commit_landed=${result.commitLanded}')
    ..writeln('has_conflicts=${result.hasConflicts}')
    ..writeln('conflict_count=${result.conflicts.length}')
    ..writeln('changelog_updated=${result.changelogUpdated}')
    ..writeln('changelog_error=${result.changelogError.replaceAll('\n', ' ')}');

  if (result.conflicts.isEmpty) {
    buffer.writeln('conflict_files=');
  } else {
    buffer
      ..writeln('conflict_files<<CONFLICTS_EOF')
      ..writeln(result.conflicts.map((p) => '- `$p`').join('\n'))
      ..writeln('CONFLICTS_EOF');
  }

  File(outputPath).writeAsStringSync(buffer.toString(), mode: FileMode.append);
}

/// Prints a human-readable summary of the update.
void printUpdateSummary({required TemplateUpdateResult result}) {
  print('');
  print('========================================');
  print('  Template Update Applied');
  print('========================================');
  print('');
  print('  From:            ${result.fromVersion}');
  print('  To:              ${result.toVersion}');
  print(
    '  _commit landed:  ${result.commitLanded ? Colors.colorize('yes', Colors.green) : Colors.colorize('NO', Colors.red)}',
  );
  print(
    '  Conflicts:       ${result.conflicts.isEmpty ? Colors.colorize('none', Colors.green) : Colors.colorize('${result.conflicts.length}', Colors.red)}',
  );
  for (final path in result.conflicts) {
    print('                     $path');
  }
  print(
    '  CHANGELOG:       ${result.changelogUpdated ? Colors.colorize('updated', Colors.green) : 'not updated (${result.changelogError})'}',
  );
  print('');
}
