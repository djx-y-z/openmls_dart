import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// A config identical to the default except for how many past epochs it keeps.
MlsGroupConfig configKeeping(int maxPastEpochs) => MlsGroupConfig(
  ciphersuite: ciphersuite,
  wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
  useRatchetTreeExtension: true,
  maxPastEpochs: maxPastEpochs,
  paddingSize: 0,
  senderRatchetMaxOutOfOrder: 5,
  senderRatchetMaxForwardDistance: 1000,
  numberOfResumptionPsks: 0,
);

void main() {
  late MlsEngine alice;
  late MlsEngine bob;
  late TestIdentity aliceId;
  late TestIdentity bobId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    alice = await createTestEngine();
    bob = await createTestEngine();
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');
  });

  /// Alice creates a group on [config] and Bob joins it. Both end at epoch 1.
  Future<Uint8List> formGroup({
    MlsGroupConfig? config,
    MlsEngine? engine,
  }) async {
    final host = engine ?? alice;
    final cfg = config ?? defaultConfig();
    final created = await host.createGroup(
      config: cfg,
      signerBytes: aliceId.signerBytes,
      credentialIdentity: aliceId.credentialIdentity,
      signerPublicKey: aliceId.publicKey,
    );
    final bobKp = await bob.createKeyPackage(
      ciphersuite: ciphersuite,
      signerBytes: bobId.signerBytes,
      credentialIdentity: bobId.credentialIdentity,
      signerPublicKey: bobId.publicKey,
    );
    final added = await host.addMembers(
      groupIdBytes: created.groupId,
      signerBytes: aliceId.signerBytes,
      keyPackagesBytes: [bobKp.keyPackageBytes],
    );
    await host.mergePendingCommit(groupIdBytes: created.groupId);
    await bob.joinGroupFromWelcome(
      config: cfg,
      welcomeBytes: added.welcome,
      signerBytes: bobId.signerBytes,
    );
    return created.groupId;
  }

  /// An application message from Bob, encrypted under whatever epoch he is in.
  Future<Uint8List> bobSays(Uint8List gid, String text) async {
    final msg = await bob.createMessage(
      groupIdBytes: gid,
      signerBytes: bobId.signerBytes,
      message: Uint8List.fromList(utf8.encode(text)),
    );
    return msg.ciphertext;
  }

  /// Moves Alice one epoch on. Bob follows only when asked, so that a message
  /// he wrote before the commit stays a message from a past epoch.
  Future<void> aliceAdvances(
    Uint8List gid, {
    bool withBob = false,
    MlsEngine? engine,
  }) async {
    final host = engine ?? alice;
    final commit = await host.selfUpdate(
      groupIdBytes: gid,
      signerBytes: aliceId.signerBytes,
    );
    await host.mergePendingCommit(groupIdBytes: gid);
    if (withBob) {
      await bob.processMessage(groupIdBytes: gid, messageBytes: commit.commit);
    }
  }

  group('the policy', () {
    test('a new group keeps no past epochs', () async {
      final gid = await formGroup();

      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isFalse);
      expect(policy.maxEpochs, equals(0));
    });

    test('the config field and the policy are one setting', () async {
      final gid = await formGroup(config: configKeeping(5));

      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isFalse);
      expect(policy.maxEpochs, equals(5));
    });

    test('keepAll is written and read back', () async {
      final gid = await formGroup();

      await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);

      // Every call loads the group from the database, so reading it back at
      // all is already a round trip through storage.
      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isTrue);
    });

    test('a number is written and read back', () async {
      final gid = await formGroup();

      await alice.setPastEpochDeletionPolicyMaxEpochs(
        groupIdBytes: gid,
        maxEpochs: 3,
      );

      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isFalse);
      expect(policy.maxEpochs, equals(3));
    });

    test('4294967295 is refused and changes nothing', () async {
      final gid = await formGroup();
      await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);

      // That value is what OpenMLS stores to mean keep-all where usize is 32
      // bits, so accepting it would make two settings one stored value on the
      // Web and two on a desktop.
      await expectLater(
        () => alice.setPastEpochDeletionPolicyMaxEpochs(
          groupIdBytes: gid,
          maxEpochs: 4294967295,
        ),
        throwsA(isA<Object>()),
      );

      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isTrue);
    });

    test('setConfiguration resets the policy', () async {
      final gid = await formGroup();
      await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);

      // Asserted before the reset as well as after it: without this the test
      // would pass just as happily if the setter had never worked at all.
      final set = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(set.keepAll, isTrue);

      // MlsGroupConfig carries maxPastEpochs, which is the same setting, and
      // the struct has no "leave as is" — so this silently undoes keepAll.
      // Documented on setConfiguration, on the setter and on the field; pinned
      // here so the documentation is measured rather than asserted.
      await alice.setConfiguration(groupIdBytes: gid, config: defaultConfig());

      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isFalse);
      expect(policy.maxEpochs, equals(0));
    });
  });

  group('messages from a past epoch', () {
    test('are lost when no past epochs are kept', () async {
      final gid = await formGroup();
      final fromEpoch1 = await bobSays(gid, 'sent before the commit');

      await aliceAdvances(gid);

      expect(
        () => alice.processMessage(groupIdBytes: gid, messageBytes: fromEpoch1),
        throwsA(isA<Object>()),
      );
    });

    test('decrypt under keepAll after the epoch advances', () async {
      final gid = await formGroup();
      await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);

      final fromEpoch1 = await bobSays(gid, 'hello from epoch 1');
      await aliceAdvances(gid);

      final processed = await alice.processMessage(
        groupIdBytes: gid,
        messageBytes: fromEpoch1,
      );
      expect(
        processed.applicationMessage,
        equals(Uint8List.fromList(utf8.encode('hello from epoch 1'))),
      );
    });

    test('decrypt under a number as well as under keepAll', () async {
      final gid = await formGroup();
      await alice.setPastEpochDeletionPolicyMaxEpochs(
        groupIdBytes: gid,
        maxEpochs: 1,
      );

      final fromEpoch1 = await bobSays(gid, 'one epoch of slack');
      await aliceAdvances(gid);

      final processed = await alice.processMessage(
        groupIdBytes: gid,
        messageBytes: fromEpoch1,
      );
      expect(
        processed.applicationMessage,
        equals(Uint8List.fromList(utf8.encode('one epoch of slack'))),
      );
    });

    test('survive closing and reopening the database', () async {
      // The in-memory database used elsewhere here is still SQLite, so the
      // policy and the secrets already cross serialization on every call. What
      // only a file can show is that they outlive the connection itself.
      final dir = Directory.systemTemp.createTempSync('openmls_past_epoch');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dbPath = '${dir.path}/alice.db';
      final dbKey = testEncryptionKey();

      var aliceFs = await MlsEngine.create(
        dbPath: dbPath,
        encryptionKey: dbKey,
      );
      final gid = await formGroup(engine: aliceFs);
      await aliceFs.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);

      final fromEpoch1 = await bobSays(gid, 'written before the reopen');
      await aliceAdvances(gid, engine: aliceFs);

      await aliceFs.close();
      aliceFs = await MlsEngine.create(dbPath: dbPath, encryptionKey: dbKey);
      addTearDown(aliceFs.close);

      final policy = await aliceFs.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isTrue);

      final processed = await aliceFs.processMessage(
        groupIdBytes: gid,
        messageBytes: fromEpoch1,
      );
      expect(
        processed.applicationMessage,
        equals(Uint8List.fromList(utf8.encode('written before the reopen'))),
      );
    });
  });

  group('deleting past epoch secrets', () {
    /// A group under keepAll, one epoch behind, with two messages left in the
    /// epoch that just passed.
    Future<(Uint8List, Uint8List, Uint8List)> oneEpochBehind() async {
      final gid = await formGroup();
      await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);
      final first = await bobSays(gid, 'first');
      final second = await bobSays(gid, 'second');
      await aliceAdvances(gid);
      return (gid, first, second);
    }

    test('deleteAll makes them unreadable, and keeps the policy', () async {
      final (gid, first, second) = await oneEpochBehind();

      // Readable to begin with...
      final before = await alice.processMessage(
        groupIdBytes: gid,
        messageBytes: first,
      );
      expect(before.applicationMessage, isNotNull);

      await alice.deleteAllPastEpochSecrets(groupIdBytes: gid);

      // ...and gone afterwards, though the policy itself is untouched.
      expect(
        () => alice.processMessage(groupIdBytes: gid, messageBytes: second),
        throwsA(isA<Object>()),
      );
      final policy = await alice.pastEpochDeletionPolicy(groupIdBytes: gid);
      expect(policy.keepAll, isTrue);
    });

    test(
      'deleteAll clears what is there but does not stop accumulation',
      () async {
        // "Delete all past epoch secrets" is a sweep, not a switch: under
        // keepAll the very next commit starts recording them again. Documented
        // on the method; measured here.
        final gid = await formGroup();
        await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);
        await aliceAdvances(gid, withBob: true);

        await alice.deleteAllPastEpochSecrets(groupIdBytes: gid);

        // Bob speaks in the epoch they now share, then Alice moves on again.
        final fromEpoch2 = await bobSays(gid, 'after the sweep');
        await aliceAdvances(gid);

        final processed = await alice.processMessage(
          groupIdBytes: gid,
          messageBytes: fromEpoch2,
        );
        expect(
          processed.applicationMessage,
          equals(Uint8List.fromList(utf8.encode('after the sweep'))),
        );
      },
    );

    test(
      'withoutTimestamps deletes nothing when every entry is dated',
      () async {
        final (gid, first, _) = await oneEpochBehind();

        // Everything this version records carries a timestamp, so the migration
        // step is a no-op here — which is the half of its behaviour a deployment
        // that never ran 0.8.1 will see.
        await alice.deletePastEpochSecretsWithoutTimestamps(groupIdBytes: gid);

        final processed = await alice.processMessage(
          groupIdBytes: gid,
          messageBytes: first,
        );
        expect(processed.applicationMessage, isNotNull);
      },
    );

    test('olderThan keeps what is younger than the window', () async {
      final (gid, first, _) = await oneEpochBehind();

      await alice.deletePastEpochSecretsOlderThan(
        groupIdBytes: gid,
        seconds: BigInt.from(3600),
      );

      final processed = await alice.processMessage(
        groupIdBytes: gid,
        messageBytes: first,
      );
      expect(processed.applicationMessage, isNotNull);
    });

    test('before a future instant deletes everything', () async {
      final (gid, first, _) = await oneEpochBehind();

      final anHourFromNow =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      await alice.deletePastEpochSecretsBefore(
        groupIdBytes: gid,
        unixSeconds: BigInt.from(anHourFromNow),
      );

      expect(
        () => alice.processMessage(groupIdBytes: gid, messageBytes: first),
        throwsA(isA<Object>()),
      );
    });

    test('before refuses a millisecond count', () async {
      final (gid, first, _) = await oneEpochBehind();

      // The likeliest way to call it wrongly: Dart offers
      // millisecondsSinceEpoch first, and that number lands past the year 9999.
      await expectLater(
        () => alice.deletePastEpochSecretsBefore(
          groupIdBytes: gid,
          unixSeconds: BigInt.from(DateTime.now().millisecondsSinceEpoch),
        ),
        throwsA(isA<Object>()),
      );

      // Refused before any database work: the secrets are still there.
      final processed = await alice.processMessage(
        groupIdBytes: gid,
        messageBytes: first,
      );
      expect(processed.applicationMessage, isNotNull);
    });

    test('maxPastEpochs caps what survives a deletion', () async {
      final gid = await formGroup();
      await alice.setPastEpochDeletionPolicyKeepAll(groupIdBytes: gid);

      final fromEpoch1 = await bobSays(gid, 'from epoch 1');
      await aliceAdvances(gid, withBob: true);
      final fromEpoch2 = await bobSays(gid, 'from epoch 2');
      await aliceAdvances(gid);

      // Every entry is dated, so the selective part deletes nothing and the
      // cap is what acts: of the two past epochs, only the newer survives.
      await alice.deletePastEpochSecretsWithoutTimestamps(
        groupIdBytes: gid,
        maxPastEpochs: 1,
      );

      final processed = await alice.processMessage(
        groupIdBytes: gid,
        messageBytes: fromEpoch2,
      );
      expect(
        processed.applicationMessage,
        equals(Uint8List.fromList(utf8.encode('from epoch 2'))),
      );
      expect(
        () => alice.processMessage(groupIdBytes: gid, messageBytes: fromEpoch1),
        throwsA(isA<Object>()),
      );
    });
  });
}
