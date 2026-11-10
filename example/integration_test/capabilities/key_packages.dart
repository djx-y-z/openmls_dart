import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';
import '../support/refs.dart';

/// The last_resort extension type (draft-ietf-mls-extensions).
const _lastResortExtension = 0x000a;

void keyPackageCapabilities() {
  group('key packages', () {
    capability('a key package carries the lifetime it was asked for, and '
        'whoever holds it can judge it by their own clock', () async {
      final alice = await Party.create('alice');
      final hour = BigInt.from(3600);
      final package = await alice.engine.createKeyPackageWithOptions(
        ciphersuite: defaultSuite,
        signerBytes: alice.signer,
        credentialIdentity: alice.identity,
        signerPublicKey: alice.publicKey,
        options: KeyPackageOptions(lifetimeSeconds: hour, lastResort: false),
      );

      final lifetime = keyPackageLifetime(
        keyPackageBytes: package.keyPackageBytes,
      );
      // OpenMLS starts the window an hour early, for clocks that run behind.
      expect(lifetime.notAfter - lifetime.notBefore, hour + hour);
      final now = BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000);
      expect(lifetime.notBefore, lessThanOrEqualTo(now));
      expect(lifetime.notAfter, greaterThan(now));

      LifetimeVerdict at(BigInt instant) => checkLifetimeAt(
        notBefore: lifetime.notBefore,
        notAfter: lifetime.notAfter,
        nowUnixSeconds: instant,
      );
      expect(at(now).valid, isTrue);
      expect(at(now).reason, isNull);
      expect(at(lifetime.notAfter - BigInt.one).valid, isTrue);
      // `notAfter` is exclusive, and an instant before `notBefore` is early.
      for (final instant in [
        lifetime.notAfter,
        lifetime.notBefore - BigInt.one,
      ]) {
        final verdict = at(instant);
        expect(verdict.valid, isFalse, reason: '$instant');
        expect(verdict.reason, isNotNull);
      }
    });

    capability('a key package is used up by the join it makes, unless it is '
        'a last resort', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');

      final once = await bob.keyPackage();
      final lastResort = (await carol.engine.createKeyPackageWithOptions(
        ciphersuite: defaultSuite,
        signerBytes: carol.signer,
        credentialIdentity: carol.identity,
        signerPublicKey: carol.publicKey,
        options: KeyPackageOptions(
          lastResort: true,
          // A key package's extensions have to be among its leaf's
          // capabilities (RFC 9420 §10.1), and the default ones do not list
          // last_resort: without this, whoever adds Carol refuses the package.
          capabilities: MlsCapabilities(
            versions: Uint16List(0),
            ciphersuites: Uint16List(0),
            extensions: Uint16List.fromList([_lastResortExtension]),
            proposals: Uint16List(0),
            credentials: Uint16List(0),
          ),
        ),
      )).keyPackageBytes;

      // Each of them joins two different groups of Alice's on the same key
      // package.
      final welcomes = <Uint8List>[];
      final groups = <Uint8List>[];
      for (var i = 0; i < 2; i++) {
        final group = await alice.createGroup();
        final added = await alice.engine.addMembers(
          groupIdBytes: group,
          signerBytes: alice.signer,
          keyPackagesBytes: [once, lastResort],
        );
        await alice.engine.mergePendingCommit(groupIdBytes: group);
        groups.add(group);
        welcomes.add(added.welcome);
      }

      expect(await bob.join(welcomes[0]), groups[0]);
      await expectLater(
        bob.join(welcomes[1]),
        throwsA(anything),
        reason: 'the first join deleted the key package it used',
      );
      expect(await carol.join(welcomes[0]), groups[0]);
      expect(await carol.join(welcomes[1]), groups[1]);
    });

    capability('a key package deleted by its reference can no longer be '
        'joined with', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');
      final deleted = await bob.keyPackage();
      final kept = await carol.keyPackage();

      await bob.engine.deleteKeyPackage(
        keyPackageRefBytes: keyPackageRef(deleted),
      );

      final group = await alice.createGroup();
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [deleted, kept],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);

      await expectLater(bob.join(added.welcome), throwsA(anything));
      // The same Welcome, to a key package nobody deleted.
      expect(await carol.join(added.welcome), group);
    });

    capability('a reference that is no reference is refused', () async {
      final bob = await Party.create('bob');
      await expectLater(
        bob.engine.deleteKeyPackage(keyPackageRefBytes: [1, 2, 3]),
        throwsA(anything),
      );
    });
  });
}
