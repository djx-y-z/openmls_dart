// Every capability of the package, inside this running Flutter app.
//
// `test/` checks what the library does; it runs on the Dart VM, with a library
// the VM found for itself. This checks that the same library gets there through
// what a consumer's app goes through — the build hook, the platform's way of
// bundling a native library, the loader, and on the web the wasm module — and
// then does its job on that platform's architecture.
//
// One file, because every test file is its own build, install and launch on a
// device. The families live under capabilities/, which is not named *_test.dart
// so that `flutter test integration_test` does not take them for entry points.
//
//   make test-example ARGS="-d macos"      a desktop, a simulator or an emulator
//   make test-example-web                  the web, in a real browser
//
// When the package gains a capability, it goes here too:
// `make verify-example-coverage` fails on a bridged function nothing here calls.
//
// This file and capabilities/ are this project's: the template wrote them once
// and leaves them alone. support/harness.dart is the template's.
import 'package:openmls/openmls.dart';

import 'capabilities/init.dart';
import 'support/harness.dart';

void main() => declareCapabilities(
  initialize: Openmls.init,
  capabilities: () {
    initCapabilities();
  },
);
