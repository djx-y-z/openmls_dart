import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as build_hook;

/// On a line of its own, so that no other line's length depends on it.
const _packageName = 'openmls';

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

  group('localBuildDirectory', () {
    String? directoryFor(
      OS targetOS,
      Architecture targetArchitecture, {
      IOSSdk? iosSdk,
    }) => build_hook.localBuildDirectory(
      targetOS: targetOS,
      targetArchitecture: targetArchitecture,
      iosSdk: iosSdk,
      hostOS: OS.macOS,
      hostArchitecture: Architecture.arm64,
    );

    test('the host reads the directory make build writes', () {
      expect(
        directoryFor(OS.macOS, Architecture.arm64),
        'rust/target/release/',
      );
    });

    test('another architecture of the host OS is a cross build', () {
      // `flutter build macos` builds both architectures. The host's library in
      // the other slice is an architecture error, so it must not read it.
      expect(
        directoryFor(OS.macOS, Architecture.x64),
        'rust/target/x86_64-apple-darwin/release/',
      );
    });

    test('a device or a simulator never reads the host build', () {
      for (final directory in [
        directoryFor(OS.iOS, Architecture.arm64, iosSdk: IOSSdk.iPhoneOS),
        directoryFor(
          OS.iOS,
          Architecture.arm64,
          iosSdk: IOSSdk.iPhoneSimulator,
        ),
        directoryFor(OS.android, Architecture.arm64),
      ]) {
        expect(directory, isNot('rust/target/release/'));
      }
    });

    test('iOS device and simulator do not share a directory', () {
      // They share the OS and, on Apple silicon, the architecture. A device
      // library in a simulator is rejected by dyld at launch.
      expect(
        directoryFor(OS.iOS, Architecture.arm64, iosSdk: IOSSdk.iPhoneOS),
        'rust/target/aarch64-apple-ios/release/',
      );
      expect(
        directoryFor(
          OS.iOS,
          Architecture.arm64,
          iosSdk: IOSSdk.iPhoneSimulator,
        ),
        'rust/target/aarch64-apple-ios-sim/release/',
      );
      expect(
        directoryFor(OS.iOS, Architecture.x64, iosSdk: IOSSdk.iPhoneSimulator),
        'rust/target/x86_64-apple-ios/release/',
      );
    });

    test('every Android ABI has the directory cargo-ndk writes', () {
      expect(
        directoryFor(OS.android, Architecture.arm64),
        'rust/target/aarch64-linux-android/release/',
      );
      expect(
        directoryFor(OS.android, Architecture.arm),
        'rust/target/armv7-linux-androideabi/release/',
      );
      expect(
        directoryFor(OS.android, Architecture.x64),
        'rust/target/x86_64-linux-android/release/',
      );
    });

    test('names the triples build-openmls.yml builds', () {
      // A name here the release does not use is a directory no make target
      // ever writes, and the hook would quietly download instead.
      final workflow = File(
        '.github/workflows/build-$_packageName.yml',
      ).readAsStringSync();
      for (final (os, arch, sdk) in [
        (OS.android, Architecture.arm64, null),
        (OS.android, Architecture.arm, null),
        (OS.android, Architecture.x64, null),
        (OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS),
        (OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator),
        (OS.iOS, Architecture.x64, IOSSdk.iPhoneSimulator),
        (OS.macOS, Architecture.x64, null),
        (OS.linux, Architecture.arm64, null),
        (OS.linux, Architecture.x64, null),
        (OS.windows, Architecture.x64, null),
      ]) {
        final triple = directoryFor(os, arch, iosSdk: sdk)!.split('/')[2];
        expect(workflow, contains(triple), reason: '$os $arch $sdk');
      }
    });

    test('a target with no release has no directory', () {
      expect(directoryFor(OS.windows, Architecture.arm64), isNull);
      expect(directoryFor(OS.android, Architecture.riscv64), isNull);
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

  group('downloads', () {
    test('pause a minute in all before the build gives up', () {
      const delays = build_hook.downloadRetryDelays;
      expect(delays, hasLength(5));
      for (var i = 1; i < delays.length; i++) {
        expect(delays[i], greaterThanOrEqualTo(delays[i - 1]));
      }
      expect(
        delays.fold(Duration.zero, (a, b) => a + b),
        equals(const Duration(minutes: 1)),
      );
    });

    test('cannot skip the checksum', () {
      // Hook runners give a hook only a fixed list of environment variables,
      // so the OPENMLS_ALLOW_UNVERIFIED_DOWNLOAD this hook used to read never
      // reached it, on any SDK. Nothing that reads one is to come back.
      final source = File('hook/build.dart').readAsStringSync();
      expect(source, isNot(contains('ALLOW_UNVERIFIED')));
      expect(source, isNot(contains('Platform.environment')));
    });

    // Against a server on this machine that answers with [statuses] in turn,
    // the last of them from then on, and with [body] when the status is 200.
    final noPauses = List.filled(5, Duration.zero);
    HttpServer? server;
    late String base;
    late int requests;
    late Directory dir;

    Future<void> serve(List<int> statuses, [String body = '']) async {
      requests = 0;
      final s = server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${s.address.address}:${s.port}';
      s.listen((request) async {
        final status =
            statuses[requests < statuses.length
                ? requests
                : statuses.length - 1];
        requests++;
        request.response
          ..statusCode = status
          ..write(status == 200 ? body : '');
        await request.response.close();
      });
    }

    setUp(() => dir = Directory.systemTemp.createTempSync('hook_download'));
    tearDown(() async {
      await server?.close(force: true);
      server = null;
      dir.deleteSync(recursive: true);
    });

    Matcher failsWith(String text) => throwsA(
      isA<build_hook.HookException>().having(
        (e) => e.message,
        'message',
        contains(text),
      ),
    );

    test('are tried again after a 5xx, and succeed', () async {
      await serve([503, 502, 200], 'library');
      final file = File('${dir.path}/archive');
      await build_hook.downloadWithRetry(
        '$base/archive',
        file,
        delays: noPauses,
      );
      expect(file.readAsStringSync(), equals('library'));
      expect(requests, equals(3));
    });

    test('stop at a 404', () async {
      await serve([404]);
      await expectLater(
        build_hook.downloadWithRetry(
          '$base/archive',
          File('${dir.path}/archive'),
          delays: noPauses,
        ),
        failsWith('HTTP 404'),
      );
      expect(requests, equals(1));
    });

    test('give up after the last try, and say how many', () async {
      await serve([503]);
      await expectLater(
        build_hook.downloadWithRetry(
          '$base/archive',
          File('${dir.path}/archive'),
          delays: noPauses,
        ),
        failsWith('after 6 attempts'),
      );
      expect(requests, equals(6));
    });

    test('do not try again a file they cannot write', () async {
      await serve([200], 'library');
      await expectLater(
        build_hook.downloadWithRetry(
          '$base/archive',
          File('${dir.path}/missing/archive'),
          delays: noPauses,
        ),
        failsWith('Could not write'),
      );
      expect(requests, equals(1));
    });

    group('checksum', () {
      const hash =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      Future<String> resolve() => build_hook.resolveExpectedChecksum(
        base,
        '8.0.0',
        'crate-8.0.0-macos-arm64.tar.gz',
        delays: noPauses,
      );

      test('is the one the file gives the archive', () async {
        await serve([200], '$hash  crate-8.0.0-macos-arm64.tar.gz\n');
        expect(await resolve(), equals(hash));
      });

      test('refuses an archive the file has no entry for', () async {
        await serve([200], '$hash  crate-8.0.0-linux-x64.tar.gz\n');
        await expectLater(resolve(), failsWith('has no entry'));
      });

      test('refuses a page that is not a checksums file', () async {
        await serve([200], '<html><body>Sign in to continue</body></html>');
        await expectLater(resolve(), failsWith('not a checksums file'));
        expect(requests, equals(1));
      });

      test('refuses to go on when the file cannot be had', () async {
        await serve([503]);
        await expectLater(
          resolve(),
          failsWith('Refusing to use an unverified native library'),
        );
        expect(requests, equals(6));
      });
    });
  });
}
