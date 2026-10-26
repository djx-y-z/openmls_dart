// Apply a copier template update and record it in CHANGELOG.md.
//
// This is the write half of the template automation; `check_template_updates`
// is the read half that decides whether there is anything to do. Everything
// here is driven by `.copier-answers.yml`, so nothing in this file names the
// project or its upstream library — it renders unchanged into any project
// generated from the same template.
//
// The three failure modes worth naming, because they are independent and only
// the first of them is loud:
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
//   * **Text merged in twice** — the same lines added on both sides of the
//     merge, in different places, which copier keeps twice without a
//     conflict. It is what happens when the template takes code from a project
//     and files it somewhere else. Nothing downstream notices: a duplicated
//     test runs twice and passes twice, and a repeated paragraph is still
//     valid Markdown.
//
// A conflict does not imply the second: verified against a real update where
// `_commit` moved to the new version while `CONTRIBUTING.md` was still
// unmerged. They are reported separately for that reason.
library;

import 'dart:convert';
import 'dart:io';

import 'ai_client.dart';
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
    this.duplicates = const [],
    this.duplicatesError = '',
    this.changelogError = '',
    this.aiProvider = '',
    this.unrecordedData = const [],
  });

  /// Template version recorded before the update ran.
  final String fromVersion;

  /// Template version requested.
  final String toVersion;

  /// Whether `.copier-answers.yml` now records [toVersion].
  final bool commitLanded;

  /// Repository-relative paths copier could not merge, sorted.
  final List<String> conflicts;

  /// Files in which the merge put the same text in twice, sorted by path.
  final List<DuplicatedText> duplicates;

  /// Why the check for [duplicates] could not run, empty when it ran.
  final String duplicatesError;

  /// Whether a CHANGELOG entry was generated and inserted.
  final bool changelogUpdated;

  /// Why the CHANGELOG step did not run, when it did not.
  final String changelogError;

  /// `provider/model` that wrote the entry, empty when none did.
  ///
  /// Reported so a reviewer can tell which model's house style they are
  /// reading. Without it, a first provider that has quietly started failing
  /// shows up only as entries that drift in style, months later.
  final String aiProvider;

  /// `--data` keys `.copier-answers.yml` does not record as given, sorted:
  /// answers the next update would render without. See [unrecordedData].
  final List<String> unrecordedData;

  bool get hasConflicts => conflicts.isNotEmpty;

  bool get hasDuplicates => duplicates.isNotEmpty;

  bool get duplicatesChecked => duplicatesError.isEmpty;

  Map<String, dynamic> toJson() => {
    'from_version': fromVersion,
    'to_version': toVersion,
    'commit_landed': commitLanded,
    'has_conflicts': hasConflicts,
    'conflicts': conflicts,
    'has_duplicates': hasDuplicates,
    'duplicates': [for (final d in duplicates) d.toJson()],
    'duplicates_checked': duplicatesChecked,
    'duplicates_error': duplicatesError,
    'changelog_updated': changelogUpdated,
    'changelog_error': changelogError,
    'ai_provider': aiProvider,
    'unrecorded_data': unrecordedData,
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

/// A question's name: the key a `--data` answer must have.
final _questionName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Every `--data key=value` and `--data=key=value` in [args], in order, as the
/// answers [runCopierUpdate] hands to copier. A later answer to the same key
/// wins, as it would on copier's own command line. Pure; exposed for testing.
///
/// This is how an update answers what its version newly asks. `copier update`
/// runs with `--defaults`, so a question nobody answered takes its default:
/// `forbidden_features` did when 4.15.0 introduced it, and moving a project's
/// `upstream_source` to `crates_io` meant calling copier by hand.
///
/// Throws [FormatException] for a `--data` with nothing after it, or for a key
/// that cannot be a question's name (`upstream-source=…`, `=…`): copier would
/// take such a key as data no question reads, and the update would land as
/// though it had never been given.
Map<String, String> parseCopierData(List<String> args) {
  final data = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final String raw;
    if (args[i] == '--data') {
      if (i + 1 >= args.length) {
        throw const FormatException('--data needs a key=value after it');
      }
      raw = args[++i];
    } else if (args[i].startsWith('--data=')) {
      raw = args[i].substring('--data='.length);
    } else {
      continue;
    }
    final eq = raw.indexOf('=');
    if (eq < 0 || !_questionName.hasMatch(raw.substring(0, eq))) {
      throw FormatException(
        '--data takes key=value, with a question\'s name as the key; '
        'got "$raw"',
      );
    }
    data[raw.substring(0, eq)] = raw.substring(eq + 1);
  }
  return data;
}

/// The command line [runCopierUpdate] runs, after `copier`. Pure; exposed for
/// testing.
List<String> copierUpdateArguments({
  required String version,
  Map<String, String> data = const {},
}) => [
  'update',
  '--trust',
  '--defaults',
  '--skip-tasks',
  '--vcs-ref=$version',
  for (final answer in data.entries) ...[
    '--data',
    '${answer.key}=${answer.value}',
  ],
];

/// The keys of [data] that [answers], the text of `.copier-answers.yml` after
/// the update, does not record with the value given, sorted. Pure; exposed for
/// testing.
///
/// Copier records an answer only for a question it asked. A key that names no
/// question, or a question whose `when:` is false under the other answers,
/// never reaches the file — measured on this template: `version_tag_prefix` is
/// not recorded once `upstream_source` is `crates_io` — so the next update
/// renders without it, whatever this one did. The file is the one place that
/// says what an update will be repeated with, so that is what is checked.
///
/// Compared as text once YAML's quoting is taken off, which is how copier
/// writes the scalars these questions take. A value it had to write across
/// lines reads as unrecorded and is reported rather than assumed.
List<String> unrecordedData({
  required String answers,
  required Map<String, String> data,
}) {
  final recorded = <String, String>{};
  final line = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*):(?: (.*))?$');
  for (final text in answers.split('\n')) {
    final m = line.firstMatch(text);
    if (m != null) recorded[m.group(1)!] = _unquoteYaml(m.group(2) ?? '');
  }
  return [
    for (final answer in data.entries)
      if (recorded[answer.key] != answer.value) answer.key,
  ]..sort();
}

String _unquoteYaml(String raw) {
  final value = raw.trim();
  if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
    return value.substring(1, value.length - 1).replaceAll("''", "'");
  }
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// Runs `copier update` for [version], streaming its output to this process.
///
/// [data] answers questions as `--data` does on copier's own command line —
/// see [parseCopierData].
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
  Map<String, String> data = const {},
  String? workingDirectory,
}) async {
  await requireCommand('copier');
  final dir = workingDirectory ?? getPackageDir().path;

  logStep('Running copier update --vcs-ref=$version ...');
  for (final answer in data.entries) {
    logInfo('  answering ${answer.key}=${answer.value}');
  }
  final process = await Process.start(
    'copier',
    copierUpdateArguments(version: version, data: data),
    workingDirectory: dir,
    mode: ProcessStartMode.inheritStdio,
  );

  return process.exitCode;
}

/// Applies the one generation task that has to run on an update as well.
///
/// `copier.yml`'s last `_task` is `dart format .`, and it is load-bearing
/// rather than tidiness. The template hard-wraps the Dart it emits, but whether
/// a rendered line fits in 80 columns depends on the *answers*:
/// `check_updates.dart` wraps one `RegExp` per upstream crate, and for a short
/// crate name the wrapped form is exactly what `dart format` collapses. The
/// same template source is therefore correctly formatted for one project and
/// not for another, and no better choice of wrap fixes it — three variants were
/// measured and each merely moved the range of crate-name lengths that comes
/// out wrong. Formatting the rendered tree is the only thing that settles it,
/// which is why the task exists.
///
/// `copier copy` runs it. `copier update` runs no tasks at all — deliberately,
/// and that must not change: see [runCopierUpdate]. So an update that
/// re-renders such a file lands it unformatted. What kept this invisible is
/// that `make format-check` used to *write*: the pull request's own gate
/// repaired the file, recorded `format=false` for it, and
/// `create-pull-request`'s `git add -A` then committed the repair — a reported
/// failure that cannot be reproduced from the branch it is reported on. The
/// gate no longer writes, so this has to.
///
/// Run here, after copier has returned, and not by dropping `--skip-tasks`:
/// copier runs tasks *between* rendering and replaying the project's diff, and
/// a task that dies in that window takes local changes with it — the
/// measurement [runCopierUpdate] records. By this point there is no such
/// window.
///
/// Never fatal. A file copier left conflicted cannot be parsed, so the
/// formatter reports it at length and exits non-zero while leaving it untouched
/// (measured) — expected here, and already reported by [findConflicts], so it
/// is summarised rather than repeated. A failure with nothing conflicted is a
/// different animal and its output is passed through verbatim, because this is
/// the only place it appears.
Future<void> formatAfterUpdate({
  Iterable<String> conflicts = const [],
  String? workingDirectory,
}) async {
  final dir = workingDirectory ?? getPackageDir().path;

  logStep('Formatting (the generation task copier skips on an update)...');

  // The SDK already running this script, so the result matches what the
  // project's own `make format` produces and no PATH lookup can disagree —
  // under FVM this is the pinned SDK, which is the whole point of pinning it.
  final result = await Process.run(Platform.resolvedExecutable, [
    'format',
    '.',
  ], workingDirectory: dir);

  for (final line in (result.stdout as String).split('\n')) {
    if (line.startsWith('Formatted ')) logInfo(line.trim());
  }

  if (result.exitCode == 0) return;

  if (conflicts.isNotEmpty) {
    logWarn(
      'Some files could not be parsed and were left unformatted — expected '
      'while ${conflicts.length} file(s) still carry conflict markers.',
    );
    return;
  }

  logWarn('dart format reported errors:');
  logWarn((result.stderr as String).trim());
}

/// Lines shorter than this, once trimmed, are never counted. Braces, `});`,
/// `- name:` and the like repeat all over every file, and say nothing about
/// where a block came from.
const _duplicateMinLength = 25;

/// A file in which the update put the same text in twice.
class DuplicatedText {
  const DuplicatedText({
    required this.path,
    required this.lines,
    required this.firstAt,
  });

  /// Repository-relative path.
  final String path;

  /// The repeated lines, without trailing whitespace, in the order the file
  /// first shows them.
  final List<String> lines;

  /// The 1-based line numbers at which the first of [lines] stands, so a
  /// reviewer can go straight to every copy.
  final List<int> firstAt;

  /// One line for a person to act on. The repeated text itself is left out:
  /// it is arbitrary, it goes into a pull-request body, and the line numbers
  /// are all anyone needs to find it.
  String describe() =>
      '`$path` — ${lines.length} line(s) repeated, the first at lines '
      '${firstAt.join(', ')}';

  Map<String, dynamic> toJson() => {
    'path': path,
    'lines': lines.length,
    'first_at': firstAt,
  };
}

/// [content] with every conflict block resolved both ways: once keeping the
/// side copier marks "before updating", once keeping "after updating". Pure;
/// exposed for testing.
///
/// For a file without conflicts both are the file itself. Copier writes the
/// two-way shape, `<<<<<<< before updating` / `=======` /
/// `>>>>>>> after updating` with no base section, and that is all this reads.
({List<String> before, List<String> after}) resolveConflictsBothWays(
  String content,
) {
  final before = <String>[];
  final after = <String>[];
  // 0 outside a block, 1 in its "before updating" side, 2 in the other.
  var side = 0;
  for (final line in content.split('\n')) {
    if (side == 0 && line.startsWith(_conflictMarker)) {
      side = 1;
    } else if (side == 1 && line == '=======') {
      side = 2;
    } else if (side == 2 && line.startsWith('>>>>>>> ')) {
      side = 0;
    } else {
      if (side != 2) before.add(line);
      if (side != 1) after.add(line);
    }
  }
  return (before: before, after: after);
}

/// Lines the update left in [updated] more often than both [before] (the file
/// at `HEAD`) and [rendered] (the same file in a fresh render of the new
/// template version) have them. Pure; exposed for testing.
///
/// This is the one way a 3-way merge goes wrong without a conflict. When both
/// sides added the same lines, but in different places, git sees two unrelated
/// additions and keeps both. It happens when the template takes code from a
/// project and files it elsewhere: measured on a real update, which put three
/// test groups into `release_test.dart` a second time. Every gate stayed green
/// — the tests just ran twice.
///
/// Hence the rule. A line counts only when both sides have it and the merge
/// has more copies than either. A line only one side has was added by that
/// side, and is a change rather than a duplicate. A line the template itself
/// repeats is repeated in the render too. Replayed over twelve adoptions that
/// people had resolved and three raw updates, it flagged the groups above and
/// one older merge that had put text in twice in two files, which people then
/// kept — and nothing else. A rule without the render, a block of five lines
/// that occurs more often after the update than at `HEAD`, raised fourteen
/// false alarms on the same adoptions, mostly workflows and tests in which the
/// template repeats a block on purpose.
///
/// In a conflicted file a line counts only when it is repeated whichever way
/// its conflicts are resolved. A line repeated one way only is a choice the
/// person resolving it will make, not something the merge has done.
List<String> findDuplicatedLines({
  required String before,
  required String updated,
  required String rendered,
}) {
  final atHead = _lineCounts(before.split('\n'));
  final inRender = _lineCounts(rendered.split('\n'));

  Set<String> repeated(List<String> lines) => {
    for (final MapEntry(key: line, value: count) in _lineCounts(lines).entries)
      if (count >= 2 &&
          (atHead[line] ?? 0) >= 1 &&
          (inRender[line] ?? 0) >= 1 &&
          count > atHead[line]! &&
          count > inRender[line]!)
        line,
  };

  final resolved = resolveConflictsBothWays(updated);
  final found = repeated(
    resolved.before,
  ).intersection(repeated(resolved.after));

  final ordered = <String>[];
  for (final line in updated.split('\n')) {
    final key = line.trimRight();
    if (found.remove(key)) ordered.add(key);
  }
  return ordered;
}

/// How often each line long enough to count occurs, keyed without trailing
/// whitespace. Indentation is kept: the same statement one level deeper is a
/// different line, and the duplicates this looks for keep theirs.
Map<String, int> _lineCounts(Iterable<String> lines) {
  final counts = <String, int>{};
  for (final line in lines) {
    if (line.trim().length < _duplicateMinLength) continue;
    final key = line.trimRight();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

/// [bytes] as text, or null for anything that is not UTF-8 text.
String? _asText(List<int> bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// Paths the update modified, unmerged ones included, sorted.
///
/// Files the update added are not among them, and need not be: a file that did
/// not exist here was copied from the template whole, with nothing to merge.
Future<List<String>> modifiedPaths({String? workingDirectory}) async {
  final dir = workingDirectory ?? getPackageDir().path;
  // `-z`, because git quotes a path with unusual characters otherwise. `M`
  // covers the files a conflict left unmerged as well: compared with `HEAD`,
  // git reports them as modified and never as `U` (measured).
  final diff = await Process.run('git', [
    'diff',
    '--name-only',
    '-z',
    '--diff-filter=M',
    'HEAD',
  ], workingDirectory: dir);
  if (diff.exitCode != 0) {
    throw Exception('git diff failed: ${(diff.stderr as String).trim()}');
  }
  return (diff.stdout as String)
      .split('\x00')
      .where((p) => p.isNotEmpty)
      .toList()
    ..sort();
}

/// Checks each of [paths] for text the update put in twice — see
/// [findDuplicatedLines]. [renderDirectory] holds a fresh render of the
/// version just applied.
Future<List<DuplicatedText>> findDuplicatedText({
  required List<String> paths,
  required String renderDirectory,
  String? workingDirectory,
}) async {
  final dir = workingDirectory ?? getPackageDir().path;
  final found = <DuplicatedText>[];

  for (final path in paths) {
    final rendered = File('$renderDirectory/$path');
    final updated = File('$dir/$path');
    if (!rendered.existsSync() || !updated.existsSync()) continue;

    final head = await Process.run(
      'git',
      ['show', 'HEAD:$path'],
      workingDirectory: dir,
      stdoutEncoding: null,
    );
    if (head.exitCode != 0) continue;

    final beforeText = _asText(head.stdout as List<int>);
    final updatedText = _asText(updated.readAsBytesSync());
    final renderedText = _asText(rendered.readAsBytesSync());
    if (beforeText == null || updatedText == null || renderedText == null) {
      continue;
    }

    final lines = findDuplicatedLines(
      before: beforeText,
      updated: updatedText,
      rendered: renderedText,
    );
    if (lines.isEmpty) continue;

    final fileLines = updatedText.split('\n');
    found.add(
      DuplicatedText(
        path: path,
        lines: lines,
        firstAt: [
          for (var i = 0; i < fileLines.length; i++)
            if (fileLines[i].trimRight() == lines.first) i + 1,
        ],
      ),
    );
  }
  return found;
}

/// The answers file as data for a fresh `copier copy`: every answer, without
/// the `_commit` and `_src_path` that copier keeps there for itself. Pure;
/// exposed for testing.
///
/// Line-based on purpose. Those two keys are written one line each, at the top
/// level, while an answer's continuation lines are indented — so dropping the
/// lines that start with `_` cannot cut a value in half.
String copierDataFromAnswers(String answers) => answers
    .split('\n')
    .where((line) => !line.startsWith('_') && !line.startsWith('#'))
    .join('\n');

/// Renders template [version] with this project's answers into a new
/// temporary directory, formatted as [formatAfterUpdate] formats the project,
/// and returns that directory; the render is its `render/`. The caller
/// deletes it.
///
/// This is what `copier update` itself compares against, and it is the only
/// way to have it: copier renders the new version into a temporary directory
/// of its own and deletes it before returning. Run after the update, because
/// the answers file then records what the update rendered with — new
/// questions answered by their defaults included. That is also why `--data`
/// answers are not passed again: the ones copier recorded are in the file, and
/// handing it the rest would render a value the update itself did not keep.
Future<Directory> renderTemplate({
  required String version,
  String? workingDirectory,
}) async {
  final dir = workingDirectory ?? getPackageDir().path;
  final answers = File('$dir/.copier-answers.yml').readAsStringSync();
  final source = RegExp(
    r'^_src_path:\s*(.+)$',
    multiLine: true,
  ).firstMatch(answers)?.group(1)?.trim();
  if (source == null || source.isEmpty) {
    throw Exception('_src_path not found in .copier-answers.yml');
  }

  final temp = Directory.systemTemp.createTempSync('template_render');
  try {
    final data = File('${temp.path}/answers.yml')
      ..writeAsStringSync(copierDataFromAnswers(answers));
    final render = '${temp.path}/render';
    final copy = await Process.run('copier', [
      'copy',
      '--trust',
      '--defaults',
      '--skip-tasks',
      '--quiet',
      '--vcs-ref=$version',
      '--data-file',
      data.path,
      source,
      render,
    ], workingDirectory: dir);
    if (copy.exitCode != 0) {
      throw Exception(
        'copier copy exited ${copy.exitCode}: '
        '${(copy.stderr as String).trim()}',
      );
    }
    await Process.run(Platform.resolvedExecutable, [
      'format',
      '.',
    ], workingDirectory: render);
    return temp;
  } catch (_) {
    temp.deleteSync(recursive: true);
    rethrow;
  }
}

/// Looks for text the update put in twice, in every file it modified.
///
/// Never fatal, and never silent about not having looked: a render that fails
/// — no network, a copier that cannot reach the template — comes back as the
/// reason, and the pull request says the check did not run rather than that it
/// found nothing.
Future<({List<DuplicatedText> found, String error})> checkDuplicatedText({
  required String version,
  String? workingDirectory,
}) async {
  final dir = workingDirectory ?? getPackageDir().path;
  logStep('Looking for text the merge put in twice...');

  Directory? temp;
  try {
    final paths = await modifiedPaths(workingDirectory: dir);
    if (paths.isEmpty) return (found: const <DuplicatedText>[], error: '');

    temp = await renderTemplate(version: version, workingDirectory: dir);
    final found = await findDuplicatedText(
      paths: paths,
      renderDirectory: '${temp.path}/render',
      workingDirectory: dir,
    );
    if (found.isEmpty) {
      logSuccess('No text was merged in twice.');
    } else {
      logWarn('The merge put text in twice in ${found.length} file(s):');
      for (final d in found) {
        logWarn(
          '  ${d.path} — ${d.lines.length} line(s), the first at lines '
          '${d.firstAt.join(', ')}',
        );
      }
    }
    return (found: found, error: '');
  } catch (e) {
    logWarn('Could not check for text merged in twice: $e');
    return (found: const <DuplicatedText>[], error: '$e');
  } finally {
    try {
      temp?.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temporary directory is not worth failing the update over.
    }
  }
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

/// The field the model must return, and what it is.
///
/// Doubles as the schema every provider enforces natively, so the JSON contract
/// is checked by the provider rather than only asked for in the prompt.
const _templateEntryFields = <String, String>{
  'entry':
      'One top-level Markdown list item for "### For Contributors" → '
      '"#### Changed", with its indented continuation lines.',
};

/// Asks the configured AI model to write the CHANGELOG entry for this adoption.
///
/// The prompt is given the template's own changelog *and* the diff the update
/// produced here. The second is what keeps the entry honest: a template
/// release describes everything it changed for every project generated from
/// it, while the diff shows the subset that actually landed in this one — the
/// rest arrives as a no-op and must not be announced as a change.
///
/// Returns the entry and the model that wrote it.
Future<({String entry, AiModel model})> generateTemplateChangelogEntry({
  required String fromVersion,
  required String toVersion,
  required String templateRepo,
  required String templateChangelog,
  required String updateDiff,
  required String currentChangelog,
  required List<ResolvedAiModel> models,
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

  final response = await callAi(
    models: models,
    prompt: prompt,
    jsonFields: _templateEntryFields,
  );

  final entry = decodeAiJsonObject(response.text)?['entry'];
  if (entry is String && entry.trim().isNotEmpty) {
    return (entry: entry.trimRight(), model: response.model);
  }

  // A fixed, honest entry beats a malformed one: the adoption is real even
  // when the model's output is not usable, and the pull request says the entry
  // needs writing. Nothing is salvaged from the raw answer — a truncated or
  // field-less response reaching CHANGELOG.md verbatim is the failure this
  // guards against.
  return (
    entry:
        '- **copier template adopted: $fromVersion → $toVersion** — see the '
        'template changelog for this range ([compare]($compareUrl)). This '
        'entry was not generated automatically and needs writing.',
    model: response.model,
  );
}

/// Applies the update end to end and returns what happened.
///
/// Ordering is load-bearing in two places. The current version is read *before*
/// copier runs, because copier rewrites the answers file that holds it. The
/// diff is collected before the CHANGELOG is edited, so the prompt describes
/// the update rather than this function's own edit.
Future<TemplateUpdateResult> applyTemplateUpdate({
  required String toVersion,
  List<ResolvedAiModel> models = const [],
  bool skipChangelog = false,
  Map<String, String> data = const {},
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
    data: data,
    workingDirectory: packageDir,
  );
  if (exitCode != 0) {
    throw Exception('copier update failed with exit code $exitCode');
  }

  // Read before anything else here touches the answers file. An answer it does
  // not record is one the next update renders without.
  final unrecorded = unrecordedData(
    answers: File('$packageDir/.copier-answers.yml').readAsStringSync(),
    data: data,
  );
  for (final key in unrecorded) {
    logWarn(
      '.copier-answers.yml does not record --data $key=${data[key]}: no '
      'question by that name was asked in this version.',
    );
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

  // After the conflicts are known, so an unparseable file can be told apart
  // from a real formatter failure, and before the CHANGELOG entry is written
  // off the diff.
  await formatAfterUpdate(conflicts: conflicts, workingDirectory: packageDir);

  // After formatting, so the comparison sees what will be committed, and
  // before the CHANGELOG entry, which is this script's own text rather than
  // the merge's.
  final duplicateCheck = await checkDuplicatedText(
    version: toVersion,
    workingDirectory: packageDir,
  );

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
  var aiProvider = '';

  if (skipChangelog) {
    changelogError = 'skipped by request';
  } else if (models.isEmpty) {
    changelogError = 'no AI model has a key';
    logWarn('No AI model has a key — skipping the CHANGELOG entry.');
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
      final generated = await generateTemplateChangelogEntry(
        fromVersion: fromVersion,
        toVersion: toVersion,
        templateRepo: templateRepo,
        templateChangelog: templateChangelog,
        updateDiff: updateDiff,
        currentChangelog: currentChangelog,
        models: models,
      );
      aiProvider = generated.model.id;

      changelogFile.writeAsStringSync(
        insertContributorChangelogEntry(
          currentChangelog: currentChangelog,
          entry: generated.entry,
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
    duplicates: duplicateCheck.found,
    duplicatesError: duplicateCheck.error,
    changelogUpdated: changelogUpdated,
    changelogError: changelogError,
    aiProvider: aiProvider,
    unrecordedData: unrecorded,
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
    ..writeln('has_duplicates=${result.hasDuplicates}')
    ..writeln('duplicate_count=${result.duplicates.length}')
    ..writeln('duplicates_checked=${result.duplicatesChecked}')
    ..writeln(
      'duplicates_error=${result.duplicatesError.replaceAll('\n', ' ')}',
    )
    ..writeln('changelog_updated=${result.changelogUpdated}')
    ..writeln('changelog_error=${result.changelogError.replaceAll('\n', ' ')}')
    ..writeln('ai_provider=${result.aiProvider}');

  if (result.conflicts.isEmpty) {
    buffer.writeln('conflict_files=');
  } else {
    buffer
      ..writeln('conflict_files<<CONFLICTS_EOF')
      ..writeln(result.conflicts.map((p) => '- `$p`').join('\n'))
      ..writeln('CONFLICTS_EOF');
  }

  if (result.duplicates.isEmpty) {
    buffer.writeln('duplicate_files=');
  } else {
    buffer
      ..writeln('duplicate_files<<DUPLICATES_EOF')
      ..writeln(result.duplicates.map((d) => '- ${d.describe()}').join('\n'))
      ..writeln('DUPLICATES_EOF');
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
  if (result.unrecordedData.isNotEmpty) {
    print(
      '  Not recorded:    '
      '${Colors.colorize(result.unrecordedData.join(', '), Colors.yellow)}',
    );
  }
  print(
    '  Duplicates:      ${!result.duplicatesChecked
        ? Colors.colorize('not checked (${result.duplicatesError})', Colors.yellow)
        : result.duplicates.isEmpty
        ? Colors.colorize('none', Colors.green)
        : Colors.colorize('${result.duplicates.length}', Colors.red)}',
  );
  for (final d in result.duplicates) {
    print(
      '                     ${d.path} — ${d.lines.length} line(s), the first '
      'at lines ${d.firstAt.join(', ')}',
    );
  }
  print(
    '  CHANGELOG:       ${result.changelogUpdated ? Colors.colorize('updated', Colors.green) : 'not updated (${result.changelogError})'}',
  );
  if (result.aiProvider.isNotEmpty) {
    print('  Written by:      ${result.aiProvider}');
  }
  print('');
}
