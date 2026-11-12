// What `make test-example-ci` decides after each run of the example's
// integration tests: whether a test failed, or the run never got far enough to
// say.
//
// An emulator, a simulator, the connection to them and the network fail now and
// then, and a run they end proves nothing about the package either way. A test
// that fails proves something every time. So a run is judged on what the app
// reported, and never on how the command ended:
//
// - `flutter test` writes each test's outcome to a JSON file
//   (`--file-reporter json:<file>`). A test that ran in the app and failed there
//   has an `error` event of its own. A test the app never finished, because the
//   app, the device or the connection went away, is only marked done ("did not
//   complete"), with no error. Loading the suite, which builds, installs and
//   connects to the app, is a test of its own named `loading <file>`, and its
//   failure is never one of the package's tests: "Error waiting for a debug
//   connection" on a simulator is that test running out of its 12 minutes.
// - `flutter drive` reports nothing per test, so the driver,
//   `example/test_driver/integration_test.dart`, prints [reportedLine] when the
//   app hands its results over, whether they passed or not.
// - An app that crashed has failed, whatever else the run says: a native crash
//   ends the app like a device that went away does, and only the platform's own
//   crash record tells the two apart. Android keeps it in the device's crash
//   log, macOS in a report on the host, for a simulator's app too. That report
//   can come after its run was judged, so the script looks once more after the
//   last run ([runAttempts]).
// - A test that failed is the verdict from the moment it is written down,
//   however the run ends. CI stops a try that runs out of time without asking
//   it, so the script records the failure while the run is still going.
// - A run whose app has sent nothing for [stallLimit] once its tests have
//   started has stopped, and nothing on the host would end it before CI's own
//   limit: a test's limits are timers of the app's isolate, and a call that
//   blocks the isolate keeps them from firing. The device is asked what became
//   of the app ([stalledRun]): still running on a device that answers, the app
//   stopped itself, and the run has failed; with either gone, it did not
//   finish.
// - A run that has not started a test [launchLimit] after flutter said the app
//   was built, or, with no such line, [startLimit] after it started, has
//   stopped short of the tests and did not finish ([StartWatch]): the install,
//   the launch or the connection, which only CI's own limits used to end.
//
// Measured with Flutter 3.38.4 on macOS: a run that passed, a capability that
// failed, and an app that exited in the middle of the suite; and in CI, an iOS
// simulator the app never connected to.
//
// Only the script runs anything; everything here takes values.
library;

import 'dart:convert';

/// What one run of the tests came to.
enum Verdict {
  /// Every test passed.
  passed,

  /// A test failed in the app, or the app crashed. That is the package's doing
  /// or the tests', and a run that ends like this is never run again.
  failed,

  /// No test failed, and the run did not finish: the app never got to the
  /// tests, or it, the device or the connection went away. Run it again.
  unfinished,
}

/// The line the driver prints when the app has handed its results over.
///
/// `example/test_driver/integration_test.dart` prints the same text. It is a
/// package of its own, so a test reads that file to keep the two the same.
const reportedLine = 'The app handed its results over.';

/// One run, judged.
class RunOutcome {
  const RunOutcome(this.verdict, {this.failedTests = const [], this.reason});

  final Verdict verdict;

  /// The tests that failed in the app, in the order they ran.
  final List<String> failedTests;

  /// Why the run failed or did not finish, when no failed test says it.
  final String? reason;

  /// One line for the log.
  String describe() => switch (verdict) {
    Verdict.passed => 'Every test passed.',
    Verdict.failed when failedTests.isNotEmpty =>
      'Failed in the app: ${failedTests.join('; ')}.',
    Verdict.failed => 'Failed: ${reason ?? 'see the log above'}.',
    Verdict.unfinished =>
      'No test failed, and the run did not finish: '
          '${reason ?? 'see the log above'}.',
  };
}

/// Judges a `flutter test` run by its exit code and the JSON its file reporter
/// wrote, [results]: null when it wrote none. [crashed] is the platform's own
/// record that the app crashed.
RunOutcome judgeTestRun({
  required int exitCode,
  required String? results,
  bool crashed = false,
}) {
  final names = <Object, String>{};
  final failed = <String>[];
  var passed = 0;
  var suitePassed = false;
  String? loadingError;

  for (final line in const LineSplitter().convert(results ?? '')) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      // A run that was killed can leave half a line at the end.
      continue;
    }
    switch (event) {
      case {
        'type': 'testStart',
        'test': {'id': final Object id, 'name': final String name},
      }:
        names[id] = name;
      // Not matched on its `error` field: an error event without one is still
      // a failed test, and must not read as a run that did not finish.
      case {'type': 'error', 'testID': final Object id}:
        final name = names[id];
        if (name == null) break;
        if (_isLoading(name)) {
          loadingError ??= _firstLine((event as Map<String, Object?>)['error']);
        } else if (!failed.contains(name)) {
          failed.add(name);
        }
      case {
        'type': 'testDone',
        'testID': final Object id,
        'result': 'success',
        'hidden': false,
      }:
        if (names[id] case final name? when !_isLoading(name)) passed++;
      case {'type': 'done', 'success': true}:
        suitePassed = true;
    }
  }

  if (exitCode == 0) return const RunOutcome(Verdict.passed);
  if (failed.isNotEmpty) {
    return RunOutcome(Verdict.failed, failedTests: failed);
  }
  if (crashed) {
    return const RunOutcome(Verdict.failed, reason: 'the app crashed');
  }

  final started = names.values.where((name) => !_isLoading(name)).length;
  return RunOutcome(
    Verdict.unfinished,
    reason: switch ((loadingError, started)) {
      (final String error, 0) => 'the app never got to the tests: $error',
      // Once the suite has loaded, the loading test is also where an error
      // lands that belongs to no test: one the app threw outside them, or one
      // flutter met on the device or cleaning up.
      (final String error, _) =>
        'an error outside the tests, after $passed passed tests: $error',
      (null, 0) =>
        'no test started (the build, the install, the launch or the '
            'connection)',
      _ when suitePassed => 'every test passed, and flutter failed after them',
      _ => 'the app stopped answering after $passed passed tests',
    },
  );
}

/// The tests that have failed in the app so far, by what a `flutter test` run
/// that may still be going has written, [results].
///
/// A run with one has failed however it ends, so its verdict can be recorded
/// before it is over. CI stops a try that runs out of time without asking how
/// it went, and one stopped after a test had failed must not read as a try
/// that did not finish, and run again.
List<String> failedSoFar(String results) =>
    judgeTestRun(exitCode: 1, results: results).failedTests;

/// What a run came to, once the platform has been asked what the run itself
/// cannot say. [judge] gives the run's own verdict, knowing whether the app
/// crashed.
///
/// [crashed], the platform's record of a crash, is asked only after a run that
/// did not finish and in which no test failed: that is the run a crash tells
/// apart from a device that went away. [verify], whether the app loaded the
/// library the run tests, is asked only after a run that passed.
Future<RunOutcome> settleRun(
  RunOutcome Function(bool crashed) judge, {
  required Future<bool> Function() crashed,
  Future<bool> Function()? verify,
}) async {
  var outcome = judge(false);
  if (outcome.verdict == Verdict.unfinished && await crashed()) {
    outcome = judge(true);
  }
  if (outcome.verdict == Verdict.passed && verify != null && !await verify()) {
    outcome = const RunOutcome(
      Verdict.failed,
      reason: 'the app loaded another library than the run tests',
    );
  }
  return outcome;
}

/// Runs the tests up to [attempts] times, and returns how the last run went.
///
/// Only a run that did not finish runs again: one that passed or failed is the
/// last, so a test that failed is never run again. [record] hears `unfinished`
/// before each run starts, so that a run killed in the middle leaves that, and
/// each run's verdict when it ends; [run] may record `failed` sooner, while it
/// goes. [beforeRetry] runs ahead of each run but the first, and
/// [onUnfinished] after each run that did not finish.
///
/// [crashedEarlier] is asked once at the end, when a run did not finish and a
/// later one did not fail: whether the platform has recorded a crash of the
/// app since the first run after all. Each run looks for one only for a while
/// after it ends, and macOS writes a simulator app's report in its own time;
/// one that comes later belongs to a run already judged, and the run after it
/// may pass.
Future<RunOutcome> runAttempts({
  required int attempts,
  required Future<RunOutcome> Function(int attempt) run,
  required void Function(Verdict verdict) record,
  Future<void> Function(int attempt)? beforeRetry,
  void Function(int attempt, RunOutcome outcome)? onUnfinished,
  Future<bool> Function()? crashedEarlier,
}) async {
  if (attempts < 1) throw ArgumentError.value(attempts, 'attempts');
  late RunOutcome outcome;
  var ran = 0;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    record(Verdict.unfinished);
    if (attempt > 1) await beforeRetry?.call(attempt);
    outcome = await run(attempt);
    ran = attempt;
    record(outcome.verdict);
    if (outcome.verdict != Verdict.unfinished) break;
    onUnfinished?.call(attempt, outcome);
  }
  // Every run before the last one did not finish.
  if (ran > 1 &&
      outcome.verdict != Verdict.failed &&
      crashedEarlier != null &&
      await crashedEarlier()) {
    outcome = const RunOutcome(Verdict.failed, reason: crashedEarlierReason);
    record(outcome.verdict);
  }
  return outcome;
}

/// Why a run that seemed to pass, or not to finish, has failed after all: the
/// app crashed in a run before it, and the record of that came late.
const crashedEarlierReason =
    'the app crashed in an earlier run, whose crash report came after that run '
    'had been judged';

/// Judges a `flutter drive` run by its exit code and what it printed,
/// [output]. [crashed] is the platform's own record that the app crashed.
RunOutcome judgeDriveRun({
  required int exitCode,
  required String output,
  bool crashed = false,
}) {
  if (exitCode == 0) return const RunOutcome(Verdict.passed);
  final reported = const LineSplitter()
      .convert(output)
      .any((line) => line.trim() == reportedLine);
  if (reported) {
    return const RunOutcome(
      Verdict.failed,
      reason:
          'the app handed its results over, and the driver printed the '
          'failures above',
    );
  }
  // The app said so as the test failed, and never got as far as handing the
  // results over.
  final failed = driveFailedSoFar(output);
  if (failed.isNotEmpty) {
    return RunOutcome(Verdict.failed, failedTests: failed);
  }
  if (crashed) {
    return const RunOutcome(Verdict.failed, reason: 'the app crashed');
  }
  return const RunOutcome(
    Verdict.unfinished,
    reason: 'the app never handed its results over',
  );
}

/// The tests a `flutter drive` run that may still be going has seen fail, by
/// what it has printed, [output].
///
/// The app's own test runner prints a line as each test starts, `00:04 +59:
/// <test>`, and the driver passes the app's log on as it comes. A test that
/// fails prints its line again at once, with ` [E]` after the name. A run with
/// one has failed however it ends, as under `flutter test` ([failedSoFar]).
List<String> driveFailedSoFar(String output) => [
  ...{
    for (final line in const LineSplitter().convert(output))
      if (_progress.firstMatch(line)?.group(1) case final text?
          when text.endsWith(_failedMark))
        text.substring(0, text.length - _failedMark.length),
  },
];

/// How long a run may go without a word from the app, once its tests have
/// started, before it is taken to have stopped.
///
/// Past both of a test's own limits, by two minutes: `capabilityTimeout`,
/// 3 minutes, inside its body (`example/integration_test/support/harness.dart`),
/// and twice that around it. Both are timers of the app's isolate, and a call
/// that blocks the isolate keeps either from firing. Nothing on the host times
/// a test out: under `flutter drive` the driver's own limit is the app's too.
const stallLimit = Duration(minutes: 8);

/// How far a run that may still be going has got.
class RunPosition {
  const RunPosition(this.step, this.test);

  /// Grows with everything the app reports. A run that keeps one has stopped.
  final int step;

  /// The last test the run started, finished or not.
  final String test;
}

/// Where a `flutter test` run that may still be going stands, by what it has
/// written, [results]: null until a test of the suite has started, and again
/// once the suite is done. Loading it, which builds, installs and connects to
/// the app, has a limit of its own.
RunPosition? testRunPosition(String results) {
  var step = 0;
  String? last;
  for (final line in const LineSplitter().convert(results)) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    step++;
    switch (event) {
      case {'type': 'testStart', 'test': {'name': final String name}}
          when !_isLoading(name):
        last = name;
      case {'type': 'done'}:
        return null;
    }
  }
  return last == null ? null : RunPosition(step, last);
}

/// The same for a `flutter drive` run, by what it has printed, [output]: null
/// until the app's test runner has started a test, and again once it has
/// printed its last line.
RunPosition? driveRunPosition(String output) {
  var step = 0;
  String? last;
  for (final line in const LineSplitter().convert(output)) {
    final text = _progress.firstMatch(line)?.group(1);
    if (text == null) continue;
    step++;
    if (_finalLines.contains(text)) return null;
    last = text.endsWith(_failedMark)
        ? text.substring(0, text.length - _failedMark.length)
        : text;
  }
  return last == null ? null : RunPosition(step, last);
}

/// Tells a run that has stopped from one that is going: one whose position has
/// not moved for [limit].
class StallWatch {
  StallWatch([this.limit = stallLimit]);

  final Duration limit;
  int? _step;
  DateTime? _since;

  /// The last test the run started, once it has stood at [position] for
  /// [limit] by [now]: null while it moves, and while it has no position.
  String? check(RunPosition? position, DateTime now) {
    if (position == null) {
      _step = null;
      _since = null;
      return null;
    }
    if (position.step != _step) {
      _step = position.step;
      _since = now;
      return null;
    }
    return now.difference(_since!) >= limit ? position.test : null;
  }
}

/// How long a run may go from the line saying the app was built to its first
/// test: installing the app, launching it and connecting to it.
///
/// Measured in CI, in a project generated from this template, over 204 runs:
/// 3 to 13 seconds on an Android emulator, 10 to 95 on an iOS simulator. The 17
/// runs that never got there stood still after that line until something ended
/// them: 11 iOS apps that never connected, until flutter gave up 12 minutes on;
/// Android profile installs that hung, two of them until the step's limit 28
/// minutes on; and an iOS install or launch that hung for 54, until the step's
/// limit took the time of the two runs that would have followed it.
const launchLimit = Duration(minutes: 5);

/// How long a run may go from its start to its first test while flutter has
/// not said the app was built: the limit when that line never comes, flutter
/// having worded it otherwise or hung before it.
///
/// The build is inside it, and a simulator's first run builds with nothing
/// cached: flutter's iOS tools, the pods and Xcode took a run up to 9 minutes
/// and 14 seconds to its first test, in the same measurement.
const startLimit = Duration(minutes: 20);

/// Whether flutter's [line] says the app has been built: `Xcode build done.` for
/// iOS, `✓ Built build/…` for Android. Flutter 3.38.4 and 3.47.9 word them so
/// (`ios/mac.dart`, `android/gradle.dart`), and a terminal can colour them.
bool isBuildLine(String line) => _buildLine.hasMatch(line);

final _buildLine = RegExp(r'Xcode build done\.|\bBuilt build[/\\]');

/// Tells a run that has stopped before its first test from one still on its
/// way there: no test [afterBuild] after the line saying the app was built, or,
/// while that line has not come, [fromStart] after the run started.
class StartWatch {
  StartWatch(
    this.started, {
    this.afterBuild = launchLimit,
    this.fromStart = startLimit,
  });

  /// When the run started.
  final DateTime started;

  /// [launchLimit] unless told otherwise.
  final Duration afterBuild;

  /// [startLimit] unless told otherwise.
  final Duration fromStart;

  DateTime? _built;
  var _tested = false;

  /// Notes that flutter said, at [at], that the app was built. A later line
  /// starts the count again.
  void built(DateTime at) => _built = at;

  /// What the run comes to, once it has stopped short of its tests by [now],
  /// [position] being where it stands: null while it may still get there, and
  /// for good once a test has started.
  RunOutcome? check(RunPosition? position, DateTime now) {
    if (position != null) _tested = true;
    if (_tested) return null;
    if (_built case final built?) {
      if (now.difference(built) < afterBuild) return null;
      return RunOutcome(
        Verdict.unfinished,
        reason:
            'no test had started ${_span(afterBuild)} after the app was '
            'built: the install, the launch or the connection',
      );
    }
    if (now.difference(started) < fromStart) return null;
    return RunOutcome(
      Verdict.unfinished,
      reason:
          'no test had started ${_span(fromStart)} after the run did, and '
          'flutter had not said the app was built',
    );
  }
}

/// What the device showed of the app once its run had stopped.
enum AppState {
  /// The device answered, and the app's process was there.
  running,

  /// The device answered, and the app's process was gone.
  gone,

  /// The device did not answer.
  unreachable,

  /// Nothing was asked: the app runs on this machine, as a process of its own
  /// that nothing here knows.
  unchecked,
}

/// What a run that has stopped comes to, [test] being the last one it started
/// and [app] what the device showed after [limit] without a word.
///
/// An app still running on a device that answers has stopped itself: its test
/// went past both of its own limits, and only a call that blocks the app's
/// isolate keeps those from firing. That is the package's doing or the tests',
/// and fails the run, which then never runs again. With the app gone, or the
/// device, it is a run that did not finish, like any other they went away in.
RunOutcome stalledRun(
  String test,
  AppState app, {
  Duration limit = stallLimit,
}) {
  final silence =
      'the app sent nothing for ${_span(limit)}, the last test it started '
      'being "$test"';
  return switch (app) {
    AppState.running => RunOutcome(
      Verdict.failed,
      reason: '$silence, and it was still running on a device that answered',
    ),
    AppState.unchecked => RunOutcome(Verdict.failed, reason: silence),
    AppState.gone => RunOutcome(
      Verdict.unfinished,
      reason: '$silence, and then it was gone',
    ),
    AppState.unreachable => RunOutcome(
      Verdict.unfinished,
      reason: '$silence, and then the device did not answer',
    ),
  };
}

/// A run's own verdict, [own], and what stopping it found, [stall]. A test that
/// failed, or an app that crashed, says more than the stop does; otherwise the
/// stop decides, having seen what the run could not.
RunOutcome withStall(RunOutcome own, RunOutcome? stall) =>
    own.verdict == Verdict.failed || stall == null ? own : stall;

/// The process id of the app [applicationId] on an Android device, in what was
/// printed there: the pid `pidof` gives, or the line of `ps` that names the app,
/// `USER PID PPID … NAME`. Null when neither has it.
int? androidPid(String output, String applicationId) {
  for (final line in const LineSplitter().convert(output)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.every(_isNumber)) return int.parse(fields.first);
    if (fields.length > 2 && fields.last == applicationId) {
      return int.tryParse(fields[1]);
    }
  }
  return null;
}

/// The process id and the bundle id of the app in a simulator, by what
/// `launchctl list` printed in it, [launchctl]: lines of `PID\tStatus\tLabel`,
/// an app's label being `UIKitApplication:<bundle id>[…]` and its PID the
/// host's. Null when none of [bundleIds] is running.
(int, String)? simulatorApp(String launchctl, Set<String> bundleIds) {
  const prefix = 'UIKitApplication:';
  for (final line in const LineSplitter().convert(launchctl)) {
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    final pid = int.tryParse(fields[0].trim());
    final label = fields[2].trim();
    if (pid == null || !label.startsWith(prefix)) continue;
    final id = label.substring(prefix.length).split('[').first;
    if (bundleIds.contains(id)) return (pid, id);
  }
  return null;
}

/// The processes under [root], deepest first, by what `ps -A -o pid=,ppid=`
/// printed, [ps]: the order to end them in, so that none is left to start
/// another.
List<int> descendants(String ps, int root) {
  final children = <int, List<int>>{};
  for (final line in const LineSplitter().convert(ps)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length != 2) continue;
    final pid = int.tryParse(fields[0]);
    final parent = int.tryParse(fields[1]);
    if (pid == null || parent == null) continue;
    (children[parent] ??= []).add(pid);
  }
  final found = <int>[];
  void visit(int pid) {
    for (final child in children[pid] ?? const <int>[]) {
      if (child == root || found.contains(child)) continue;
      visit(child);
      found.add(child);
    }
  }

  visit(root);
  return found;
}

/// The arguments to `make` that run one of the example's [target]s on the app
/// in [app], with [args] for flutter, and with [flutter] when it is given.
///
/// `FVM=`, because the script runs under `fvm dart`, and fvm has put the pinned
/// Flutter and its Dart first on PATH: the target finds them there. Through fvm
/// once more it failed in CI, every time — "fvm as globally activated doesn't
/// support Dart 3.10.3" — since the global fvm is a snapshot of a newer Dart
/// than the one now first on PATH.
///
/// [flutter] is the app's own, which the Makefile resolves with fvm from the
/// app's directory before this script starts. Without it, an app whose
/// `.fvmrc` names another Flutter than the project's ran on the pinned one: the
/// one `make create-consumer FLUTTER_VERSION=…` makes for the newest Flutter
/// stopped at its first `pub get`, which needed a newer Dart.
List<String> makeArguments(
  String target, {
  required String app,
  required List<String> args,
  String? flutter,
}) => [
  'FVM=',
  if (flutter != null) 'EXAMPLE_FLUTTER=$flutter',
  target,
  'EXAMPLE_DIR=$app',
  'ARGS=${args.join(' ')}',
];

/// The application id an Android app's `android/app/build.gradle.kts`, or
/// `build.gradle`, gives it.
String? androidApplicationId(String gradle) => RegExp(
  r'''applicationId\s*=?\s*["']([\w.]+)["']''',
).firstMatch(gradle)?.group(1);

/// Whether Android's crash log, `adb logcat -b crash -d`, holds a crash of the
/// app [applicationId]. A Java crash names it as `Process: <id>, PID: …`, a
/// native one as `>>> <id> <<<`.
bool crashedOnAndroid(String crashLog, String applicationId) {
  final id = RegExp.escape(applicationId);
  return RegExp('Process: $id[,\\s]|>>> $id <<<').hasMatch(crashLog);
}

/// The bundle ids an iOS app's `ios/Runner.xcodeproj/project.pbxproj` gives
/// its targets: the app's, and its tests'.
Set<String> iosBundleIds(String pbxproj) => {
  for (final match in RegExp(
    r'PRODUCT_BUNDLE_IDENTIFIER = "?([\w.-]+)"?;',
  ).allMatches(pbxproj))
    match.group(1)!,
};

/// Whether a crash report macOS wrote, `~/Library/Logs/DiagnosticReports/*.ips`,
/// is of an app with one of [bundleIds] in a simulator. The first line of the
/// report is a JSON header, `{"app_name":"Runner",…,"platform":7,"bundleID":…}`,
/// platform 7 being the iOS simulator. macOS writes it for a simulator app too,
/// measured: a native abort in the example on an iOS 26.2 simulator, half a
/// minute after `flutter test` had given up on the app.
bool crashedOnSimulator(String report, Set<String> bundleIds) {
  final header = const LineSplitter().convert(report).firstOrNull;
  if (header == null) return false;
  try {
    return switch (jsonDecode(header)) {
      {'bundleID': final String id, 'platform': 7} => bundleIds.contains(id),
      _ => false,
    };
  } on FormatException {
    return false;
  }
}

bool _isLoading(String name) => name.startsWith('loading ');

String? _firstLine(Object? text) =>
    text is String ? const LineSplitter().convert(text).firstOrNull : null;

/// A line of the app's own test runner, `MM:SS +passed ~skipped -failed:
/// <what>`, the last two only when there are any, after whatever the log puts
/// in front of it: `flutter: `, or Android's `I/flutter ( 2955): `. Flutter
/// 3.38.4, `_Reporter` in `package:flutter_test/src/test_compat.dart`.
final _progress = RegExp(r'(?:^|\s)\d+:\d\d \+\d+(?: ~\d+)?(?: -\d+)?: (.*)$');

/// What that runner puts after a test that has just failed.
const _failedMark = ' [E]';

/// Its last line, once every test has run.
const _finalLines = {
  'All tests passed!',
  'Some tests failed.',
  'All tests skipped.',
};

bool _isNumber(String text) => RegExp(r'^\d+$').hasMatch(text);

/// [duration] in words, in whole minutes when it has them.
String _span(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds;
  if (seconds % 60 == 0) return minutes == 1 ? '1 minute' : '$minutes minutes';
  return seconds == 1 ? '1 second' : '$seconds seconds';
}
