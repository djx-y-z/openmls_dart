import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late MlsClient alice;
  late MlsClient bob;
  late TestIdentity aliceId;
  late TestIdentity bobId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() {
    alice = MlsClient(InMemoryMlsStorage());
    bob = MlsClient(InMemoryMlsStorage());
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');
  });

  group('message utilities', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      // Alice creates group and adds Bob
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

    test('extract group ID from encrypted message', () async {
      final msg = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: Uint8List.fromList(utf8.encode('test')),
      );
      final extractedId = mlsMessageExtractGroupId(
        messageBytes: msg.ciphertext,
      );
      expect(extractedId, equals(groupIdBytes));
    });

    test('extract epoch from encrypted message', () async {
      final msg = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: Uint8List.fromList(utf8.encode('test')),
      );
      final epoch = mlsMessageExtractEpoch(messageBytes: msg.ciphertext);
      expect(epoch, equals(BigInt.from(1)));
    });

    test('content type of encrypted message', () async {
      final msg = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: Uint8List.fromList(utf8.encode('test')),
      );
      final ct = mlsMessageContentType(messageBytes: msg.ciphertext);
      expect(ct, equals('application'));
    });
  });

  group('message with AAD', () {
    test(
      'send and receive message with additional authenticated data',
      () async {
        // Setup: Alice creates group and adds Bob
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

        // Send message with AAD
        final msg = Uint8List.fromList(utf8.encode('Hello with AAD'));
        final aad = Uint8List.fromList(utf8.encode('authenticated-metadata'));
        final encrypted = await alice.createMessage(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          message: msg,
          aad: aad,
        );
        expect(encrypted.ciphertext, isNotEmpty);

        // Bob decrypts the message
        final received = await bob.processMessage(
          groupIdBytes: groupIdBytes,
          messageBytes: encrypted.ciphertext,
        );
        expect(received.messageType, ProcessedMessageType.application);
        expect(received.applicationMessage, equals(msg));
      },
    );
  });

  group('process commit and proposal messages', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      // Create group with Alice and Bob
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

    test('Bob processes Alice self-update commit', () async {
      // selfUpdate auto-merges on Alice's side
      final updateResult = await alice.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );

      // Bob processes the commit
      final processed = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: updateResult.commit,
      );
      expect(processed.messageType, ProcessedMessageType.stagedCommit);
    });

    test('Bob processes Alice self-update commit with inspect', () async {
      final updateResult = await alice.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );

      // Bob processes with inspection
      final processed = await bob.processMessageWithInspect(
        groupIdBytes: groupIdBytes,
        messageBytes: updateResult.commit,
      );
      expect(processed.messageType, ProcessedMessageType.stagedCommit);
      expect(processed.stagedCommitInfo, isNotNull);
      // self_update creates a commit with path update (not an explicit
      // Update proposal), so hasUpdate may be false. The key assertion
      // is that stagedCommitInfo is present and the commit is processed.
      expect(processed.stagedCommitInfo!.selfRemoved, isFalse);
    });

    test('Bob processes Alice proposal message', () async {
      // Alice proposes self-update (sends proposal, not commit)
      final proposal = await alice.proposeSelfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );

      // Bob processes the proposal
      final processed = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: proposal.proposalMessage,
      );
      expect(processed.messageType, ProcessedMessageType.proposal);
      expect(processed.proposalType, MlsProposalType.update);
    });
  });

  group('three-member group', () {
    test('Alice, Bob, and Charlie exchange messages', () async {
      // Create group
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;

      // Add Bob
      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );
      final addBob = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);
      await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addBob.welcome,
        signerBytes: bobId.signerBytes,
      );

      // Add Charlie
      final charlieId = TestIdentity.create('charlie');
      final charlieStorage = InMemoryMlsStorage();
      final charlie = MlsClient(charlieStorage);
      final charlieKp = await charlie.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: charlieId.signerBytes,
        credentialIdentity: charlieId.credentialIdentity,
        signerPublicKey: charlieId.publicKey,
      );
      final addCharlie = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [charlieKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      // Bob processes the add-Charlie commit
      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: addCharlie.commit,
      );

      // Charlie joins via welcome
      await charlie.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: addCharlie.welcome,
        signerBytes: charlieId.signerBytes,
      );

      // All three see 3 members
      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      final bobMembers = await bob.groupMembers(groupIdBytes: groupIdBytes);
      final charlieMembers = await charlie.groupMembers(
        groupIdBytes: groupIdBytes,
      );
      expect(aliceMembers, hasLength(3));
      expect(bobMembers, hasLength(3));
      expect(charlieMembers, hasLength(3));

      // Alice sends a message, both Bob and Charlie receive it
      final msg = Uint8List.fromList(utf8.encode('Hello everyone!'));
      final encrypted = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: msg,
      );

      final bobReceived = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: encrypted.ciphertext,
      );
      final charlieReceived = await charlie.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: encrypted.ciphertext,
      );

      expect(bobReceived.applicationMessage, equals(msg));
      expect(charlieReceived.applicationMessage, equals(msg));
    });
  });
}
