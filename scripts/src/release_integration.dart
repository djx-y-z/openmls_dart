/// What `make release` reads before it tags: whether the integration tests
/// passed on the released binaries the new version will download.
///
/// When the native build of a `openmls_frb-*` tag succeeds, `integration.yml`
/// starts by itself and runs the package in a real app on every platform,
/// against those binaries. `publish.yml` runs the same tests again before its
/// upload, but only once the tag is pushed, and a failure there leaves a tag
/// with no version on pub.dev. So the release refuses to tag until a run has
/// passed.
///
/// That run cannot be found by its commit. GitHub records the default branch's
/// head as the commit of a run started by `workflow_run`, not the commit the
/// build ran on. Measured in a project generated from this template: the build
/// of a patch release, cut from a maintenance branch, ran on that branch's
/// commit, and the `test.yml` run it started carries the commit main's head was
/// at the time. So `integration.yml` names the run after the tag
/// ([releasedRunTitle]), and it is found by that title.
///
/// A run started by hand on the released binaries counts too, when it ran on
/// the commit being released. Its commit is recorded truly, because it ran on
/// that commit. It is the way through when the crate was built before
/// `integration.yml` existed, or when its run is gone.
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// The title `integration.yml` gives the run that follows the native build of
/// [tag].
String releasedRunTitle(String tag) => 'Released binaries of $tag';

/// The title `integration.yml` gives a run started by hand: `{0}` is where the
/// library comes from (`tree`, `release` or `pub`), `{1}` the ref it ran on.
const byHandTitleFormat = 'By hand: {0}, on {1}';

/// How the title of a run started by hand on the released binaries begins.
final byHandReleaseTitle = byHandTitleFormat
    .replaceFirst('{0}', 'release')
    .replaceFirst('{1}', '');

/// What [judgeIntegration] concluded.
enum IntegrationVerdict { passed, failed, running, none }

/// A verdict and the run it rests on.
class IntegrationCheck {
  const IntegrationCheck(this.verdict, this.detail, {this.run});

  final IntegrationVerdict verdict;

  /// What the verdict rests on, in a few words, for the message.
  final String detail;

  /// The run it rests on. For [IntegrationVerdict.none], the newest one that
  /// tested nothing, if there is one.
  final IntegrationRun? run;
}

/// One run, as `gh run list --json` gives it.
class IntegrationRun {
  IntegrationRun({
    required this.id,
    required this.title,
    required this.event,
    required this.sha,
    required this.status,
    required this.conclusion,
    required this.created,
    required this.url,
  });

  /// Throws a [FormatException] on anything else than such a run, so that the
  /// caller can fail closed.
  factory IntegrationRun.fromJson(Object? json) {
    if (json is! Map) throw FormatException('Not a run: $json');
    T field<T>(String name) {
      final value = json[name];
      if (value is T) return value;
      throw FormatException('A run without a usable "$name": $json');
    }

    final created = DateTime.tryParse(field<String>('createdAt'));
    if (created == null) throw FormatException('A run without a date: $json');
    final conclusion = field<String>('conclusion');
    return IntegrationRun(
      id: field<int>('databaseId'),
      title: field<String>('displayTitle'),
      event: field<String>('event'),
      sha: field<String>('headSha'),
      status: field<String>('status'),
      // `gh` gives an empty string while the run has none yet.
      conclusion: conclusion.isEmpty ? null : conclusion,
      created: created,
      url: field<String>('url'),
    );
  }

  final int id;
  final String title;
  final String event;
  final String sha;
  final String status;
  final String? conclusion;
  final DateTime created;
  final String url;
}

/// The runs that tested the binaries of [tag] for the commit [head], newest
/// first: the one that follows the native build of [tag], and any started by
/// hand on the released binaries at [head].
List<IntegrationRun> integrationCandidates({
  required String tag,
  required String head,
  required Iterable<IntegrationRun> runs,
}) {
  final title = releasedRunTitle(tag);
  final ids = <int>{};
  return [
    for (final run in runs)
      if (((run.event == 'workflow_run' && run.title == title) ||
              (run.event == 'workflow_dispatch' &&
                  run.title.startsWith(byHandReleaseTitle) &&
                  run.sha == head)) &&
          ids.add(run.id))
        run,
  ]..sort((a, b) => b.created.compareTo(a.created));
}

/// Whether a finished run ran the tests at all: a test job of the reusable
/// workflow, [testJobPrefix], that was not skipped. A run whose `resolve` found
/// no tests in its tree runs none, and ends green all the same. Its other jobs
/// test nothing: `Choose Flutter` picks a version, `Package (…)` only builds.
bool ranTheTests(Iterable<Map<String, Object?>> jobs) => jobs.any((job) {
  final name = job['name'];
  return name is String &&
      name.startsWith(testJobPrefix) &&
      job['conclusion'] != 'skipped';
});

/// How `gh` names a test job of the run: the job in `integration.yml` that
/// calls the reusable workflow, then the test job's own name there.
const testJobPrefix = 'integration / Integration (';

/// Judges [runs] for the binaries of [tag] at the commit [head]. The newest
/// run that tested anything decides, and so does one still running: it is
/// newer than whatever finished, so the release waits for it. [jobsOf] gives
/// the jobs of a finished run, from its latest attempt.
Future<IntegrationCheck> judgeIntegration({
  required String tag,
  required String head,
  required Iterable<IntegrationRun> runs,
  required Future<List<Map<String, Object?>>> Function(IntegrationRun run)
  jobsOf,
}) async {
  IntegrationRun? untested;
  for (final run in integrationCandidates(tag: tag, head: head, runs: runs)) {
    if (run.status != 'completed') {
      return IntegrationCheck(
        IntegrationVerdict.running,
        run.status.replaceAll('_', ' '),
        run: run,
      );
    }
    final jobs = run.conclusion == 'skipped'
        ? const <Map<String, Object?>>[]
        : await jobsOf(run);
    if (!ranTheTests(jobs)) {
      untested ??= run;
      continue;
    }
    if (run.conclusion == 'success') {
      return IntegrationCheck(IntegrationVerdict.passed, 'passed', run: run);
    }
    final failed = [
      for (final job in jobs)
        if (job['conclusion'] case final String c
            when c != 'success' && c != 'skipped')
          '${job['name']} ($c)',
    ];
    return IntegrationCheck(
      IntegrationVerdict.failed,
      failed.isEmpty ? '${run.conclusion}' : failed.join(', '),
      run: run,
    );
  }
  return IntegrationCheck(
    IntegrationVerdict.none,
    untested == null
        ? 'there is none'
        : 'the newest, ${untested.url}, ran no tests (${untested.conclusion})',
    run: untested,
  );
}

/// The commit a run started by hand can have tested for this release, as git
/// names it: the one the release is cut from.
///
/// A resumed release has its own commit on top already, the version bump and
/// the CHANGELOG, made here and never pushed. No run can have been dispatched
/// on that one, so the commit to look for is the one under it.
String releaseBaseRev({required bool resuming}) => resuming ? 'HEAD~1' : 'HEAD';

/// Refuses, by throwing, a release whose binaries [tag] have no passing
/// integration run for the commit [head]. Fails closed when GitHub cannot be
/// read.
Future<void> verifyIntegrationPassed({
  required String tag,
  required String head,
}) async {
  if (!await commandExists('gh')) {
    throw Exception(
      'The `gh` CLI is not installed, so the integration tests of $tag cannot '
      'be read. Install it, or pass --skip-integration-check if you have seen '
      'them pass on GitHub.',
    );
  }
  final runs = [
    ...await _runs(['--event', 'workflow_run', '--limit', '200']),
    ...await _runs([
      '--event',
      'workflow_dispatch',
      '--commit',
      head,
      '--limit',
      '50',
    ]),
  ];
  final check = await judgeIntegration(
    tag: tag,
    head: head,
    runs: runs,
    jobsOf: _jobs,
  );
  final run = check.run;
  switch (check.verdict) {
    case IntegrationVerdict.passed:
      logInfo(
        'The integration tests passed on the binaries of $tag: ${run!.url}',
      );
    case IntegrationVerdict.running:
      throw Exception(
        'The integration tests of the binaries of $tag are still running '
        '(${check.detail}): ${run!.url}\n'
        'Run make release again once they have passed.',
      );
    case IntegrationVerdict.failed:
      throw Exception(
        'The integration tests of the binaries of $tag failed: '
        '${check.detail}.\n'
        '  ${run!.url}\n'
        'publish.yml runs the same tests before its upload, once the tag is '
        'pushed, so a release now would leave a tag with no version on pub.dev. '
        'If the runner failed rather than a test (a job that never started, a '
        'device that never came up), run the failed jobs again:\n'
        '  gh run rerun ${run.id} --failed\n'
        'and run make release again once it has passed. A test that failed '
        'needs a fix first.',
      );
    case IntegrationVerdict.none:
      throw Exception(
        'No integration run has passed on the binaries of $tag for this commit '
        '(${check.detail}). One starts by itself when the native build of $tag '
        'succeeds; a crate built before integration.yml existed has none. Start '
        'one on the released binaries, at the commit being released, '
        '${head.substring(0, 7)}, which main on origin has to be at:\n'
        '  gh workflow run integration.yml --ref main -f library=release\n'
        'and run make release again once it has passed.',
      );
  }
}

/// The runs of `integration.yml` that `gh run list` gives with [filter].
Future<List<IntegrationRun>> _runs(List<String> filter) async {
  final decoded = await _gh([
    'run',
    'list',
    '--workflow',
    'integration.yml',
    ...filter,
    '--json',
    'databaseId,displayTitle,event,headSha,status,conclusion,createdAt,url',
  ]);
  if (decoded is! List) throw _unreadable('gh run list gave $decoded');
  try {
    return [for (final run in decoded) IntegrationRun.fromJson(run)];
  } on FormatException catch (e) {
    throw _unreadable(e.message);
  }
}

/// The jobs of the latest attempt of [run].
Future<List<Map<String, Object?>>> _jobs(IntegrationRun run) async {
  final decoded = await _gh(['run', 'view', '${run.id}', '--json', 'jobs']);
  try {
    return parseRunJobs(decoded);
  } on FormatException catch (e) {
    throw _unreadable('gh run view ${run.id}: ${e.message}');
  }
}

/// The jobs in what `gh run view --json jobs` prints. Throws a
/// [FormatException] on anything else, a job without a name included: read as
/// one that ran nothing, it would turn a run that failed into one that tested
/// nothing.
List<Map<String, Object?>> parseRunJobs(Object? decoded) {
  final jobs = decoded is Map ? decoded['jobs'] : null;
  if (jobs is! List) throw FormatException('No list of jobs in $decoded');
  return [
    for (final job in jobs)
      if (job is Map && job['name'] is String)
        {for (final e in job.entries) '${e.key}': e.value}
      else
        throw FormatException('A job without a name: $job'),
  ];
}

Future<Object?> _gh(List<String> args) async {
  final result = await Process.run('gh', args);
  if (result.exitCode != 0) {
    final error = (result.stderr as String).trim();
    throw _unreadable(
      error.isEmpty ? 'gh ${args.first} exited ${result.exitCode}' : error,
    );
  }
  try {
    return jsonDecode(result.stdout as String);
  } on FormatException catch (e) {
    throw _unreadable('gh ${args.first} gave no JSON: ${e.message}');
  }
}

Exception _unreadable(String why) => Exception(
  'Could not read the integration runs on GitHub ($why). Re-run when it is '
  'reachable, or pass --skip-integration-check if you have seen them pass '
  'there.',
);
