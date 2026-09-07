import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// The margin OpenMLS extends `notBefore` into the past by, to tolerate skewed
/// clocks. Named here because the arithmetic below is otherwise unreadable.
final _skewMargin = BigInt.from(60 * 60);

void main() {
  late MlsEngine alice;
  late TestIdentity aliceId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    alice = await createTestEngine();
    aliceId = TestIdentity.create('alice');
  });

  Future<Uint8List> keyPackage({BigInt? lifetimeSeconds}) async {
    final result = lifetimeSeconds == null
        ? await alice.createKeyPackage(
            ciphersuite: ciphersuite,
            signerBytes: aliceId.signerBytes,
            credentialIdentity: aliceId.credentialIdentity,
            signerPublicKey: aliceId.publicKey,
          )
        : await alice.createKeyPackageWithOptions(
            ciphersuite: ciphersuite,
            signerBytes: aliceId.signerBytes,
            credentialIdentity: aliceId.credentialIdentity,
            signerPublicKey: aliceId.publicKey,
            options: KeyPackageOptions(
              lifetimeSeconds: lifetimeSeconds,
              lastResort: false,
            ),
          );
    return result.keyPackageBytes;
  }

  group('keyPackageLifetime', () {
    test('reads the window an explicit lifetime asked for', () async {
      final bytes = await keyPackage(lifetimeSeconds: BigInt.from(3600));
      final lifetime = keyPackageLifetime(keyPackageBytes: bytes);

      // `notBefore` is pushed one hour into the past for clock skew, so the
      // window is the requested lifetime plus that margin.
      expect(
        lifetime.notAfter - lifetime.notBefore,
        equals(BigInt.from(3600) + _skewMargin),
      );
    });

    test('reads the window of a default key package', () async {
      final lifetime = keyPackageLifetime(keyPackageBytes: await keyPackage());
      expect(lifetime.notAfter, greaterThan(lifetime.notBefore));
      // OpenMLS's default is 3 * 28 days plus the skew margin. Assert only that
      // it is generous, so an upstream tweak of the constant is not a failure
      // here.
      expect(
        lifetime.notAfter - lifetime.notBefore,
        greaterThan(BigInt.from(80 * 24 * 60 * 60)),
      );
    });

    test("this device's clock gates the read", () async {
      // `lifetimeSeconds: 0` makes `notAfter` equal to the moment of creation,
      // and OpenMLS treats `notAfter` as exclusive — so the key package is
      // already expired when it is handed back.
      final expired = await keyPackage(lifetimeSeconds: BigInt.zero);

      // This is the limitation the docstring states, measured rather than
      // asserted from reading upstream: reaching the window means validating
      // the key package, validation checks the lifetime against this device's
      // clock, and there is no way to skip that from outside the crate. So the
      // bounds of an expired package are unreachable, and checkLifetimeAt
      // cannot be used to rescue one.
      // Asserted on the message, not just on "it threw": a bare throw would
      // also be satisfied by an unrelated validation failure, and then the
      // measurement would not be of the clock at all. OpenMLS reports
      // `not_after` and its own `now` side by side, and they are equal here —
      // which is `notAfter` being exclusive, from the other direction.
      expect(
        () => keyPackageLifetime(keyPackageBytes: expired),
        throwsA(
          predicate(
            (Object e) =>
                e.toString().contains('Lifetime') &&
                e.toString().contains('not_after='),
            'names the lifetime that failed',
          ),
        ),
      );
    });

    test('rejects bytes that are not a key package', () {
      expect(
        () => keyPackageLifetime(
          keyPackageBytes: Uint8List.fromList([0xFF, 0xFF, 0xFF]),
        ),
        throwsA(isA<Object>()),
      );
      expect(
        () => keyPackageLifetime(keyPackageBytes: Uint8List(0)),
        throwsA(isA<Object>()),
      );
    });
  });

  group('checkLifetimeAt', () {
    final notBefore = BigInt.from(1000);
    final notAfter = BigInt.from(2000);

    LifetimeVerdict at(BigInt now) => checkLifetimeAt(
      notBefore: notBefore,
      notAfter: notAfter,
      nowUnixSeconds: now,
    );

    test('notBefore is inclusive', () {
      expect(at(notBefore).valid, isTrue);
      expect(at(notBefore).reason, isNull);
    });

    test('an instant before the window is not yet valid', () {
      final verdict = at(notBefore - BigInt.one);
      expect(verdict.valid, isFalse);
      expect(verdict.reason, isNotNull);
      expect(verdict.reason, contains('1000'));
    });

    test('notAfter is exclusive', () {
      expect(at(notAfter - BigInt.one).valid, isTrue);

      final verdict = at(notAfter);
      expect(verdict.valid, isFalse);
      expect(verdict.reason, isNotNull);
      expect(verdict.reason, contains('2000'));
    });

    test('an instant after the window is expired', () {
      expect(at(notAfter + BigInt.from(86400)).valid, isFalse);
    });

    test('an unrepresentable instant is an error, not a verdict', () {
      // Past the year 9999. Rejected by an explicit cap rather than left to the
      // platform: native Unix keeps a timespec and would overflow, but
      // web_time's SystemTime on wasm32 is a bare Duration since the epoch and
      // would happily accept u64::MAX, so without the cap this same call would
      // be an error on a phone and a verdict on the Web.
      expect(
        () => checkLifetimeAt(
          notBefore: notBefore,
          notAfter: notAfter,
          nowUnixSeconds: BigInt.parse('18446744073709551615'),
        ),
        throwsA(isA<Object>()),
      );
    });

    test('the cap is at the end of year 9999, inclusive', () {
      final lastRepresentable = BigInt.from(253402300799);

      // The cap itself is accepted and answers as a verdict...
      final verdict = checkLifetimeAt(
        notBefore: notBefore,
        notAfter: notAfter,
        nowUnixSeconds: lastRepresentable,
      );
      expect(verdict.valid, isFalse);

      // ...and one second past it is the error.
      expect(
        () => checkLifetimeAt(
          notBefore: notBefore,
          notAfter: notAfter,
          nowUnixSeconds: lastRepresentable + BigInt.one,
        ),
        throwsA(isA<Object>()),
      );
    });
  });

  group('the two together', () {
    test(
      'a server clock can reject a package the device still accepts',
      () async {
        final bytes = await keyPackage(lifetimeSeconds: BigInt.from(3600));
        final lifetime = keyPackageLifetime(keyPackageBytes: bytes);

        // A server one second short of the end still accepts it...
        expect(
          checkLifetimeAt(
            notBefore: lifetime.notBefore,
            notAfter: lifetime.notAfter,
            nowUnixSeconds: lifetime.notAfter - BigInt.one,
          ).valid,
          isTrue,
        );

        // ...and a server whose clock runs an hour ahead of this device's does
        // not, even though the device just validated the same package.
        final aheadByAnHour = checkLifetimeAt(
          notBefore: lifetime.notBefore,
          notAfter: lifetime.notAfter,
          nowUnixSeconds: lifetime.notAfter + BigInt.one,
        );
        expect(aheadByAnHour.valid, isFalse);
        expect(aheadByAnHour.reason, isNotNull);
      },
    );
  });
}
