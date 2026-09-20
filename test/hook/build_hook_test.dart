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

  group('local WASM crate stamp', () {
    // The hook prefers a local `rust/target/wasm32/` build over the released
    // module, so this stamp is the only thing standing between a developer and
    // a silently stale module on the web. `rustContentHash` does not cover it:
    // that value compares the FFI surface, which a patch release leaves
    // byte-identical while the vendored native code moves underneath it.
    test('accepts a build stamped with the same crate version', () {
      expect(
        build_hook.localWasmMatchesCrate(stamped: '1.5.0', version: '1.5.0'),
        isTrue,
      );
    });

    test('rejects a build stamped with another crate version', () {
      expect(
        build_hook.localWasmMatchesCrate(stamped: '1.4.0', version: '1.5.0'),
        isFalse,
      );
    });

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

    test('tolerates the trailing newline `make build-web` actually writes', () {
      // The target stamps with `grep | sed > file`, which terminates the line.
      // A check that compared raw contents would reject every real build.
      expect(
        build_hook.localWasmMatchesCrate(stamped: '1.5.0\n', version: '1.5.0'),
        isTrue,
      );
    });

    test('readLocalWasmStamp returns null when the stamp is absent', () {
      final dir = Directory.systemTemp.createTempSync('wasm_stamp_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(build_hook.readLocalWasmStamp(dir), isNull);
    });

    test('readLocalWasmStamp reads and trims the stamp', () {
      final dir = Directory.systemTemp.createTempSync('wasm_stamp_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/${build_hook.localWasmStampName}',
      ).writeAsStringSync('1.5.0\n');
      expect(build_hook.readLocalWasmStamp(dir), equals('1.5.0'));
    });
  });
}
