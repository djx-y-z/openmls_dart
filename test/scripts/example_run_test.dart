import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/example_run.dart';

// `flutter test --file-reporter json:` output from real runs of the example on
// macOS with Flutter 3.38.4, cut down to a few tests, the paths shortened.
const _start = '''
{"protocolVersion":"0.1.1","runnerVersion":null,"pid":55455,"type":"start","time":0}
{"suite":{"id":0,"platform":"vm","path":"/repo/example/integration_test/mypackage_test.dart"},"type":"suite","time":0}
{"test":{"id":1,"name":"loading /repo/example/integration_test/mypackage_test.dart","suiteID":0,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":null,"column":null,"url":null},"type":"testStart","time":0}
{"count":1,"time":5,"type":"allSuites"}
''';

const _loaded = '''
{"testID":1,"result":"success","skipped":false,"hidden":true,"type":"testDone","time":21025}
{"test":{"id":4,"name":"MyPackage init is idempotent and survives cleanup","suiteID":0,"groupIDs":[2,3],"metadata":{"skip":false,"skipReason":null},"line":174,"column":5,"url":"package:flutter_test/src/widget_tester.dart","root_line":39,"root_column":3,"root_url":"file:///repo/example/integration_test/mypackage_test.dart"},"type":"testStart","time":21025}
{"testID":4,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":21329}
''';

// Every test passed.
const _passed =
    '''
$_start$_loaded{"test":{"id":6,"name":"keys: agreement matches the published test vectors","suiteID":0,"groupIDs":[2,5],"metadata":{"skip":false,"skipReason":null},"line":174,"column":5,"url":"package:flutter_test/src/widget_tester.dart","root_line":40,"root_column":3,"root_url":"file:///repo/example/integration_test/mypackage_test.dart"},"type":"testStart","time":21329}
{"testID":6,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":21348}
{"test":{"id":77,"name":"(tearDownAll)","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":50,"column":5,"url":"package:integration_test/integration_test.dart"},"type":"testStart","time":23835}
{"testID":77,"result":"success","skipped":false,"hidden":true,"type":"testDone","time":23837}
{"success":true,"type":"done","time":23848}
''';

// A capability failed an `expect`, and the next one exited the app: the first
// has an error of its own, the second and the rest only "did not complete".
const _failedInApp =
    '''
$_start$_loaded{"test":{"id":5,"name":"a capability that fails","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":174,"column":5,"url":"package:flutter_test/src/widget_tester.dart","root_line":43,"root_column":3,"root_url":"file:///repo/example/integration_test/mypackage_test.dart"},"type":"testStart","time":33591}
{"testID":5,"error":"Test failed. See exception logs above.\\nThe test description was: a capability that fails","stackTrace":"","isFailure":false,"type":"error","time":33685}
{"testID":5,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":33686}
{"test":{"id":6,"name":"the app exits","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":174,"column":5,"url":"package:flutter_test/src/widget_tester.dart","root_line":46,"root_column":3,"root_url":"file:///repo/example/integration_test/mypackage_test.dart"},"type":"testStart","time":33686}
{"testID":6,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":33719}
{"test":{"id":79,"name":"(tearDownAll)","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":50,"column":5,"url":"package:integration_test/integration_test.dart"},"type":"testStart","time":33740}
{"testID":79,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":33740}
{"success":false,"type":"done","time":33745}
''';

// A capability exited the app, and nothing failed before it: the tests after
// it are marked done, none with an error.
const _appWentAway =
    '''
$_start$_loaded{"test":{"id":5,"name":"the app exits","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":174,"column":5,"url":"package:flutter_test/src/widget_tester.dart","root_line":43,"root_column":3,"root_url":"file:///repo/example/integration_test/mypackage_test.dart"},"type":"testStart","time":22510}
{"testID":5,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":22540}
{"test":{"id":7,"name":"keys: agreement matches the published test vectors","suiteID":0,"groupIDs":[2,6],"metadata":{"skip":false,"skipReason":null},"line":174,"column":5,"url":"package:flutter_test/src/widget_tester.dart","root_line":46,"root_column":3,"root_url":"file:///repo/example/integration_test/mypackage_test.dart"},"type":"testStart","time":22545}
{"testID":7,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":22545}
{"success":false,"type":"done","time":22575}
''';

// The app never connected. Written from the log of an iOS simulator run in CI
// (GitHub's reporter there, so the shape is the protocol's): the loading test
// failed after its 12 minutes, and no test of the suite started.
const _neverConnected =
    '''
$_start{"testID":1,"error":"TimeoutException after 0:12:00.000000: Test timed out after 12 minutes.","stackTrace":"package:test_api/src/backend/invoker.dart 362:28  Invoker._handleError.<fn>","isFailure":false,"type":"error","time":720010}
{"testID":1,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":720011}
{"success":false,"type":"done","time":720020}
''';

void main() {
  group('judgeTestRun', () {
    test('a run that exited 0 passed', () {
      final outcome = judgeTestRun(exitCode: 0, results: _passed);
      expect(outcome.verdict, Verdict.passed);
    });

    test('a test that failed in the app fails the run, and is named', () {
      final outcome = judgeTestRun(exitCode: 1, results: _failedInApp);
      expect(outcome.verdict, Verdict.failed);
      // Not the test the app died in: it did not fail, it did not complete.
      expect(outcome.failedTests, ['a capability that fails']);
      expect(outcome.describe(), contains('a capability that fails'));
    });

    test('an app that went away before any test failed did not finish', () {
      final outcome = judgeTestRun(exitCode: 1, results: _appWentAway);
      expect(outcome.verdict, Verdict.unfinished);
      expect(outcome.failedTests, isEmpty);
      expect(outcome.reason, contains('after 1 passed tests'));
    });

    test('an app that never connected did not finish, and says why', () {
      final outcome = judgeTestRun(exitCode: 1, results: _neverConnected);
      expect(outcome.verdict, Verdict.unfinished);
      expect(
        outcome.reason,
        'the app never got to the tests: TimeoutException after '
        '0:12:00.000000: Test timed out after 12 minutes.',
      );
    });

    test('a run with no results file did not finish', () {
      final outcome = judgeTestRun(exitCode: 1, results: null);
      expect(outcome.verdict, Verdict.unfinished);
      expect(outcome.reason, startsWith('no test started'));
    });

    test('a half-written last line is skipped, not fatal', () {
      final outcome = judgeTestRun(
        exitCode: 1,
        results: '$_failedInApp{"testID":7,"res',
      );
      expect(outcome.verdict, Verdict.failed);
      expect(outcome.failedTests, ['a capability that fails']);
    });

    test('a crash fails a run in which no test failed', () {
      final outcome = judgeTestRun(
        exitCode: 1,
        results: _appWentAway,
        crashed: true,
      );
      expect(outcome.verdict, Verdict.failed);
      expect(outcome.reason, 'the app crashed');
    });

    test('an error event without its text is still a failed test', () {
      final results = _appWentAway.replaceFirst(
        '{"testID":7,"result":"error"',
        '{"testID":7,"type":"error","time":22544}\n'
            '{"testID":7,"result":"error"',
      );
      final outcome = judgeTestRun(exitCode: 1, results: results);
      expect(outcome.verdict, Verdict.failed);
      expect(outcome.failedTests, [
        'keys: agreement matches the published test vectors',
      ]);
    });

    test('every test passed and the command failed after them: unfinished', () {
      final outcome = judgeTestRun(exitCode: 1, results: _passed);
      expect(outcome.verdict, Verdict.unfinished);
      expect(outcome.reason, contains('every test passed'));
    });

    test('an error outside the tests, after some ran, does not say the app '
        'never got to them', () {
      // Not measured: test_core sends an error that reaches it after the suite
      // has loaded to the loading test (runner/plugin/platform_helpers.dart),
      // wrapped like this when the app threw it outside any test.
      const results =
          '''
$_start$_loaded{"testID":1,"error":"Failed to load \\"/repo/example/integration_test/mypackage_test.dart\\": Bad state: outside any test","stackTrace":"","isFailure":false,"type":"error","time":21400}
{"success":false,"type":"done","time":21500}
''';
      final outcome = judgeTestRun(exitCode: 1, results: results);
      expect(outcome.verdict, Verdict.unfinished);
      expect(
        outcome.reason,
        startsWith('an error outside the tests, after 1 passed tests: '),
      );
    });
  });

  group('failedSoFar', () {
    test('a run cut off after a test failed has failed', () {
      // The next test started and never ended: what a try that CI stopped at
      // its time limit leaves.
      final cut = _failedInApp.substring(
        0,
        _failedInApp.indexOf('{"testID":6,'),
      );
      expect(failedSoFar(cut), ['a capability that fails']);
    });

    test('a run going well, or still loading, has not', () {
      expect(failedSoFar(''), isEmpty);
      expect(failedSoFar(_start), isEmpty);
      expect(failedSoFar('$_start$_loaded'), isEmpty);
      expect(failedSoFar(_appWentAway), isEmpty);
    });

    test('nor has one the app never connected to', () {
      expect(failedSoFar(_neverConnected), isEmpty);
    });
  });

  group('settleRun', () {
    // A run that came to [verdict], judged as judgeTestRun does: a crash fails
    // only a run that did not finish.
    RunOutcome judged(Verdict verdict, {required bool crashed}) =>
        crashed && verdict == Verdict.unfinished
        ? const RunOutcome(Verdict.failed, reason: 'the app crashed')
        : RunOutcome(verdict);

    test('asks about a crash only after a run that did not finish', () async {
      for (final verdict in Verdict.values) {
        var asked = false;
        await settleRun(
          (crashed) => judged(verdict, crashed: crashed),
          crashed: () async => asked = true,
        );
        expect(asked, verdict == Verdict.unfinished, reason: '$verdict');
      }
    });

    test('a crash fails a run that did not finish', () async {
      final outcome = await settleRun(
        (crashed) => judged(Verdict.unfinished, crashed: crashed),
        crashed: () async => true,
      );
      expect(outcome.verdict, Verdict.failed);
    });

    test('checks the library only after a run that passed, and fails it when '
        'it was another', () async {
      for (final verdict in Verdict.values) {
        var asked = false;
        final outcome = await settleRun(
          (crashed) => judged(verdict, crashed: crashed),
          crashed: () async => false,
          verify: () async {
            asked = true;
            return false;
          },
        );
        expect(asked, verdict == Verdict.passed, reason: '$verdict');
        if (verdict == Verdict.passed) {
          expect(outcome.verdict, Verdict.failed);
          expect(outcome.reason, contains('another library'));
        }
      }
      final right = await settleRun(
        (crashed) => judged(Verdict.passed, crashed: crashed),
        crashed: () async => false,
        verify: () async => true,
      );
      expect(right.verdict, Verdict.passed);
    });
  });

  group('runAttempts', () {
    /// Runs [outcomes] in turn, with [attempts] allowed, and returns what
    /// happened, in order. With [crashedEarlier], the look back at the end
    /// finds that crash, or none.
    Future<(RunOutcome, List<String>)> attempt(
      List<Verdict> outcomes, {
      int attempts = 3,
      bool? crashedEarlier,
    }) async {
      final events = <String>[];
      final last = await runAttempts(
        attempts: attempts,
        record: (verdict) => events.add('record ${verdict.name}'),
        beforeRetry: (n) async => events.add('wait $n'),
        run: (n) async {
          events.add('run $n');
          return RunOutcome(outcomes[n - 1]);
        },
        onUnfinished: (n, _) => events.add('unfinished $n'),
        crashedEarlier: crashedEarlier == null
            ? null
            : () async {
                events.add('look back');
                return crashedEarlier;
              },
      );
      return (last, events);
    }

    test('a test that failed is never run again', () async {
      final (last, events) = await attempt([Verdict.failed]);
      expect(last.verdict, Verdict.failed);
      expect(events, ['record unfinished', 'run 1', 'record failed']);
    });

    test(
      'a run that did not finish runs again, and the next decides',
      () async {
        final (last, events) = await attempt([
          Verdict.unfinished,
          Verdict.unfinished,
          Verdict.passed,
        ]);
        expect(last.verdict, Verdict.passed);
        expect(events, [
          'record unfinished',
          'run 1',
          'record unfinished',
          'unfinished 1',
          'record unfinished',
          'wait 2',
          'run 2',
          'record unfinished',
          'unfinished 2',
          'record unfinished',
          'wait 3',
          'run 3',
          'record passed',
        ]);

        final (failedLater, _) = await attempt([
          Verdict.unfinished,
          Verdict.failed,
          Verdict.passed,
        ]);
        expect(failedLater.verdict, Verdict.failed);
      },
    );

    test('no more runs than allowed', () async {
      final (last, events) = await attempt([
        Verdict.unfinished,
        Verdict.unfinished,
      ], attempts: 2);
      expect(last.verdict, Verdict.unfinished);
      expect(events.where((e) => e.startsWith('run ')), ['run 1', 'run 2']);
      expect(events.last, 'unfinished 2');
      await expectLater(attempt([], attempts: 0), throwsArgumentError);
    });

    test('a crash reported late fails the run that passed after it', () async {
      final (last, events) = await attempt([
        Verdict.unfinished,
        Verdict.passed,
      ], crashedEarlier: true);
      expect(last.verdict, Verdict.failed);
      expect(last.reason, crashedEarlierReason);
      expect(events.sublist(events.length - 3), [
        'record passed',
        'look back',
        'record failed',
      ]);
    });

    test('with no crash found, the pass stands', () async {
      final (last, events) = await attempt([
        Verdict.unfinished,
        Verdict.passed,
      ], crashedEarlier: false);
      expect(last.verdict, Verdict.passed);
      expect(events.last, 'look back');
    });

    test('runs that all did not finish, and a crash reported late', () async {
      final (last, _) = await attempt([
        Verdict.unfinished,
        Verdict.unfinished,
        Verdict.unfinished,
      ], crashedEarlier: true);
      expect(last.verdict, Verdict.failed);
      expect(last.reason, crashedEarlierReason);
    });

    test('no look back after one run, nor after a failure', () async {
      for (final outcomes in [
        [Verdict.passed],
        [Verdict.unfinished],
        [Verdict.unfinished, Verdict.failed],
      ]) {
        final (last, events) = await attempt(
          outcomes,
          attempts: outcomes.length,
          crashedEarlier: true,
        );
        expect(last.verdict, outcomes.last, reason: '$outcomes');
        expect(events, isNot(contains('look back')), reason: '$outcomes');
      }
    });
  });

  group('judgeDriveRun', () {
    test('a run that exited 0 passed', () {
      expect(judgeDriveRun(exitCode: 0, output: '').verdict, Verdict.passed);
    });

    test('the app handed over a failure: failed', () {
      final outcome = judgeDriveRun(
        exitCode: 1,
        output: 'Failure Details:\n...\n$reportedLine\r\nThe suite did not...',
      );
      expect(outcome.verdict, Verdict.failed);
    });

    test('the app never handed anything over: unfinished', () {
      final outcome = judgeDriveRun(
        exitCode: 1,
        output: 'Error waiting for a debug connection: The log reader stopped',
      );
      expect(outcome.verdict, Verdict.unfinished);
    });

    test('a crash fails it all the same', () {
      final outcome = judgeDriveRun(exitCode: 1, output: '', crashed: true);
      expect(outcome.verdict, Verdict.failed);
      expect(outcome.reason, 'the app crashed');
    });

    test('the driver prints the very line this looks for', () {
      final driver = File(
        'example/test_driver/integration_test.dart',
      ).readAsStringSync();
      expect(driver, contains("stdout.writeln('$reportedLine');"));
      expect(driver, contains('writeResponseOnFailure: true'));
    });
  });

  group('makeArguments', () {
    test('runs the target on the Flutter already first on PATH, not fvm', () {
      expect(
        makeArguments(
          'test-example',
          app: 'build/consumer',
          args: ['-d', 'emulator-5554', '--file-reporter', 'json:/t/r.json'],
        ),
        [
          'FVM=',
          'test-example',
          'EXAMPLE_DIR=build/consumer',
          'ARGS=-d emulator-5554 --file-reporter json:/t/r.json',
        ],
      );
    });
  });

  group('Android', () {
    test(
      'reads the application id of the example',
      () {
        final gradle = File(_gradle).readAsStringSync();
        final id = androidApplicationId(gradle);
        expect(id, isNotNull);
        expect(gradle, contains('applicationId = "$id"'));
      },
      skip: _untilFlutterCreate(_gradle),
    );

    test('reads a Groovy build file too', () {
      expect(
        androidApplicationId('    applicationId "com.example.app"\n'),
        'com.example.app',
      );
    });

    test('finds a Java crash of the app', () {
      const log =
          '--------- beginning of crash\n'
          'E AndroidRuntime: FATAL EXCEPTION: main\n'
          'E AndroidRuntime: Process: com.mypackage.example, PID: 4321\n';
      expect(crashedOnAndroid(log, 'com.mypackage.example'), isTrue);
    });

    test('finds a native crash of the app', () {
      const log =
          'F DEBUG   : pid: 4321, tid: 4350, name: 1.ui  '
          '>>> com.mypackage.example <<<\n';
      expect(crashedOnAndroid(log, 'com.mypackage.example'), isTrue);
    });

    test('ignores a crash of another app, one with a longer id included', () {
      const log =
          'E AndroidRuntime: Process: com.android.systemui, PID: 99\n'
          'E AndroidRuntime: Process: com.mypackage.example2, PID: 98\n'
          'F DEBUG   : pid: 97, name: x  >>> com.mypackage.example2 <<<\n';
      expect(crashedOnAndroid(log, 'com.mypackage.example'), isFalse);
    });
  });

  group('iOS simulator', () {
    // The first line of the report macOS wrote when the example aborted on an
    // iOS 26.2 simulator.
    const header =
        '{"app_name":"Runner","timestamp":"2026-11-03 17:48:46.00 +0100","app_version":"1.0.0","sroute_id":16,"slice_uuid":"3e711a9d-7318-399a-9745-6b99c85e47bc","build_version":"1","platform":7,"bundleID":"com.mypackage.example","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 26.5 (25F71)","roots_installed":0,"name":"Runner","incident_id":"E8E1F9E4-82EC-4E6A-91BD-4024ACDF7C5B"}';

    test('reads the bundle ids of the example', () {
      final pbxproj = File(_pbxproj).readAsStringSync();
      final ids = iosBundleIds(pbxproj);
      final app = ids.where((id) => !id.endsWith('.RunnerTests')).toSet();
      expect(app, hasLength(1));
      expect(ids, contains('${app.single}.RunnerTests'));
      for (final id in ids) {
        expect(pbxproj, contains('PRODUCT_BUNDLE_IDENTIFIER = $id;'));
      }
    }, skip: _untilFlutterCreate(_pbxproj));

    test('finds a crash of the app in a simulator', () {
      expect(
        crashedOnSimulator('$header\n{\n  "uptime" : 2500000,', {
          'com.mypackage.example',
        }),
        isTrue,
      );
    });

    test('ignores another app, the same app on the Mac, and noise', () {
      const ids = {'com.mypackage.example'};
      expect(
        crashedOnSimulator(
          header.replaceFirst('com.mypackage.example', 'com.apple.Maps'),
          ids,
        ),
        isFalse,
      );
      expect(
        crashedOnSimulator(
          header.replaceFirst('"platform":7', '"platform":1'),
          ids,
        ),
        isFalse,
      );
      expect(crashedOnSimulator('', ids), isFalse);
      expect(crashedOnSimulator('not json\n', ids), isFalse);
    });
  });

  group('testRunPosition', () {
    test('none while the suite loads: the build, the install, the launch', () {
      expect(testRunPosition(''), isNull);
      expect(testRunPosition(_start), isNull);
      expect(testRunPosition(_neverConnected), isNull);
    });

    test('the last test that started, and every event so far', () {
      final position = testRunPosition('$_start$_loaded')!;
      expect(
        position.test,
        'MyPackage init is idempotent and survives cleanup',
      );
      expect(position.step, 7);
    });

    test('the test the run is in, once it has started one more', () {
      final cut = _failedInApp.substring(
        0,
        _failedInApp.indexOf('{"testID":6,'),
      );
      final position = testRunPosition(cut)!;
      expect(position.test, 'the app exits');
      expect(position.step, 11);
    });

    test('half a line is no step: it is the same line when it ends', () {
      final whole = testRunPosition('$_start$_loaded')!.step;
      expect(
        testRunPosition('$_start$_loaded{"testID":4,"result":"succ')!.step,
        whole,
      );
    });

    test('none once the suite is done, however it went', () {
      expect(testRunPosition(_passed), isNull);
      expect(testRunPosition(_failedInApp), isNull);
      expect(testRunPosition(_appWentAway), isNull);
    });
  });

  group('the app under flutter drive', () {
    // What `flutter drive --profile` printed on the API 24 emulator in CI, run
    // 42031248805, cut down: the app's own runner prints a line as each test
    // starts, after Android's log prefix.
    const going =
        "Running Gradle task 'assembleProfile'...                           29.3s\n"
        '✓ Built build/app/outputs/flutter-apk/app-profile.apk (31.5MB)\n'
        'I/flutter ( 2955): 00:00 +0: MyPackage init is idempotent and survives cleanup\n'
        'I/flutter ( 2955): 00:00 +1: keys: agreement matches the published test vectors\n';
    const done =
        'I/flutter ( 2955): 00:04 +59: every capability above ran\n'
        'I/flutter ( 2955): 00:04 +60: (tearDownAll)\n'
        'I/flutter ( 2955): 00:04 +61: All tests passed!\n'
        'All tests passed.\n'
        '$reportedLine\n';
    // A test that fails, as `_Reporter` in flutter_test 3.38.4 prints it
    // (test_compat.dart): written from the code, not measured.
    const failing =
        'I/flutter ( 2955): 00:01 +3: a capability that fails\n'
        'I/flutter ( 2955): 00:01 +3 -1: a capability that fails [E]\n'
        'I/flutter ( 2955):   Test failed. See exception logs above.\n'
        'I/flutter ( 2955): 00:01 +3 -1: the next one\n';

    test('none until a test has started', () {
      expect(driveRunPosition(''), isNull);
      expect(driveRunPosition(going.split('I/flutter').first), isNull);
    });

    test('the last test that started, and its line', () {
      final position = driveRunPosition(going)!;
      expect(
        position.test,
        'keys: agreement matches the published test vectors',
      );
      expect(position.step, 2);
    });

    test('the log of a simulator or a desktop puts flutter: in front', () {
      final position = driveRunPosition(
        'flutter: 00:00 +0: MyPackage init is idempotent and survives cleanup\n',
      )!;
      expect(
        position.test,
        'MyPackage init is idempotent and survives cleanup',
      );
    });

    test('a print of the app moves nothing', () {
      expect(
        driveRunPosition(
          '${going}I/flutter ( 2955): a line of its own\n',
        )!.step,
        2,
      );
    });

    test('none after the last line', () {
      expect(driveRunPosition('$going$done'), isNull);
      expect(
        driveRunPosition('I/flutter ( 1): 00:09 +2 -1: Some tests failed.\n'),
        isNull,
      );
    });

    test('a failure is a step, and names the test without the mark', () {
      final position = driveRunPosition(
        failing.substring(0, failing.indexOf('I/flutter ( 2955):   ')),
      )!;
      expect(position.test, 'a capability that fails');
      expect(position.step, 2);
    });

    test('the tests that failed, each once, as soon as it says so', () {
      expect(driveFailedSoFar(going), isEmpty);
      expect(driveFailedSoFar('$going$done'), isEmpty);
      expect(driveFailedSoFar('$failing$failing'), ['a capability that fails']);
    });

    test('a run that said a test failed has failed, however it ended', () {
      final outcome = judgeDriveRun(exitCode: 1, output: failing);
      expect(outcome.verdict, Verdict.failed);
      expect(outcome.failedTests, ['a capability that fails']);
      expect(
        judgeDriveRun(exitCode: 1, output: going).verdict,
        Verdict.unfinished,
      );
    });
  });

  group('StallWatch', () {
    final start = DateTime.utc(2026, 11, 5, 12);
    DateTime at(int seconds) => start.add(Duration(seconds: seconds));
    const one = RunPosition(5, 'a test');

    test('a run that stands still for the limit has stopped', () {
      final watch = StallWatch(const Duration(seconds: 60));
      expect(watch.check(one, at(0)), isNull);
      expect(watch.check(one, at(59)), isNull);
      expect(watch.check(one, at(60)), 'a test');
      expect(watch.check(one, at(61)), 'a test');
    });

    test('every step starts the count again', () {
      final watch = StallWatch(const Duration(seconds: 60));
      expect(watch.check(one, at(0)), isNull);
      expect(watch.check(const RunPosition(6, 'a test'), at(50)), isNull);
      expect(watch.check(const RunPosition(6, 'a test'), at(100)), isNull);
      expect(watch.check(const RunPosition(6, 'a test'), at(110)), 'a test');
    });

    test('no position, no count: loading, and after the suite', () {
      final watch = StallWatch(const Duration(seconds: 60));
      expect(watch.check(null, at(0)), isNull);
      expect(watch.check(null, at(600)), isNull);
      expect(watch.check(one, at(601)), isNull);
      expect(watch.check(null, at(700)), isNull);
      expect(watch.check(one, at(701)), isNull);
      expect(watch.check(one, at(761)), 'a test');
    });

    test('waits 8 minutes unless told otherwise', () {
      expect(StallWatch().limit, stallLimit);
      expect(stallLimit, const Duration(minutes: 8));
    });
  });

  group('stalledRun', () {
    test('an app still running on a device that answers: failed', () {
      final outcome = stalledRun('a test', AppState.running);
      expect(outcome.verdict, Verdict.failed);
      expect(
        outcome.describe(),
        'Failed: the app sent nothing for 8 minutes, the last test it started '
        'being "a test", and it was still running on a device that answered.',
      );
    });

    test("nothing asked, the app being this machine's: failed", () {
      final outcome = stalledRun(
        'a test',
        AppState.unchecked,
        limit: const Duration(seconds: 90),
      );
      expect(outcome.verdict, Verdict.failed);
      expect(
        outcome.reason,
        'the app sent nothing for 90 seconds, the last test it started being '
        '"a test"',
      );
    });

    test('the app or the device gone: unfinished, and run again', () {
      final gone = stalledRun('a test', AppState.gone);
      expect(gone.verdict, Verdict.unfinished);
      expect(gone.reason, endsWith(', and then it was gone'));
      final silent = stalledRun('a test', AppState.unreachable);
      expect(silent.verdict, Verdict.unfinished);
      expect(silent.reason, endsWith(', and then the device did not answer'));
    });

    test('counts in minutes, and in seconds when it must', () {
      String said(Duration limit) =>
          stalledRun('t', AppState.unchecked, limit: limit).reason!;
      expect(said(const Duration(minutes: 1)), contains(' 1 minute,'));
      expect(said(const Duration(seconds: 1)), contains(' 1 second,'));
      expect(said(const Duration(seconds: 61)), contains(' 61 seconds,'));
    });
  });

  group('withStall', () {
    const stalled = RunOutcome(Verdict.failed, reason: 'stopped');
    const gone = RunOutcome(Verdict.unfinished, reason: 'gone');

    test('a test that failed says more than the stop', () {
      const own = RunOutcome(Verdict.failed, failedTests: ['a test']);
      expect(withStall(own, stalled), same(own));
      expect(withStall(own, gone), same(own));
    });

    test('otherwise the stop decides, whatever the run said', () {
      expect(
        withStall(const RunOutcome(Verdict.unfinished), stalled),
        same(stalled),
      );
      expect(
        withStall(const RunOutcome(Verdict.passed), stalled),
        same(stalled),
      );
      expect(withStall(const RunOutcome(Verdict.unfinished), gone), same(gone));
    });

    test('and a run never stopped is its own', () {
      const own = RunOutcome(Verdict.unfinished);
      expect(withStall(own, null), same(own));
    });

    test('a crash the stop did not see is the crash', () async {
      // settleRun asks for a crash after a run that did not finish: with the
      // app gone, a crash record makes it a failure.
      final outcome = await settleRun(
        (crashed) => withStall(
          judgeTestRun(exitCode: 1, results: _appWentAway, crashed: crashed),
          gone,
        ),
        crashed: () async => true,
      );
      expect(outcome.verdict, Verdict.failed);
      expect(outcome.reason, 'the app crashed');
    });
  });

  group('the app on its device', () {
    test('pidof gives the pid', () {
      expect(androidPid('alive\n4321\n', 'com.mypackage.example'), 4321);
      expect(androidPid('alive\n4321 4322\n', 'com.mypackage.example'), 4321);
    });

    test('ps gives it on the line that names the app', () {
      // API 24's toolbox ps, which lists every process.
      const toolbox =
          'alive\n'
          'USER      PID   PPID  VSIZE  RSS   WCHAN              PC  NAME\n'
          'root      1     0     9888   1268  SyS_epoll_ 00000000 S /init\n'
          'u0_a59    2955  1360  1286180 80156 SyS_epoll_ 00000000 S com.mypackage.example\n';
      expect(androidPid(toolbox, 'com.mypackage.example'), 2955);
      // Toybox's, from Android 8, with -A.
      const toybox =
          'alive\n'
          'USER           PID  PPID     VSZ    RSS WCHAN            ADDR S NAME\n'
          'u0_a123       4321   345 1234567  89012 do_epoll_wait      0 S com.mypackage.example\n';
      expect(androidPid(toybox, 'com.mypackage.example'), 4321);
    });

    test('nothing for an app that is not there, a longer id included', () {
      expect(androidPid('alive\n', 'com.mypackage.example'), isNull);
      expect(
        androidPid(
          'alive\nu0_a1  77  1  1 1 x 0 S com.mypackage.example2\n',
          'com.mypackage.example',
        ),
        isNull,
      );
    });

    // `xcrun simctl spawn <udid> launchctl list` on an iOS 18.0 simulator, the
    // app's id put in place of Settings'.
    const launchctl =
        'PID\tStatus\tLabel\n'
        '-\t0\tcom.apple.progressd\n'
        '12658\t0\tUIKitApplication:com.apple.Spotlight[582b][rb-legacy]\n'
        '12850\t0\tUIKitApplication:com.mypackage.example[5f35][rb-legacy]\n';

    test("a simulator's launchctl gives the app's pid and bundle id", () {
      expect(
        simulatorApp(launchctl, {
          'com.mypackage.example',
          'com.mypackage.example.RunnerTests',
        }),
        (12850, 'com.mypackage.example'),
      );
    });

    test('nothing when the app is not running', () {
      expect(simulatorApp(launchctl, {'com.mypackage.other'}), isNull);
      expect(
        simulatorApp('PID\tStatus\tLabel\n-\t0\tcom.apple.progressd\n', {
          'com.apple.progressd',
        }),
        isNull,
      );
    });

    test('the processes under one, deepest first, and no other', () {
      const ps =
          '    1     0\n'
          '  100     1\n'
          '  200   100\n'
          '  201   100\n'
          '  300   200\n'
          '  400     1\n';
      expect(descendants(ps, 100), [300, 200, 201]);
      expect(descendants(ps, 300), isEmpty);
      expect(descendants('', 100), isEmpty);
    });
  });

  group('the watchdog and what it is held to', () {
    final harness = File(
      'example/integration_test/support/harness.dart',
    ).readAsStringSync();

    Duration minutes(String pattern) => Duration(
      minutes: int.parse(RegExp(pattern).firstMatch(harness)!.group(1)!),
    );

    test("waits past both of a test's own limits", () {
      final limit = minutes(r'capabilityTimeout = Duration\(minutes: (\d+)\)');
      final backstop =
          limit *
          int.parse(
            RegExp(
              r'Timeout\(capabilityTimeout \* (\d+)\)',
            ).firstMatch(harness)!.group(1)!,
          );
      expect(
        stallLimit - backstop,
        greaterThanOrEqualTo(const Duration(minutes: 1)),
      );
    });

    test('the self-test blocks the app for longer than the watchdog waits', () {
      final hang = minutes(r'hangFor = Duration\(minutes: (\d+)\)');
      expect(
        hang - stallLimit,
        greaterThanOrEqualTo(const Duration(minutes: 2)),
      );
    });

    test('the self-test comes first, and only when the build asks for it', () {
      // In the one function every entry point declares its suite through.
      final declare = harness.substring(
        harness.indexOf('void declareCapabilities('),
      );
      final selfTest = declare.indexOf(
        'if (hangOnPurpose) _capabilityThatHangs();',
      );
      expect(selfTest, greaterThan(0));
      expect(selfTest, lessThan(declare.indexOf('  capabilities();')));
      expect(
        declare.indexOf('  capabilities();'),
        lessThan(declare.indexOf('_capabilitiesAllRan(')),
      );
      expect(
        harness,
        contains('const hangOnPurpose = bool.fromEnvironment(hangDefine);'),
      );
    });

    test('CI builds and runs the app with it only in the self-test', () {
      final reusable = _readLf('.github/workflows/integration-reusable.yml');
      final define = '--dart-define=${_hangDefine(harness)}=true';
      expect(
        reusable,
        contains("HANG_TEST: \${{ inputs.hang && '$define' || '' }}"),
      );
      expect(
        reusable,
        contains(
          "HANG_TEST: \${{ inputs.hang && !matrix.profile && '$define' || '' }}",
        ),
      );
      expect(
        reusable,
        contains(
          "HANG_DRIVE: \${{ inputs.hang && matrix.profile && '$define' || '' }}",
        ),
      );
      final runs = [
        for (final line in reusable.split('\n'))
          if (line.contains('make test-example-ci ARGS=')) line,
      ];
      // iOS, and three tries of two runs each on Android.
      expect(runs, hasLength(7));
      for (final line in runs) {
        expect(
          line,
          contains(line.contains('--drive') ? r'$HANG_DRIVE"' : r'$HANG_TEST"'),
        );
      }
      expect(
        reusable,
        contains(
          r'make build-example ARGS="apk --debug --target-platform android-x64 $HANG_TEST"',
        ),
      );
      expect(
        reusable,
        contains(
          r'make build-example ARGS="apk --profile --target-platform android-x64 $HANG_DRIVE"',
        ),
      );
    });

    test('only a run started by hand can ask for it', () {
      final workflow = _readLf('.github/workflows/integration.yml');
      expect(workflow, contains(r'hang: ${{ inputs.hang == true }}'));
      expect(
        workflow,
        contains(r'if [ "$INPUT_HANG" = true ] && [ "$library" = pub ]; then'),
      );
    });
  });
}

/// A workflow's text with LF line ends. On Windows git checks the workflows out
/// with CRLF, and a pattern across lines would match nothing there.
String _readLf(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// The build files `flutter create` made the example's ids in.
const _gradle = 'example/android/app/build.gradle.kts';
const _pbxproj = 'example/ios/Runner.xcodeproj/project.pbxproj';

/// Why a test of [path] is skipped, or false to run it. A project has the file
/// from the day it was generated; a render of the template with its tasks
/// skipped, which never ran `flutter create`, has none.
Object _untilFlutterCreate(String path) =>
    File(path).existsSync() ? false : 'no $path: flutter create has not run';

/// The name of the define that builds the watchdog's self-test into the app,
/// as the harness gives it.
String _hangDefine(String harness) =>
    RegExp(r"const hangDefine = '(\w+)';").firstMatch(harness)!.group(1)!;
