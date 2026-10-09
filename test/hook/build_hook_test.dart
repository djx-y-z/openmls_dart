import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as build_hook;

void main() {
  group('downloadCacheSubdir', () {
    test('distinguishes iOS device from iOS simulator', () {
      final device = build_hook.downloadCacheSubdir(
        version: '1.5.0',
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        iosSdk: IOSSdk.iPhoneOS,
      );
      final simulator = build_hook.downloadCacheSubdir(
        version: '1.5.0',
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        iosSdk: IOSSdk.iPhoneSimulator,
      );

      expect(
        device,
        isNot(equals(simulator)),
        reason:
            'iOS device and simulator builds share targetOS and '
            'targetArchitecture on Apple-silicon hosts. If they also share '
            'a cache key, whichever platform builds first poisons the cache '
            'for the other and dyld rejects the binary at runtime '
            "(incompatible platform: have 'iOS-simulator', need 'iOS').",
      );
    });

    test('distinguishes crate versions', () {
      String subdirFor(String version) => build_hook.downloadCacheSubdir(
        version: version,
        targetOS: OS.macOS,
        targetArchitecture: Architecture.arm64,
      );

      expect(
        subdirFor('1.4.0'),
        isNot(equals(subdirFor('1.5.0'))),
        reason: 'A version bump must not reuse a previously cached binary.',
      );
    });

    test('distinguishes architectures', () {
      final arm64 = build_hook.downloadCacheSubdir(
        version: '1.5.0',
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        iosSdk: IOSSdk.iPhoneSimulator,
      );
      final x64 = build_hook.downloadCacheSubdir(
        version: '1.5.0',
        targetOS: OS.iOS,
        targetArchitecture: Architecture.x64,
        iosSdk: IOSSdk.iPhoneSimulator,
      );

      expect(arm64, isNot(equals(x64)));
    });

    test('matches the release artifact identity', () {
      expect(
        build_hook.downloadCacheSubdir(
          version: '1.5.0',
          targetOS: OS.iOS,
          targetArchitecture: Architecture.arm64,
          iosSdk: IOSSdk.iPhoneOS,
        ),
        '1.5.0-ios-device-arm64',
      );
      expect(
        build_hook.downloadCacheSubdir(
          version: '1.5.0',
          targetOS: OS.iOS,
          targetArchitecture: Architecture.arm64,
          iosSdk: IOSSdk.iPhoneSimulator,
        ),
        '1.5.0-ios-simulator-arm64',
      );
      expect(
        build_hook.downloadCacheSubdir(
          version: '1.5.0',
          targetOS: OS.android,
          targetArchitecture: Architecture.arm64,
        ),
        '1.5.0-android-arm64-v8a',
      );
    });
  });

  group('local build crate stamp', () {
    // The hook prefers a local build over the released one, so the stamp is
    // the only thing standing between a developer and a silently stale
    // library or module. `rustContentHash` does not cover it: that value
    // hashes only the bridged functions' names, which a patch release leaves
    // unchanged while the vendored native code moves underneath them.
    test('accepts a build stamped with the same crate version', () {
      expect(
        build_hook.localBuildMatchesCrate(stamped: '1.5.0', version: '1.5.0'),
        isTrue,
      );
    });

    test('rejects a build stamped with another crate version', () {
      expect(
        build_hook.localBuildMatchesCrate(stamped: '1.4.0', version: '1.5.0'),
        isFalse,
      );
    });

<<<<<<< before updating
    test(
      'rejects an UNSTAMPED build, which is every one built before this',
      () {
        // The case that motivated the check: a wasm directory that predates the
        // stamp carries no version at all and used to be served regardless.
        expect(
          build_hook.localWasmMatchesCrate(stamped: null, version: '1.5.0'),
          isFalse,
        );
      },
    );
=======
    test('rejects an UNSTAMPED build, which is every one built before this', () {
      // The case that motivated the check: a build directory that predates
      // its stamp carries no version at all and used to be used regardless.
      expect(
        build_hook.localBuildMatchesCrate(stamped: null, version: '1.5.0'),
        isFalse,
      );
    });
>>>>>>> after updating

    test('tolerates the trailing newline the make targets actually write', () {
      // `make build` and `make build-web` stamp with `grep | sed > file`, which
      // terminates the line. A check that compared raw contents would reject
      // every real build.
      expect(
        build_hook.localBuildMatchesCrate(stamped: '1.5.0\n', version: '1.5.0'),
        isTrue,
      );
    });

    test('readLocalBuildStamp returns null when the stamp is absent', () {
      final dir = Directory.systemTemp.createTempSync('build_stamp_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(build_hook.readLocalBuildStamp(dir), isNull);
    });

    test('readLocalBuildStamp reads and trims the stamp', () {
      final dir = Directory.systemTemp.createTempSync('build_stamp_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/${build_hook.localBuildStampName}',
      ).writeAsStringSync('1.5.0\n');
      expect(build_hook.readLocalBuildStamp(dir), equals('1.5.0'));
    });
  });
}
