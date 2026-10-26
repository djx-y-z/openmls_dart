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

    test(
      'rejects an UNSTAMPED build, which is every one built before this',
      () {
        // The case that motivated the check: a build directory that predates
        // its stamp carries no version at all and used to be used regardless.
        expect(
          build_hook.localBuildMatchesCrate(stamped: null, version: '1.5.0'),
          isFalse,
        );
      },
    );

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

  group('local build lock copy', () {
    // An upstream update moves rust/Cargo.lock under an unchanged crate
    // version, so the version stamp alone accepts a build made before it.
    const lock =
        '# This file is automatically @generated by Cargo.\n'
        'version = 4\n';

    test('accepts a build made from the lock file the tree has now', () {
      expect(
        build_hook.localBuildMatchesLock(built: lock, current: lock),
        isTrue,
      );
    });

    test('rejects a build made from another lock file', () {
      expect(
        build_hook.localBuildMatchesLock(
          built: lock,
          current: '$lock[[package]]\nname = "moved"\n',
        ),
        isFalse,
      );
    });

    test(
      'rejects a build without the copy, which is every one made before it',
      () {
        expect(
          build_hook.localBuildMatchesLock(built: null, current: lock),
          isFalse,
        );
      },
    );

    test('rejects a build when the tree has no lock file at all', () {
      expect(
        build_hook.localBuildMatchesLock(built: lock, current: null),
        isFalse,
      );
    });

    test('compares exactly: a trailing newline is a difference', () {
      // `make build` copies the file with cp, so the copy is byte-identical
      // to what it was made from; nothing here should need normalizing.
      expect(
        build_hook.localBuildMatchesLock(built: lock, current: '$lock\n'),
        isFalse,
      );
    });

    test(
      'readIfPresent returns null for a missing file and the text otherwise',
      () {
        final dir = Directory.systemTemp.createTempSync('build_lock_test');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/${build_hook.localBuildLockName}');
        expect(build_hook.readIfPresent(file), isNull);
        file.writeAsStringSync(lock);
        expect(build_hook.readIfPresent(file), equals(lock));
      },
    );
  });
}
