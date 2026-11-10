import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/release_integration.dart';

const _tag = 'mypackage_frb-9.1.0';

/// On a line of its own, so that no other line's length depends on it.
const _crate = 'openmls_frb';
const _head = 'a2d2b0735c73c3c414633338cd8a9a99e1013acb';
const _other = 'b9a98e16d89caa7e8e37bc2cf2e562bf41fa15f3';

/// A run as `gh run list --json databaseId,displayTitle,event,headSha,status,
/// conclusion,createdAt,url` prints it.
Map<String, Object?> _json({
  required int id,
  required String title,
  required String created,
  String event = 'workflow_run',
  String sha = _other,
  String status = 'completed',
  String conclusion = 'success',
}) => {
  'conclusion': conclusion,
  'createdAt': created,
  'databaseId': id,
  'displayTitle': title,
  'event': event,
  'headSha': sha,
  'status': status,
  'url': 'https://github.com/owner/mypackage_dart/actions/runs/$id',
};

IntegrationRun _run({
  required int id,
  required String created,
  String? title,
  String event = 'workflow_run',
  String sha = _other,
  String status = 'completed',
  String conclusion = 'success',
}) => IntegrationRun.fromJson(
  _json(
    id: id,
    title: title ?? releasedRunTitle(_tag),
    created: created,
    event: event,
    sha: sha,
    status: status,
    conclusion: conclusion,
  ),
);

/// A run started by hand on the released binaries, at [sha].
IntegrationRun _byHand({
  required int id,
  required String created,
  String sha = _head,
  String library = 'release',
  String status = 'completed',
  String conclusion = 'success',
}) => _run(
  id: id,
  created: created,
  title: byHandTitleFormat
      .replaceFirst('{0}', library)
      .replaceFirst('{1}', 'main'),
  event: 'workflow_dispatch',
  sha: sha,
  status: status,
  conclusion: conclusion,
);

Map<String, Object?> _job(String name, String conclusion) => {
  'name': name,
  'status': 'completed',
  'conclusion': conclusion,
};

/// The jobs of a run on the released binaries, as `gh run view --json jobs`
/// names them: the reusable workflow's under `integration / `.
List<Map<String, Object?>> _jobsOfRelease({String android = 'success'}) => [
  _job('resolve', 'success'),
  _job('integration / Choose Flutter', 'success'),
  _job('integration / Integration (Linux x86_64)', 'success'),
  _job('integration / Integration (iOS simulator)', 'success'),
  _job('integration / Integration (Android API 36, 16 KB pages)', android),
  _job('integration / Package (Android)', 'success'),
];

/// A run whose `resolve` found no tests in its tree: the reusable workflow is
/// one skipped job named after the job that calls it.
final _jobsOfNothing = [
  _job('resolve', 'success'),
  _job('integration', 'skipped'),
];

Future<IntegrationCheck> _judge(
  List<IntegrationRun> runs, {
  Map<int, List<Map<String, Object?>>> jobs = const {},
}) => judgeIntegration(
  tag: _tag,
  head: _head,
  runs: runs,
  jobsOf: (run) async => jobs[run.id] ?? _jobsOfRelease(),
);

/// A workflow's text with LF line ends. On Windows git checks the workflows out
/// with CRLF, and a pattern across lines would match nothing there.
String _readLf(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('judgeIntegration', () {
    test('the run after the native build passed', () async {
      final check = await _judge([
        _run(id: 1, created: '2026-11-04T10:00:00Z'),
      ]);
      expect(check.verdict, IntegrationVerdict.passed);
      expect(check.run!.id, 1);
    });

    test('it failed: names the jobs that did', () async {
      final check = await _judge(
        [_run(id: 1, created: '2026-11-04T10:00:00Z', conclusion: 'failure')],
        jobs: {1: _jobsOfRelease(android: 'failure')},
      );
      expect(check.verdict, IntegrationVerdict.failed);
      expect(
        check.detail,
        'integration / Integration (Android API 36, 16 KB pages) (failure)',
      );
    });

    test('a run GitHub cancelled is no pass', () async {
      final check = await _judge(
        [_run(id: 1, created: '2026-11-04T10:00:00Z', conclusion: 'cancelled')],
        jobs: {
          1: [
            ..._jobsOfRelease(),
            _job('integration / Integration (macOS ARM64)', 'cancelled'),
          ],
        },
      );
      expect(check.verdict, IntegrationVerdict.failed);
      expect(check.detail, contains('macOS ARM64) (cancelled)'));
    });

    test('still running: the release waits', () async {
      final check = await _judge([
        _run(id: 1, created: '2026-11-04T10:00:00Z', status: 'in_progress'),
      ]);
      expect(check.verdict, IntegrationVerdict.running);
      expect(check.detail, 'in progress');
    });

    test('no run at all', () async {
      final check = await _judge([]);
      expect(check.verdict, IntegrationVerdict.none);
      expect(check.run, isNull);
    });

    test('the run of another crate does not count', () async {
      final check = await _judge([
        _run(
          id: 1,
          created: '2026-11-04T10:00:00Z',
          title: releasedRunTitle('mypackage_frb-9.0.0'),
        ),
      ]);
      expect(check.verdict, IntegrationVerdict.none);
    });

    test('a green run that ran no tests is no pass', () async {
      final check = await _judge(
        [_run(id: 1, created: '2026-11-04T10:00:00Z')],
        jobs: {1: _jobsOfNothing},
      );
      expect(check.verdict, IntegrationVerdict.none);
      expect(check.run!.id, 1);
      expect(check.detail, contains('ran no tests'));

      // The reusable workflow called, and every job in it skipped.
      final allSkipped = await _judge(
        [_run(id: 2, created: '2026-11-04T10:00:00Z')],
        jobs: {
          2: [
            _job('resolve', 'success'),
            _job('integration / Choose Flutter', 'skipped'),
            _job('integration / Integration (Linux x86_64)', 'skipped'),
          ],
        },
      );
      expect(allSkipped.verdict, IntegrationVerdict.none);

      // Only the jobs around the tests ran: choosing Flutter tests nothing,
      // and neither does packaging.
      final onlyAroundThem = await _judge(
        [_run(id: 3, created: '2026-11-04T10:00:00Z')],
        jobs: {
          3: [
            _job('resolve', 'success'),
            _job('integration / Choose Flutter', 'success'),
            _job('integration / Integration (Linux x86_64)', 'skipped'),
            _job('integration / Integration (Android API 24)', 'skipped'),
            _job('integration / Package (Android, all ABIs)', 'success'),
          ],
        },
      );
      expect(onlyAroundThem.verdict, IntegrationVerdict.none);
    });

    test('a run with the title that the native build did not start never '
        'counts', () async {
      // A push takes its commit's message as its title, and anyone's pull
      // request can end up as one.
      final check = await _judge([
        _run(id: 1, created: '2026-11-04T10:00:00Z', event: 'push', sha: _head),
      ]);
      expect(check.verdict, IntegrationVerdict.none);
    });

    test('a skipped run is passed over for an older one that ran', () async {
      final check = await _judge([
        _run(id: 1, created: '2026-11-04T10:00:00Z'),
        _run(id: 2, created: '2026-11-04T12:00:00Z', conclusion: 'skipped'),
      ]);
      expect(check.verdict, IntegrationVerdict.passed);
      expect(check.run!.id, 1);
    });

    test('the newest run that ran decides, either way', () async {
      final redThenGreen = await _judge(
        [
          _run(id: 1, created: '2026-11-04T10:00:00Z', conclusion: 'failure'),
          _run(id: 2, created: '2026-11-04T12:00:00Z'),
        ],
        jobs: {1: _jobsOfRelease(android: 'failure')},
      );
      expect(redThenGreen.verdict, IntegrationVerdict.passed);
      expect(redThenGreen.run!.id, 2);

      final greenThenRed = await _judge(
        [
          _run(id: 1, created: '2026-11-04T10:00:00Z'),
          _run(id: 2, created: '2026-11-04T12:00:00Z', conclusion: 'failure'),
        ],
        jobs: {2: _jobsOfRelease(android: 'failure')},
      );
      expect(greenThenRed.verdict, IntegrationVerdict.failed);
      expect(greenThenRed.run!.id, 2);
    });

    test('a run started by hand on the released binaries at HEAD', () async {
      final check = await _judge([
        _byHand(id: 3, created: '2026-11-04T10:00:00Z'),
      ]);
      expect(check.verdict, IntegrationVerdict.passed);
      expect(check.run!.id, 3);
    });

    test('...but not at another commit, nor built from the tree', () async {
      final elsewhere = await _judge([
        _byHand(id: 3, created: '2026-11-04T10:00:00Z', sha: _other),
      ]);
      expect(elsewhere.verdict, IntegrationVerdict.none);

      final fromTree = await _judge([
        _byHand(id: 4, created: '2026-11-04T10:00:00Z', library: 'tree'),
      ]);
      expect(fromTree.verdict, IntegrationVerdict.none);
    });

    test('a green run by hand after a red one after the build', () async {
      final check = await _judge(
        [
          _run(id: 1, created: '2026-11-04T10:00:00Z', conclusion: 'failure'),
          _byHand(id: 2, created: '2026-11-04T12:00:00Z'),
        ],
        jobs: {1: _jobsOfRelease(android: 'failure')},
      );
      expect(check.verdict, IntegrationVerdict.passed);
      expect(check.run!.id, 2);
    });

    test('a run listed twice is judged once', () {
      final run = _run(id: 1, created: '2026-11-04T10:00:00Z');
      expect(
        integrationCandidates(tag: _tag, head: _head, runs: [run, run]),
        hasLength(1),
      );
    });

    test('a pull request run never counts', () async {
      final check = await _judge([
        _run(
          id: 1,
          created: '2026-11-04T10:00:00Z',
          event: 'pull_request',
          sha: _head,
          title: 'test(example): run every capability',
        ),
      ]);
      expect(check.verdict, IntegrationVerdict.none);
    });
  });

  group('releaseBaseRev', () {
    test('a new release is cut from HEAD', () {
      expect(releaseBaseRev(resuming: false), 'HEAD');
    });

    test('a resumed one from under its own commit, which was never pushed', () {
      expect(releaseBaseRev(resuming: true), 'HEAD~1');
    });

    test('is what make release asks git for', () {
      expect(
        File('scripts/src/release.dart').readAsStringSync(),
        contains(
          "head: await git(['rev-parse', "
          'releaseBaseRev(resuming: resuming)]),',
        ),
      );
    });
  });

  group('IntegrationRun.fromJson', () {
    test('a run still going has no conclusion', () {
      final run = IntegrationRun.fromJson(
        _json(
          id: 1,
          title: 't',
          created: '2026-11-04T10:00:00Z',
          status: 'queued',
          conclusion: '',
        ),
      );
      expect(run.conclusion, isNull);
      expect(run.status, 'queued');
    });

    test('anything else is refused, so that the check fails closed', () {
      expect(() => IntegrationRun.fromJson('run'), throwsFormatException);
      expect(
        () => IntegrationRun.fromJson(
          {..._json(id: 1, title: 't', created: '2026-11-04T10:00:00Z')}
            ..remove('headSha'),
        ),
        throwsFormatException,
      );
      expect(
        () => IntegrationRun.fromJson(
          _json(id: 1, title: 't', created: 'yesterday'),
        ),
        throwsFormatException,
      );
    });
  });

  group('parseRunJobs', () {
    test('reads the jobs as gh run view prints them', () {
      final jobs = parseRunJobs({
        'jobs': [
          {
            'completedAt': '2026-11-03T17:41:02Z',
            'conclusion': 'success',
            'databaseId': 126099000000,
            'name': 'resolve',
            'status': 'completed',
            'steps': <Object?>[],
            'url':
                'https://github.com/owner/mypackage_dart/actions/runs/1/job/2',
          },
          _job('integration / Integration (Web)', 'success'),
        ],
      });
      expect(jobs.map((j) => j['name']), [
        'resolve',
        'integration / Integration (Web)',
      ]);
      expect(ranTheTests(jobs), isTrue);
    });

    test('refuses anything else, a job without a name included', () {
      expect(() => parseRunJobs(<Object?>[]), throwsFormatException);
      expect(() => parseRunJobs({'jobs': 'none'}), throwsFormatException);
      expect(
        () => parseRunJobs({
          'jobs': [
            {'conclusion': 'failure', 'status': 'completed'},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('integration.yml', () {
    // The titles are how the check finds its runs, so the workflow has to give
    // exactly these. Read as text: a renamed title, or a condition that no
    // longer names the build, is what this is here to catch.
    final workflow = _readLf('.github/workflows/integration.yml');

    test('names the run after the native build by the tag', () {
      expect(
        workflow,
        contains(
          "format('${releasedRunTitle('{0}')}', "
          'github.event.workflow_run.head_branch)',
        ),
      );
      expect(
        workflow,
        contains(
          'startsWith(github.event.workflow_run.head_branch, '
          "'$_crate-')",
        ),
      );
    });

    test('names a run by hand by its library and ref', () {
      expect(
        workflow,
        contains(
          "format('$byHandTitleFormat', inputs.library, github.ref_name)",
        ),
      );
      expect(byHandReleaseTitle, 'By hand: release, on ');
    });

    test("names the watchdog's self-test so that it never counts", () {
      // It is meant to fail. Titled as a run by hand on the released binaries,
      // it would hold a release back, or pass for its tests by accident.
      const format = 'Watchdog self-test: {0}, on {1}';
      expect(
        workflow,
        contains(
          "github.event_name == 'workflow_dispatch' && inputs.hang\n"
          "      && format('$format', inputs.library, github.ref_name)",
        ),
      );
      // Ahead of the title of a run by hand, which would otherwise be its.
      expect(
        workflow.indexOf(format),
        lessThan(workflow.indexOf(byHandTitleFormat)),
      );
      final selfTest = _run(
        id: 1,
        created: '2026-11-04T10:00:00Z',
        title: format
            .replaceFirst('{0}', 'release')
            .replaceFirst('{1}', 'main'),
        event: 'workflow_dispatch',
        sha: _head,
      );
      expect(
        integrationCandidates(tag: _tag, head: _head, runs: [selfTest]),
        isEmpty,
      );
    });

    test('names it so only after a build that succeeded', () {
      final runName = workflow.substring(
        workflow.indexOf('run-name:'),
        workflow.indexOf('\non:'),
      );
      expect(
        runName,
        contains("github.event.workflow_run.conclusion == 'success'"),
      );
    });

    test('tests the tree the native build ran on', () {
      // Not main's head, which GitHub records as the run's commit: the title
      // says whose binaries, and this is the tree they are tested with.
      expect(workflow, contains(r'ref="$RELEASE_SHA"'));
    });

    test('tests a release only where a tag of its name is', () {
      // The build runs by hand on any ref, and checks the crate version only
      // for a tag: a branch named like a crate tag gets the title above, and
      // must leave no test job behind, which the check counts as no run.
      expect(
        workflow,
        contains(
          'if ! tag_at "\$RELEASE_TAG" "\$RELEASE_SHA"; then\n'
          '                # A build run by hand',
        ),
      );
      expect(
        workflow,
        contains(
          r'"$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/commits/refs/tags/$1"',
        ),
      );
      // Only "no such tag" is no tag; anything else stops the run.
      expect(workflow, contains('              404 | 422) return 1 ;;\n'));
      final release = workflow.substring(
        workflow.indexOf('            workflow_run)'),
        workflow.indexOf('            schedule)'),
      );
      expect(
        release.indexOf('tag_at "'),
        lessThan(release.indexOf('has_tests "')),
      );
      expect(release, contains('run=false'));
    });

    test('calls its test jobs what the check counts', () {
      // `gh` names a job of the reusable workflow after the job here that
      // calls it, then its own name there.
      expect(
        workflow,
        matches(
          RegExp(r'^  integration:\n    needs: resolve$', multiLine: true),
        ),
      );
      final reusable = _readLf('.github/workflows/integration-reusable.yml');
      final testJobs = RegExp(
        r'^    name: Integration \(',
        multiLine: true,
      ).allMatches(reusable);
      // Desktop, web, iOS and Android.
      expect(testJobs, hasLength(4));
      expect(testJobPrefix, 'integration / Integration (');
    });
  });
}
