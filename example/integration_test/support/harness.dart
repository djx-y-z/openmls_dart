// The in-app half of what `make test-example-ci` judges a run by: how a
// capability is declared, the limit inside it, the watchdog's self-test, and the
// count the driver checks. The template keeps this file in step with the host's
// half, scripts/src/example_run.dart and test_driver/integration_test.dart, so
// a project changes its tests, not this.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

int _declared = 0;
int _ran = 0;

/// What every [capability] runs first, given to [declareCapabilities].
late Future<void> Function() _initialize;

/// How long one capability may take, measured inside its body.
const capabilityTimeout = Duration(minutes: 3);

/// Runs [body], and fails the test that runs it when [body] takes longer than
/// [limit].
///
/// Inside the body, as well as in `testWidgets(timeout:)`, because the two are
/// not the same failure. test_api's timeout ends the test from outside: under
/// `flutter drive` the host reads the binding's results, which that never
/// reaches, so the slow test is missing from the failures, and the body goes on
/// and can still count itself as having run. Thrown in here, it is the test's own
/// failure, on every runner.
Future<void> withinLimit(Duration limit, Future<void> Function() body) =>
    body().timeout(
      limit,
      onTimeout: () => throw TestFailure('Took longer than $limit.'),
    );

/// Declares the whole suite, from the entry point's `main`: the watchdog's
/// self-test first when the build asks for it, so that the run stops at once,
/// then [capabilities], which declares every [capability], then the check that
/// each of them ran.
///
/// [initialize] is the package's own initialization. Each capability runs it
/// first, inside its own limit, so that every one of them gets the library the
/// way an app does.
void declareCapabilities({
  required Future<void> Function() initialize,
  required void Function() capabilities,
}) {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  _initialize = initialize;
  if (hangOnPurpose) _capabilityThatHangs();
  capabilities();
  _capabilitiesAllRan(binding);
}

/// Declares one capability of the library, checked inside this running app.
///
/// `testWidgets` rather than `test`, and that is not a style choice. Under
/// `flutter drive` — the only way to run this suite on the web — the result the
/// host reads holds `testWidgets` outcomes only, so a plain `test` could fail
/// there with the run still green.
///
/// For the same reason it initializes here rather than in `setUpAll`: a
/// `setUpAll` that throws under `flutter drive` leaves no failure and no tests
/// behind, and the host reads that as success.
void capability(String description, Future<void> Function() body) {
  _declared++;
  testWidgets(
    description,
    (tester) async {
      await withinLimit(capabilityTimeout, () async {
        await _initialize();
        await body();
      });
      _ran++;
    },
    // A backstop only: the limit above fires first.
    timeout: Timeout(capabilityTimeout * 2),
  );
}

/// The define that builds [_capabilityThatHangs] into the app: only
/// `gh workflow run integration.yml -f hang=true` passes it.
const hangDefine = 'OPENMLS_EXAMPLE_HANG';

/// Whether this build carries [_capabilityThatHangs].
const hangOnPurpose = bool.fromEnvironment(hangDefine);

/// How long [_capabilityThatHangs] blocks the app: past the 8 minutes the
/// watchdog of `make test-example-ci` waits (`stallLimit` in
/// `scripts/src/example_run.dart`), so that it is the watchdog that ends it.
const hangFor = Duration(minutes: 12);

/// Declares a capability that blocks the app's isolate for [hangFor], as a call
/// that never returns would: the self-test of the watchdog. The jobs it runs in
/// fail, and should say that the app sent nothing for 8 minutes.
void _capabilityThatHangs() {
  capability('blocks the app on purpose, for the watchdog to stop', () async {
    final clock = Stopwatch()..start();
    // Meanwhile nothing else runs on the isolate: no timer, no frame, and no
    // word to the host.
    while (clock.elapsed < hangFor) {}
    fail(
      'Blocked the app for $hangFor, and nothing stopped it: the watchdog of '
      'make test-example-ci did not.',
    );
  });
}

/// Declares the check that every [capability] above it really ran, and hands
/// the count to `test_driver/integration_test.dart`. Declared last.
void _capabilitiesAllRan(IntegrationTestWidgetsFlutterBinding binding) {
  final declared = _declared;
  testWidgets('every capability above ran', (tester) async {
    expect(_ran, declared);
    binding.reportData = {'capabilities': _ran};
  });
}
