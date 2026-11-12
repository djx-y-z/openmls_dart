/// Run the example's integration tests the way CI does: judge each run on what
/// the app reported, fail at once on a test that failed, and run again, up to
/// `--attempts`, only when a run never got that far. See
/// `scripts/src/example_run.dart`.
///
/// Usage: make test-example-ci ARGS="[options] -- <arguments for flutter>"
///
///   --drive             Under `flutter drive` (`make drive-example`), the way to
///                       run them in profile mode. Otherwise `flutter test`.
///   --attempts <n>      How many runs in all, at most. 1 by default.
///   --simulator <udid>  The tests run on this iOS simulator: after a run that
///                       did not finish, look for a crash report of the app,
///                       and reboot the simulator before the third run and each
///                       one after it. After the last run, look once more, for
///                       a report of any run that came after its run's look.
///   --android <serial>  The tests run on this Android device: after a run that
///                       did not finish, read its crash log. An app that
///                       crashed has failed, whatever else the run says.
///   --verify=<args>     After a run that passed, `make verify-example-library
///                       ARGS="<args>"`. A run that loaded the wrong library
///                       has failed.
///   --verdict <file>    Write the last run's verdict there: passed, failed or
///                       unfinished, for a caller that runs it again itself.
///                       `unfinished` goes in first, so a run that was killed
///                       leaves that; `failed` goes in as soon as a test has
///                       failed, so a run killed after that leaves `failed`.
///   --stall-after <s>   Stop a run whose app has sent nothing for this many
///                       seconds once its tests have started: 480 by default
///                       (`stallLimit`). An app still running on a device that
///                       answers has failed the run, and its threads go to the
///                       log when the device gives them; with the app or the
///                       device gone, the run did not finish.
///   --launch-within <s> Stop a run that has not started a test this many
///                       seconds after flutter said the app was built: 300 by
///                       default (`launchLimit`). The run did not finish.
///   --start-within <s>  The same, counted from the start of the run, for when
///                       that line never comes: 1200 by default (`startLimit`).
///                       CI passes neither, nor any option a tag made before them
///                       would refuse: a `pub` run runs the tag's own script.
///   --flutter <path>    The flutter the app runs on. The Makefile passes the
///                       one fvm resolves in the app's directory: this script
///                       runs under `fvm dart`, which puts the project's pinned
///                       Flutter first on PATH, so an app whose .fvmrc names
///                       another would run on the pinned one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/example_run.dart';

Future<void> main(List<String> args) async {
  final split = args.indexOf('--');
  final options = split < 0 ? args : args.sublist(0, split);
  final flutterArgs = split < 0 ? const <String>[] : args.sublist(split + 1);

  const valued = {
    '--attempts',
    '--simulator',
    '--android',
    '--verdict',
    '--dir',
    '--stall-after',
    '--launch-within',
    '--start-within',
    '--flutter',
  };
  final values = <String, String>{};
  var drive = false;
  String? verify;
  for (var i = 0; i < options.length; i++) {
    final option = options[i];
    if (option == '--drive') {
      drive = true;
    } else if (option.startsWith('--verify=')) {
      verify = option.substring('--verify='.length);
    } else if (valued.contains(option) && i + 1 < options.length) {
      values[option] = options[++i];
    } else {
      _usage('Not an option here, or one without its value: $option');
    }
  }
  final attempts = int.tryParse(values['--attempts'] ?? '1');
  if (attempts == null || attempts < 1) {
    _usage('--attempts takes a whole number from 1.');
  }
  Duration seconds(String option, Duration byDefault) {
    final value = int.tryParse(values[option] ?? '${byDefault.inSeconds}');
    if (value == null || value < 1) {
      _usage('$option takes a whole number of seconds from 1.');
    }
    return Duration(seconds: value);
  }

  final stallAfter = seconds('--stall-after', stallLimit);
  final launchWithin = seconds('--launch-within', launchLimit);
  final startWithin = seconds('--start-within', startLimit);

  final verdict = values['--verdict'];
  final simulator = values['--simulator'];
  void record(Verdict value) => _writeVerdict(verdict, value);

  final flutter = switch (values['--flutter']) {
    null || '' => null,
    final path => path,
  };
  if (flutter != null) stdout.writeln('The app runs on $flutter.');

  final run = _Run(
    app: values['--dir'] ?? 'example',
    flutter: flutter,
    flutterArgs: flutterArgs,
    drive: drive,
    android: values['--android'],
    simulator: simulator,
    verify: verify,
    results: Directory.systemTemp.createTempSync('example-run-'),
    record: record,
    stallLimit: stallAfter,
    launchLimit: launchWithin,
    startLimit: startWithin,
  );

  final outcome = await runAttempts(
    attempts: attempts,
    record: record,
    beforeRetry: (attempt) async {
      // What ended the run before, the network above all, is often over by now.
      await Future<void>.delayed(const Duration(seconds: 30));
      if (simulator != null && attempt >= 3) await _reboot(simulator);
    },
    run: (attempt) {
      stdout.writeln(
        '\nRun $attempt of $attempts, under flutter ${drive ? 'drive' : 'test'}: '
        '${flutterArgs.join(' ')}',
      );
      return run.once(attempt);
    },
    onUnfinished: (attempt, outcome) {
      // An error only for a single run: after several, the one below sums
      // them up, and with --verdict the caller decides.
      _annotate(
        attempts > 1 || verdict != null ? 'warning' : 'error',
        'Run $attempt of $attempts: ${outcome.describe()}'
        '${attempt < attempts ? ' Running the tests again.' : ''}',
      );
    },
    crashedEarlier: run.crashedSinceFirstRun,
  );
  switch (outcome.verdict) {
    case Verdict.passed:
      stdout.writeln(outcome.describe());
      exit(0);
    case Verdict.failed:
      // Once on the run's page: the run may have said it while it went.
      if (run.failureAnnounced) {
        stdout.writeln(outcome.describe());
      } else {
        _annotate(
          'error',
          '${outcome.describe()} A test that fails is not run again.',
        );
      }
      exit(1);
    case Verdict.unfinished:
      if (verdict == null && attempts > 1) {
        _annotate(
          'error',
          'None of the $attempts runs finished, and no test failed in any of '
              'them: the device, the connection or the runner. The log of each '
              'says why.',
        );
      }
      exit(1);
  }
}

class _Run {
  _Run({
    required this.app,
    required this.flutter,
    required this.flutterArgs,
    required this.drive,
    required this.android,
    required this.simulator,
    required this.verify,
    required this.results,
    required this.record,
    required this.stallLimit,
    required this.launchLimit,
    required this.startLimit,
  });

  final String app;

  /// The flutter the app runs on, when the Makefile resolved its own.
  final String? flutter;
  final List<String> flutterArgs;
  final bool drive;
  final String? android;
  final String? simulator;
  final String? verify;
  final Directory results;

  /// Writes the verdict down for a caller that runs the tests again itself.
  final void Function(Verdict verdict) record;

  /// How long the app may send nothing, once its tests have started.
  final Duration stallLimit;

  /// How long a run may take to its first test, after flutter said the app
  /// was built, and after the run started.
  final Duration launchLimit;
  final Duration startLimit;

  /// Whether a run has already said, while it went, that a test failed.
  bool failureAnnounced = false;

  /// When the first run started.
  DateTime? firstStarted;

  Future<RunOutcome> once(int attempt) async {
    final started = DateTime.now();
    firstStarted ??= started;
    final (code, judge) = drive ? await _drive() : await _test(attempt);
    // Before anything slow, which a time limit could cut short: a test that
    // failed is the verdict, whatever comes after.
    if (judge(false).verdict == Verdict.failed) record(Verdict.failed);
    if (code != 0 && android != null) await _printAndroidLog(android!);
    final library = verify;
    return settleRun(
      judge,
      crashed: () => _crashed(started),
      verify: library == null
          ? null
          : () async => await _make('verify-example-library', [library]) == 0,
    );
  }

  Future<(int, RunOutcome Function(bool crashed))> _test(int attempt) async {
    final file = File('${results.absolute.path}/run-$attempt.json');
    if (file.existsSync()) file.deleteSync();
    final run = await _start(
      makeArguments(
        'test-example',
        app: app,
        args: [...flutterArgs, '--file-reporter', 'json:${file.path}'],
        flutter: flutter,
      ),
    );
    // CI stops a try that runs out of time without asking it, and one stopped
    // after a test had failed must not read as one that did not finish. So the
    // results are read while the run goes, and a failure recorded at once.
    final watched = _watch(run, () {
      final text = _read(file) ?? '';
      _announce(failedSoFar(text));
      return testRunPosition(text);
    });
    final code = await run.process.exitCode;
    final stop = await watched();
    await run.drained();
    final text = _read(file);
    return (
      code,
      (bool crashed) => withStall(
        judgeTestRun(exitCode: code, results: text, crashed: crashed),
        stop,
      ),
    );
  }

  Future<(int, RunOutcome Function(bool crashed))> _drive() async {
    final run = await _start(
      makeArguments(
        'drive-example',
        app: app,
        args: flutterArgs,
        flutter: flutter,
      ),
    );
    // The app prints a line as each test starts and as one fails, and the
    // driver passes them on as they come.
    final watched = _watch(run, () {
      final text = run.output.toString();
      _announce(driveFailedSoFar(text));
      return driveRunPosition(text);
    });
    final code = await run.process.exitCode;
    final stop = await watched();
    await run.drained();
    final text = run.output.toString();
    return (
      code,
      (bool crashed) => withStall(
        judgeDriveRun(exitCode: code, output: text, crashed: crashed),
        stop,
      ),
    );
  }

  /// Starts `make` with [arguments], its output passed on as it comes. What it
  /// printed is kept, and a line saying the app was built starts the count
  /// towards [launchLimit].
  Future<_Started> _start(List<String> arguments) async {
    final starts = StartWatch(
      DateTime.now(),
      afterBuild: launchLimit,
      fromStart: startLimit,
    );
    final process = await Process.start('make', arguments);
    final output = StringBuffer();
    const decoder = Utf8Decoder(allowMalformed: true);
    Future<void> copy(Stream<List<int>> from, IOSink to) {
      // A line can come in two pieces: the end of one is held for the next.
      var partial = '';
      return from.transform(decoder).forEach((text) {
        to.write(text);
        output.write(text);
        final lines = '$partial$text'.split('\n');
        partial = lines.removeLast();
        if (lines.any(isBuildLine)) starts.built(DateTime.now());
      });
    }

    return _Started(process, output, starts, [
      copy(process.stdout, stdout),
      copy(process.stderr, stderr),
    ]);
  }

  /// Writes down and says, once, that tests have failed in a run that is
  /// going: [failed], when there are any.
  void _announce(List<String> failed) {
    if (failureAnnounced || failed.isEmpty) return;
    record(Verdict.failed);
    failureAnnounced = true;
    _annotate(
      'error',
      'Failed in the app: ${failed.join('; ')}. A test that fails is not run '
          'again; this run goes on to its end.',
    );
  }

  /// Reads the run through [look] every 2 seconds while it goes, and stops it
  /// once it has stood still for [stallLimit] in its tests, or has not got to
  /// them in time ([StartWatch]). The function it gives stops the reading, and
  /// gives what stopping the run came to, if it was stopped.
  Future<RunOutcome?> Function() _watch(
    _Started run,
    RunPosition? Function() look,
  ) {
    final stalls = StallWatch(stallLimit);
    Future<RunOutcome>? stopping;
    final timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (stopping != null) return;
      final now = DateTime.now();
      final position = look();
      if (stalls.check(position, now) case final test?) {
        stopping = _stop(
          run.process,
          (app) => stalledRun(test, app, limit: stallLimit),
        );
      } else if (run.starts.check(position, now) case final outcome?) {
        stopping = _stop(run.process, (_) => outcome);
      }
    });
    return () async {
      timer.cancel();
      return stopping;
    };
  }

  /// Stops a run that has stood still, or never got to its tests, [judge]
  /// saying what that comes to given what became of the app. The device is
  /// asked that, and the verdict written down at once, ahead of anything a
  /// time limit could cut short. Then the app's threads go to the log, the app
  /// is ended, and flutter too if it does not end with it.
  Future<RunOutcome> _stop(
    Process process,
    RunOutcome Function(AppState app) judge,
  ) async {
    final probe = await _probe();
    final outcome = judge(probe.state);
    final failed = outcome.verdict == Verdict.failed;
    if (failed) {
      record(Verdict.failed);
      failureAnnounced = true;
    }
    final threads = switch (probe.pid) {
      final pid? => await _printThreads(pid),
      null => false,
    };
    if (failed) {
      _annotate(
        'error',
        '${outcome.describe()} A test that hangs is not run again'
            '${threads ? "; the app's threads are in the log" : ''}.',
      );
    } else {
      stdout.writeln('${outcome.describe()} Ending the run.');
    }
    if (await _endApp(probe)) {
      final ended = await process.exitCode
          .then((_) => true)
          .timeout(const Duration(minutes: 1), onTimeout: () => false);
      if (ended) return outcome;
      stdout.writeln('flutter was still going a minute after the app ended.');
    }
    stdout.writeln('Ending flutter, and every process it started.');
    await _endTree(process.pid);
    return outcome;
  }

  /// What the device shows of the app, and where its process is.
  Future<_Probe> _probe() async {
    if (android case final serial?) {
      final id = _androidId();
      if (id == null) return const _Probe(AppState.unchecked);
      // `pidof` where the device has one, and `ps` where it does not: every
      // process with -A from Android 8, and without it before.
      final result = await _capture('adb', [
        '-s',
        serial,
        'shell',
        'echo alive; pidof $id || { ps -A; ps; } 2>/dev/null',
      ]);
      if (result == null ||
          !const LineSplitter()
              .convert(result.stdout)
              .any((line) => line.trim() == 'alive')) {
        return const _Probe(AppState.unreachable);
      }
      final pid = androidPid(result.stdout, id);
      return pid == null
          ? const _Probe(AppState.gone)
          : _Probe(AppState.running, pid: pid, app: id);
    }
    if (simulator case final udid?) {
      final result = await _capture('xcrun', [
        'simctl',
        'spawn',
        udid,
        'launchctl',
        'list',
      ]);
      if (result == null || result.exitCode != 0) {
        return const _Probe(AppState.unreachable);
      }
      final found = simulatorApp(result.stdout, _iosIds());
      return found == null
          ? const _Probe(AppState.gone)
          : _Probe(AppState.running, pid: found.$1, app: found.$2);
    }
    return const _Probe(AppState.unchecked);
  }

  /// Leaves the threads of the app's process [pid] in the log, and with them
  /// the call that blocks it. False when the device would not give them.
  Future<bool> _printThreads(int pid) async {
    if (android case final serial?) {
      // Neither emulator image CI uses gives debuggerd to the shell, measured:
      // API 24's SELinux hides it ("not found"), API 36 wants root. Their `su`
      // gives root without restarting adbd, which `adb root` would do, and
      // flutter's connection to the app with it.
      final result = await _capture('adb', [
        '-s',
        serial,
        'shell',
        'su 0 debuggerd -b $pid 2>/dev/null || debuggerd -b $pid',
      ], timeout: const Duration(minutes: 1));
      _printGroup(
        "The app's threads (debuggerd -b $pid)",
        result == null
            ? 'debuggerd gave nothing.'
            : '${result.stdout}${result.stderr}',
      );
      return result != null &&
          result.exitCode == 0 &&
          result.stdout.trim().isNotEmpty;
    }
    // A simulator's app is a process of this machine.
    final file = File('${results.absolute.path}/threads-$pid.txt');
    final result = await _capture('sample', [
      '$pid',
      '3',
      '-file',
      file.path,
    ], timeout: const Duration(minutes: 1));
    final threads = _read(file);
    _printGroup(
      "The app's threads (sample $pid)",
      threads ?? result?.stderr ?? 'sample gave nothing.',
    );
    return threads != null && threads.trim().isNotEmpty;
  }

  /// Ends the app on its device, which ends flutter's run. False when there is
  /// none to end: the device does not answer, or nothing here knows the app.
  Future<bool> _endApp(_Probe probe) async {
    switch (probe.state) {
      case AppState.gone:
        return true;
      case AppState.unreachable || AppState.unchecked:
        return false;
      case AppState.running:
        break;
    }
    final app = probe.app!;
    final result = android != null
        ? await _capture('adb', [
            '-s',
            android!,
            'shell',
            'am',
            'force-stop',
            app,
          ])
        : await _capture('xcrun', ['simctl', 'terminate', simulator!, app]);
    return result != null && result.exitCode == 0;
  }

  /// Ends the process [pid] and every process under it.
  Future<void> _endTree(int pid) async {
    if (Platform.isWindows) {
      await _capture('taskkill', ['/PID', '$pid', '/T', '/F']);
      return;
    }
    final listing = await _capture('ps', ['-A', '-o', 'pid=,ppid=']);
    final tree = [...descendants(listing?.stdout ?? '', pid), pid];
    for (final each in tree) {
      Process.killPid(each);
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    for (final each in tree) {
      Process.killPid(each, ProcessSignal.sigkill);
    }
  }

  Future<int> _make(String target, List<String> args) async {
    final process = await Process.start(
      'make',
      makeArguments(target, app: app, args: args, flutter: flutter),
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  /// The application id of the Android app, from its Gradle build file.
  String? _androidId() {
    final gradle = ['build.gradle.kts', 'build.gradle']
        .map((name) => File('$app/android/app/$name'))
        .where((f) => f.existsSync());
    return gradle.isEmpty
        ? null
        : androidApplicationId(gradle.first.readAsStringSync());
  }

  /// The bundle ids of the iOS app and of its tests, from its Xcode project.
  Set<String> _iosIds() {
    final pbxproj = File('$app/ios/Runner.xcodeproj/project.pbxproj');
    return pbxproj.existsSync()
        ? iosBundleIds(pbxproj.readAsStringSync())
        : const <String>{};
  }

  /// Whether the platform recorded a crash of the app since [since].
  Future<bool> _crashed(DateTime since) async {
    if (android case final serial?) return _crashedOnAndroid(serial);
    if (simulator != null) return _crashedOnSimulator(since);
    return false;
  }

  /// Whether the platform has recorded a crash of the app since the first run
  /// started, for `runAttempts` to ask at the end. It does not wait for a
  /// report: the last run has had its wait, and the others the time since.
  Future<bool> crashedSinceFirstRun() async {
    final since = firstStarted;
    if (since == null) return false;
    stdout.writeln(
      '\nLooking back for a crash of the app in any run: a report can come '
      'after its run was judged.',
    );
    if (android case final serial?) return _crashedOnAndroid(serial);
    if (simulator != null) {
      return _crashedOnSimulator(since, wait: Duration.zero);
    }
    return false;
  }

  /// Android's crash log starts empty with each emulator, so whatever it holds
  /// of the app is this try's.
  Future<bool> _crashedOnAndroid(String serial) async {
    final id = _androidId();
    if (id == null) {
      stderr.writeln(
        'No application id in $app/android/app/: no crash log read.',
      );
      return false;
    }
    try {
      final result = await Process.run('adb', [
        '-s',
        serial,
        'logcat',
        '-b',
        'crash',
        '-d',
      ]).timeout(const Duration(minutes: 1));
      // A device that went away has no log to read, and no crash to show.
      if (result.exitCode != 0) return false;
      final log = result.stdout as String;
      if (!crashedOnAndroid(log, id)) return false;
      stdout.writeln('The crash log names $id:\n$log');
      return true;
    } on Object catch (e) {
      stderr.writeln('Could not read the crash log: $e');
      return false;
    }
  }

  /// macOS writes a simulator app's crash report on the host, and takes its
  /// time: measured, half a minute after `flutter test` had given up on the
  /// app. So this waits up to [wait] for one, a minute and a half unless told
  /// otherwise, which only a run that did not finish pays.
  Future<bool> _crashedOnSimulator(
    DateTime since, {
    Duration wait = const Duration(seconds: 90),
  }) async {
    final ids = _iosIds();
    final home = Platform.environment['HOME'];
    if (ids.isEmpty || home == null) {
      stderr.writeln('No bundle id in $app/ios/: no crash report looked for.');
      return false;
    }
    final reports = Directory('$home/Library/Logs/DiagnosticReports');
    stdout.writeln('Looking for a crash report of ${ids.join(' or ')}.');
    final deadline = DateTime.now().add(wait);
    while (true) {
      if (reports.existsSync()) {
        for (final entry in reports.listSync()) {
          if (entry is! File || !entry.path.endsWith('.ips')) continue;
          final String report;
          try {
            // A second of slack: the file system's clock and this one may not
            // agree to the millisecond.
            final written = entry.lastModifiedSync();
            if (written.isBefore(since.subtract(const Duration(seconds: 1)))) {
              continue;
            }
            report = entry.readAsStringSync();
          } on FileSystemException {
            // Gone, or moved aside, since the listing.
            continue;
          }
          if (crashedOnSimulator(report, ids)) {
            stdout.writeln('The app crashed: ${entry.path}');
            return true;
          }
        }
      }
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }
}

/// A run of flutter under `make`: the process, what it has printed so far,
/// and the watch on how long it takes to its first test.
class _Started {
  _Started(this.process, this.output, this.starts, this._copies);

  final Process process;
  final StringBuffer output;
  final StartWatch starts;
  final List<Future<void>> _copies;

  /// Waits for the output to end, a minute at most: a process flutter left
  /// behind can hold it open.
  Future<void> drained() => Future.wait(
    _copies,
  ).timeout(const Duration(minutes: 1), onTimeout: () => const <void>[]);
}

/// What the device showed of the app, and the app's process when it was there.
class _Probe {
  const _Probe(this.state, {this.pid, this.app});

  final AppState state;

  /// The app's process id: the device's, or this machine's for a simulator.
  final int? pid;

  /// The app's application id, or its bundle id.
  final String? app;
}

/// Runs [executable], and gives how it ended and what it printed: null when it
/// could not start, or did not end within [timeout] and was ended.
Future<({int exitCode, String stdout, String stderr})?> _capture(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Process process;
  try {
    process = await Process.start(executable, arguments);
  } on ProcessException catch (e) {
    stderr.writeln('Could not run $executable: ${e.message}');
    return null;
  }
  const decoder = Utf8Decoder(allowMalformed: true);
  final out = process.stdout.transform(decoder).join();
  final err = process.stderr.transform(decoder).join();
  final code = await process.exitCode
      .then<int?>((code) => code)
      .timeout(
        timeout,
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return null;
        },
      );
  if (code == null) {
    stderr.writeln(
      '$executable ${arguments.join(' ')} did not end in '
      '${timeout.inSeconds} seconds.',
    );
    return null;
  }
  return (exitCode: code, stdout: await out, stderr: await err);
}

/// The end of the device's log, for whoever reads why the run failed.
Future<void> _printAndroidLog(String serial) async {
  final process = await Process.start('adb', [
    '-s',
    serial,
    'logcat',
    '-d',
    '-t',
    '500',
    '*:W',
  ], mode: ProcessStartMode.inheritStdio);
  await process.exitCode.timeout(
    const Duration(minutes: 1),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
}

Future<void> _reboot(String udid) async {
  stdout.writeln('Rebooting the simulator $udid first.');
  // Fails when it is already shut down, which is fine.
  await Process.run('xcrun', ['simctl', 'shutdown', udid]);
  for (final command in ['boot', 'bootstatus']) {
    final process = await Process.start('xcrun', [
      'simctl',
      command,
      udid,
    ], mode: ProcessStartMode.inheritStdio);
    final code = await process.exitCode;
    if (code != 0) stderr.writeln('xcrun simctl $command exited $code.');
  }
}

void _writeVerdict(String? path, Verdict verdict) {
  if (path != null) File(path).writeAsStringSync('${verdict.name}\n');
}

/// What [file] holds, or null when it is not there. A file still being written
/// can end in the middle of a character: decoded leniently, it ends in half a
/// line, which the judge skips like any other.
String? _read(File file) {
  try {
    return utf8.decode(file.readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

/// A message GitHub shows on the run, or a plain line anywhere else.
void _annotate(String level, String message) {
  if (Platform.environment['GITHUB_ACTIONS'] == 'true') {
    final escaped = message
        .replaceAll('%', '%25')
        .replaceAll('\r', '%0D')
        .replaceAll('\n', '%0A');
    stdout.writeln('::$level::$escaped');
  } else {
    (level == 'error' ? stderr : stdout).writeln(message);
  }
}

/// [text] under [title]: folded away on a GitHub run, which is long already.
void _printGroup(String title, String text) {
  final github = Platform.environment['GITHUB_ACTIONS'] == 'true';
  stdout.writeln(github ? '::group::$title' : '--- $title');
  stdout.write(text.endsWith('\n') ? text : '$text\n');
  if (github) stdout.writeln('::endgroup::');
}

Never _usage(String problem) {
  stderr.writeln(problem);
  stderr.writeln(
    'Usage: make test-example-ci ARGS="[--drive] [--attempts <n>] '
    '[--simulator <udid>] [--android <serial>] [--verify=<args>] '
    '[--verdict <file>] [--stall-after <seconds>] [--launch-within <seconds>] '
    '[--start-within <seconds>] -- <arguments for flutter>"',
  );
  exit(2);
}
