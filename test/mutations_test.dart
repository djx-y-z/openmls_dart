import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

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

  group('add member and messaging', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      groupIdBytes = result.groupId;
    });

    test('Alice adds Bob via welcome', () async {
      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );

      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      expect(addResult.commit, isNotEmpty);
      expect(addResult.welcome, isNotEmpty);

      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      final joinResult = await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
      );
      expect(joinResult.groupId, equals(groupIdBytes));

      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      final bobMembers = await bob.groupMembers(
        groupIdBytes: joinResult.groupId,
      );
      expect(aliceMembers, hasLength(2));
      expect(bobMembers, hasLength(2));
    });

    test('Alice and Bob exchange messages', () async {
      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );
      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      // Bob joins from welcome — Welcome already includes the add commit
      // state, so Bob does NOT need to process the add commit separately.
      final joinResult = await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
      );
      final bobGroupId = joinResult.groupId;

      // Alice sends a message
      final msgContent = Uint8List.fromList(utf8.encode('Hello Bob!'));
      final encrypted = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: msgContent,
      );
      expect(encrypted.ciphertext, isNotEmpty);

      // Bob receives the message
      final received = await bob.processMessage(
        groupIdBytes: bobGroupId,
        messageBytes: encrypted.ciphertext,
      );
      expect(received.messageType, ProcessedMessageType.application);
      expect(received.applicationMessage, equals(msgContent));

      // Bob sends a message back
      final replyContent = Uint8List.fromList(utf8.encode('Hi Alice!'));
      final reply = await bob.createMessage(
        groupIdBytes: bobGroupId,
        signerBytes: bobId.signerBytes,
        message: replyContent,
      );

      final aliceReceived = await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: reply.ciphertext,
      );
      expect(aliceReceived.messageType, ProcessedMessageType.application);
      expect(aliceReceived.applicationMessage, equals(replyContent));
    });
  });

  group('member removal', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      groupIdBytes = result.groupId;

      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );
      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      // Bob joins from welcome — Welcome already includes the add epoch
      await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
      );
    });

    test('Alice removes Bob', () async {
      final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(members, hasLength(2));

      final bobMember = members.firstWhere(
        (m) =>
            utf8.decode(identityFromCredential(m.credential)) ==
            utf8.decode(bobId.credentialIdentity),
      );

      final removeResult = await alice.removeMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        memberIndices: [bobMember.index],
      );
      expect(removeResult.commit, isNotEmpty);

      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      final membersAfter = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(membersAfter, hasLength(1));
    });
  });

  group('self-update operations', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      groupIdBytes = result.groupId;
    });

    test('self-update rotates keys', () async {
      final epochBefore = await alice.groupEpoch(groupIdBytes: groupIdBytes);

      final result = await alice.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      expect(result.commit, isNotEmpty);

      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      final epochAfter = await alice.groupEpoch(groupIdBytes: groupIdBytes);
      expect(epochAfter, equals(epochBefore + BigInt.one));
    });

    test('self-update with new signer rotates credential', () async {
      final newId = TestIdentity.create('alice-new');

      final result = await alice.selfUpdateWithNewSigner(
        groupIdBytes: groupIdBytes,
        oldSignerBytes: aliceId.signerBytes,
        newSignerBytes: newId.signerBytes,
        newCredentialIdentity: newId.credentialIdentity,
        newSignerPublicKey: newId.publicKey,
      );
      expect(result.commit, isNotEmpty);

      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      // Credential should now be the new identity
      final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(
        identityFromCredential(members.first.credential),
        equals(newId.credentialIdentity),
      );
    });
  });

  group('add members without update', () {
    test('adds member without self-updating', () async {
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;

      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );

      final addResult = await alice.addMembersWithoutUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      expect(addResult.commit, isNotEmpty);
      expect(addResult.welcome, isNotEmpty);

      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(members, hasLength(2));
    });
  });

  group('swap members', () {
    test('atomic remove and add', () async {
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;

      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );
      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);
      await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
      );

      // Create Charlie
      final charlieId = TestIdentity.create('charlie');
      final charlie = await createTestEngine();
      final charlieKp = await charlie.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: charlieId.signerBytes,
        credentialIdentity: charlieId.credentialIdentity,
        signerPublicKey: charlieId.publicKey,
      );

      // Swap Bob for Charlie
      final bobIdx = await alice.groupMemberLeafIndex(
        groupIdBytes: groupIdBytes,
        credentialBytes: bobId.serializedCredential,
      );

      final swapResult = await alice.swapMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        removeIndices: [bobIdx!],
        addKeyPackagesBytes: [charlieKp.keyPackageBytes],
      );
      expect(swapResult.commit, isNotEmpty);
      expect(swapResult.welcome, isNotEmpty);

      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      // Check members: Alice + Charlie (no Bob)
      final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(members, hasLength(2));
      final names = members
          .map((m) => utf8.decode(identityFromCredential(m.credential)))
          .toSet();
      expect(names, contains('alice'));
      expect(names, contains('charlie'));
      expect(names, isNot(contains('bob')));
    });
  });

  group('leave group', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      groupIdBytes = result.groupId;

      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );
      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);
      await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
      );
    });

    test('Bob leaves group', () async {
      final result = await bob.leaveGroup(
        groupIdBytes: groupIdBytes,
        signerBytes: bobId.signerBytes,
      );
      expect(result.message, isNotEmpty);
    });

    test('Bob leaves group via self-remove', () async {
      // leaveGroupViaSelfRemove requires plaintext wire format policy
      final plaintextConfig = MlsGroupConfig(
        ciphersuite: ciphersuite,
        wireFormatPolicy: MlsWireFormatPolicy.plaintext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );

      // Create fresh group with plaintext config
      final ptAlice = await createTestEngine();
      final ptBob = await createTestEngine();
      final ptAliceId = TestIdentity.create('pt-alice');
      final ptBobId = TestIdentity.create('pt-bob');

      final groupResult = await ptAlice.createGroup(
        config: plaintextConfig,
        signerBytes: ptAliceId.signerBytes,
        credentialIdentity: ptAliceId.credentialIdentity,
        signerPublicKey: ptAliceId.publicKey,
      );
      final gid = groupResult.groupId;

      final bobKp = await ptBob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: ptBobId.signerBytes,
        credentialIdentity: ptBobId.credentialIdentity,
        signerPublicKey: ptBobId.publicKey,
      );
      final addResult = await ptAlice.addMembers(
        groupIdBytes: gid,
        signerBytes: ptAliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await ptAlice.mergePendingCommit(groupIdBytes: gid);
      await ptBob.joinGroupFromWelcome(
        config: plaintextConfig,
        welcomeBytes: addResult.welcome,
        signerBytes: ptBobId.signerBytes,
      );

      // Bob leaves via self-remove
      final result = await ptBob.leaveGroupViaSelfRemove(
        groupIdBytes: gid,
        signerBytes: ptBobId.signerBytes,
      );
      expect(result.message, isNotEmpty);
    });
  });
}
