// This project's half of `make verify-example-coverage`: which bridged functions
// the example's integration tests are excused from calling, and how much of the
// hand-written code they have to run. The rules that read these are the
// template's, in example_coverage.dart.
//
// The template writes this file once and never again, so what is in it is this
// project's to keep current: a new bridged function gets a test under
// example/integration_test/capabilities/, or a line here saying why not.
library;

/// Bridged functions the tests do not call, and why that is right.
///
/// Keys are what follows `crateApi` in `lib/src/rust/frb_generated.dart`. A name
/// that no longer exists there is reported rather than ignored, so this list
/// cannot quietly outlive what it excuses.
const uncalledOnPurpose = {
  'InitInitOpenmls':
      'lib/src/rust/api/init.dart is not exported by the package.',
  'InitIsOpenmlsInitialized':
      'lib/src/rust/api/init.dart is not exported by the package.',
};

/// The share of hand-written lines the tests have to execute. Not a target: the
/// misses that are fine, a `catch` for a library that cannot load and the like,
/// add up to well under this. It is there because a whole new class on top of
/// already-covered bridged functions moves nothing the check above can see.
const handWrittenFloor = 0.95;
