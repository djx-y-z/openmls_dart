// What `flutter drive` runs on the host: it waits for the app to finish
// integration_test/openmls_test.dart and turns the outcome into an exit code.
// `make test-example-web` and the profile-mode runs go through here.
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  // So that the callback below runs on a failure too: the app has answered
  // either way, and that is what tells a failed test from a run that never got
  // that far.
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    // `make test-example-ci` looks for this line, in
    // scripts/src/example_run.dart, which a test keeps the same as this one.
    stdout.writeln('The app handed its results over.');
    // The binding counts only `testWidgets`, and a suite that never got to run
    // one reports "all tests passed" with nothing behind it. So the suite's last
    // test leaves this number, and its absence fails the run. A failed run
    // leaves none either: its last test does not get that far.
    final capabilities = data?['capabilities'];
    if (capabilities is! int || capabilities < 1) {
      stderr.writeln(
        'The suite did not report that every capability ran (got: $data).',
      );
      exit(1);
    }
    stdout.writeln('$capabilities capabilities passed.');
  },
);
