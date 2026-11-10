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

import 'capabilities/app.dart';
import 'capabilities/ciphersuites.dart';
import 'capabilities/credentials.dart';
import 'capabilities/groups.dart';
import 'capabilities/init.dart';
import 'capabilities/key_packages.dart';
import 'capabilities/keys.dart';
import 'capabilities/membership.dart';
import 'capabilities/messages.dart';
import 'capabilities/past_epochs.dart';
import 'capabilities/proposals.dart';
import 'capabilities/secure_bytes.dart';
import 'capabilities/state.dart';
import 'capabilities/storage.dart';
import 'support/harness.dart';

void main() => declareCapabilities(
  initialize: Openmls.init,
  capabilities: () {
    initCapabilities();
    keyCapabilities();
    credentialCapabilities();
    keyPackageCapabilities();
    groupCapabilities();
    stateCapabilities();
    membershipCapabilities();
    proposalCapabilities();
    messageCapabilities();
    pastEpochCapabilities();
    storageCapabilities();
    ciphersuiteCapabilities();
    secureBytesCapabilities();
    // Last: the app's `dispose` calls `Openmls.cleanup()`.
    appCapabilities();
  },
);
