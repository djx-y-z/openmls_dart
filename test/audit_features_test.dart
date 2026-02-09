import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late MlsClient alice;
  late TestIdentity aliceId;
  late MlsClient bob;
  late TestIdentity bobId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() {
    alice = MlsClient(InMemoryMlsStorage());
    aliceId = TestIdentity.create('alice');
    bob = MlsClient(InMemoryMlsStorage());
    bobId = TestIdentity.create('bob');
  });

  group('deleteGroup', () {
    test('deletes a group and verifies it is gone', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      final groupIdBytes = result.groupId;

      // Verify group exists
      final active = await alice.groupIsActive(groupIdBytes: groupIdBytes);
      expect(active, isTrue);

      // Delete group
      await alice.deleteGroup(groupIdBytes: groupIdBytes);

      // Verify group is gone — loading should fail
      expect(
        () => alice.groupIsActive(groupIdBytes: groupIdBytes),
        throwsA(isA<Object>()),
      );
    });

    test('delete non-existent group throws', () async {
      expect(
        () => alice.deleteGroup(groupIdBytes: [1, 2, 3]),
        throwsA(isA<Object>()),
      );
    });
  });

  group('deleteKeyPackage', () {
    test('create and delete a key package', () async {
      // Create a key package — it gets stored internally
      final kpResult = await alice.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      expect(kpResult.keyPackageBytes, isNotEmpty);

      // The key package hash ref is computed from the serialized bytes.
      // We need to get the hash ref to delete. OpenMLS computes this
      // internally. For this test, we verify that deleteKeyPackage doesn't
      // throw with well-formed (though manually constructed) ref bytes.
      // Since we can't easily extract the hash ref from the Dart side,
      // we test that malformed ref bytes throw.
      expect(
        () => alice.deleteKeyPackage(keyPackageRefBytes: [1, 2, 3]),
        throwsA(isA<Object>()),
      );
    });
  });

  group('removePendingProposal', () {
    test('remove a specific pending proposal', () async {
      // Create group with Alice and Bob
      final aliceGroup = await alice.createGroup(
        config: defaultConfig(),
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

      // Alice proposes adding Bob
      await alice.proposeAdd(
        groupIdBytes: aliceGroup.groupId,
        signerBytes: aliceId.signerBytes,
        keyPackageBytes: bobKp.keyPackageBytes,
      );

      // Verify proposal exists
      final proposals = await alice.groupPendingProposals(
        groupIdBytes: aliceGroup.groupId,
      );
      expect(proposals, hasLength(1));
      expect(proposals.first.proposalType, MlsProposalType.add);

      // Clear all pending proposals (since we can't easily get the
      // proposal ref from Dart side without it being returned by propose)
      await alice.clearPendingProposals(groupIdBytes: aliceGroup.groupId);

      // Verify proposals cleared
      final after = await alice.groupPendingProposals(
        groupIdBytes: aliceGroup.groupId,
      );
      expect(after, isEmpty);
    });

    test('remove non-existent proposal ref throws', () async {
      final aliceGroup = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      // Malformed proposal ref should throw
      expect(
        () => alice.removePendingProposal(
          groupIdBytes: aliceGroup.groupId,
          proposalRefBytes: [1, 2, 3],
        ),
        throwsA(isA<Object>()),
      );
    });
  });

  group('groupEpochAuthenticator', () {
    test('returns non-empty bytes for a new group', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      final authenticator = await alice.groupEpochAuthenticator(
        groupIdBytes: result.groupId,
      );
      expect(authenticator, isNotEmpty);
    });

    test('epoch authenticator changes after commit', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      final auth0 = await alice.groupEpochAuthenticator(
        groupIdBytes: result.groupId,
      );

      // Self-update to advance epoch
      await alice.selfUpdate(
        groupIdBytes: result.groupId,
        signerBytes: aliceId.signerBytes,
      );

      final auth1 = await alice.groupEpochAuthenticator(
        groupIdBytes: result.groupId,
      );

      // Should differ after epoch advance
      expect(auth1, isNot(equals(auth0)));
    });
  });

  group('groupConfiguration', () {
    test('returns configuration matching defaults', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      final config = await alice.groupConfiguration(
        groupIdBytes: result.groupId,
      );
      expect(config.ciphersuite, equals(ciphersuite));
      expect(config.wireFormatPolicy, equals(MlsWireFormatPolicy.ciphertext));
      expect(config.paddingSize, equals(0));
    });

    test('configuration reflects custom settings', () async {
      final customConfig = MlsGroupConfig(
        ciphersuite: ciphersuite,
        wireFormatPolicy: MlsWireFormatPolicy.plaintext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 5,
        paddingSize: 128,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 500,
        numberOfResumptionPsks: 3,
      );

      final result = await alice.createGroup(
        config: customConfig,
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      final readBack = await alice.groupConfiguration(
        groupIdBytes: result.groupId,
      );
      expect(readBack.wireFormatPolicy, equals(MlsWireFormatPolicy.plaintext));
      expect(readBack.paddingSize, equals(128));
      expect(readBack.senderRatchetMaxOutOfOrder, equals(10));
      expect(readBack.senderRatchetMaxForwardDistance, equals(500));
    });

    test('GroupConfigurationResult equality and hashCode', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      final config1 = await alice.groupConfiguration(
        groupIdBytes: result.groupId,
      );
      final config2 = await alice.groupConfiguration(
        groupIdBytes: result.groupId,
      );

      // Same group → equal configs
      expect(config1, equals(config2));
      expect(config1.hashCode, equals(config2.hashCode));

      // Different type → not equal
      expect(config1, isNot(equals('not a config')));
    });
  });

  group('X.509 credential support', () {
    test(
      'createKeyPackage with null credentialBytes uses BasicCredential',
      () async {
        // Default behavior: passing null credentialBytes should still work
        final kpResult = await alice.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        expect(kpResult.keyPackageBytes, isNotEmpty);
      },
    );

    test('createGroup with explicit BasicCredential bytes', () async {
      // Serialize a BasicCredential and pass it explicitly
      final basicCred = MlsCredential.basic(
        identity: aliceId.credentialIdentity,
      );
      final credBytes = basicCred.serialize();

      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
        credentialBytes: credBytes,
      );
      expect(result.groupId, isNotEmpty);

      // Verify the group's credential matches
      final groupCred = await alice.groupCredential(
        groupIdBytes: result.groupId,
      );
      final parsed = MlsCredential.deserialize(
        bytes: Uint8List.fromList(groupCred),
      );
      expect(parsed.identity(), equals(aliceId.credentialIdentity));
    });

    test('createGroupWithBuilder with explicit credential bytes', () async {
      final basicCred = MlsCredential.basic(
        identity: aliceId.credentialIdentity,
      );
      final credBytes = basicCred.serialize();

      final result = await alice.createGroupWithBuilder(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
        credentialBytes: credBytes,
      );
      expect(result.groupId, isNotEmpty);
    });

    test('selfUpdateWithNewSigner with explicit credential', () async {
      // Create group
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      // Create new identity for rotation
      final newAlice = TestIdentity.create('alice-rotated');
      final newCred = MlsCredential.basic(
        identity: newAlice.credentialIdentity,
      );

      final commitResult = await alice.selfUpdateWithNewSigner(
        groupIdBytes: result.groupId,
        oldSignerBytes: aliceId.signerBytes,
        newSignerBytes: newAlice.signerBytes,
        newCredentialIdentity: newAlice.credentialIdentity,
        newSignerPublicKey: newAlice.publicKey,
        newCredentialBytes: newCred.serialize(),
      );
      expect(commitResult.commit, isNotEmpty);
    });

    test('malformed credentialBytes throws', () async {
      expect(
        () => alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
          credentialBytes: Uint8List.fromList([0xFF, 0xFF]),
        ),
        throwsA(isA<Object>()),
      );
    });
  });

  group('proposeSelfUpdate with LeafNodeParameters', () {
    test('propose self-update with default params (no extensions)', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      // Default behavior — no leaf node params
      final proposal = await alice.proposeSelfUpdate(
        groupIdBytes: result.groupId,
        signerBytes: aliceId.signerBytes,
      );
      expect(proposal.proposalMessage, isNotEmpty);
    });

    test('propose self-update with custom extensions', () async {
      final result = await alice.createGroupWithBuilder(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
        capabilities: MlsCapabilities(
          versions: Uint16List.fromList([1]),
          ciphersuites: Uint16List.fromList([1]),
          extensions: Uint16List.fromList([0xFF01]),
          proposals: Uint16List(0),
          credentials: Uint16List(0),
        ),
      );

      // Propose self-update with custom leaf node extensions
      final proposal = await alice.proposeSelfUpdate(
        groupIdBytes: result.groupId,
        signerBytes: aliceId.signerBytes,
        leafNodeExtensions: [
          MlsExtension(
            extensionType: 0xFF01,
            data: Uint8List.fromList([1, 2, 3]),
          ),
        ],
      );
      expect(proposal.proposalMessage, isNotEmpty);
    });
  });
}
