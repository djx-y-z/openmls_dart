import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

/// Helper to create a test identity (key pair + credential + signer bytes).
class TestIdentity {
  TestIdentity._({
    required this.signerBytes,
    required this.publicKey,
    required this.credentialIdentity,
  });

  factory TestIdentity.create(
    String name, {
    MlsCiphersuite ciphersuite =
        MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
  }) {
    final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
    final pubKey = keyPair.publicKey();
    final privKey = keyPair.privateKey();
    final identity = Uint8List.fromList(utf8.encode(name));
    final signer = serializeSigner(
      ciphersuite: ciphersuite,
      privateKey: privKey,
      publicKey: pubKey,
    );
    return TestIdentity._(
      signerBytes: signer,
      publicKey: pubKey,
      credentialIdentity: identity,
    );
  }

  final Uint8List signerBytes;
  final Uint8List publicKey;
  final Uint8List credentialIdentity;
}

void main() {
  late MlsClient alice;
  late MlsClient bob;
  late InMemoryMlsStorage aliceStorage;
  late InMemoryMlsStorage bobStorage;
  late TestIdentity aliceId;
  late TestIdentity bobId;

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() {
    aliceStorage = InMemoryMlsStorage();
    bobStorage = InMemoryMlsStorage();
    alice = MlsClient(aliceStorage);
    bob = MlsClient(bobStorage);
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');
  });

  MlsGroupConfig defaultConfig() =>
      MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  group('Provider-based API', () {
    // =========================================================================
    // Key Package
    // =========================================================================
    group('key packages', () {
      test('creates a key package', () async {
        final result = await alice.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        expect(result.keyPackageBytes, isNotEmpty);
        expect(aliceStorage.length, greaterThan(0));
      });
    });

    // =========================================================================
    // Group lifecycle
    // =========================================================================
    group('group lifecycle', () {
      test('creates a group', () async {
        final result = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        expect(result.groupId, isNotEmpty);
        expect(aliceStorage.length, greaterThan(0));
      });

      test('creates group with specific group ID', () async {
        final customId = Uint8List.fromList(utf8.encode('my-group'));
        final result = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
          groupId: customId,
        );
        expect(result.groupId, equals(customId));
      });
    });

    // =========================================================================
    // Group state queries
    // =========================================================================
    group('group state queries', () {
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

      test('group is active', () async {
        final active = await alice.groupIsActive(groupIdBytes: groupIdBytes);
        expect(active, isTrue);
      });

      test('group epoch starts at 0', () async {
        final epoch = await alice.groupEpoch(groupIdBytes: groupIdBytes);
        expect(epoch, equals(BigInt.zero));
      });

      test('group has one member (creator)', () async {
        final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
        expect(members, hasLength(1));
        expect(
          members.first.credentialIdentity,
          equals(aliceId.credentialIdentity),
        );
      });

      test('group ciphersuite matches', () async {
        final cs = await alice.groupCiphersuite(groupIdBytes: groupIdBytes);
        expect(cs, equals(ciphersuite));
      });

      test('own index is 0', () async {
        final idx = await alice.groupOwnIndex(groupIdBytes: groupIdBytes);
        expect(idx, equals(0));
      });

      test('group credential returns creator identity', () async {
        final cred = await alice.groupCredential(groupIdBytes: groupIdBytes);
        expect(cred, isNotEmpty);
      });

      test('no pending proposals initially', () async {
        final has = await alice.groupHasPendingProposals(
          groupIdBytes: groupIdBytes,
        );
        expect(has, isFalse);
      });

      test('own leaf node info', () async {
        final leaf = await alice.groupOwnLeafNode(groupIdBytes: groupIdBytes);
        expect(leaf.signatureKey, isNotEmpty);
        expect(leaf.credentialIdentity, equals(aliceId.credentialIdentity));
      });
    });

    // =========================================================================
    // Add member and messaging
    // =========================================================================
    group('add member and messaging', () {
      late Uint8List groupIdBytes;

      setUp(() async {
        // Alice creates group
        final result = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        groupIdBytes = result.groupId;
      });

      test('Alice adds Bob via welcome', () async {
        // Bob creates key package
        final bobKp = await bob.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: bobId.signerBytes,
          credentialIdentity: bobId.credentialIdentity,
          signerPublicKey: bobId.publicKey,
        );

        // Alice adds Bob
        final addResult = await alice.addMembers(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          keyPackagesBytes: [bobKp.keyPackageBytes],
        );
        expect(addResult.commit, isNotEmpty);
        expect(addResult.welcome, isNotEmpty);

        // Alice merges pending commit
        await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

        // Bob joins from welcome
        final joinResult = await bob.joinGroupFromWelcome(
          config: defaultConfig(),
          welcomeBytes: addResult.welcome,
          signerBytes: bobId.signerBytes,
        );
        expect(joinResult.groupId, equals(groupIdBytes));

        // Both see 2 members
        final aliceMembers = await alice.groupMembers(
          groupIdBytes: groupIdBytes,
        );
        final bobMembers = await bob.groupMembers(
          groupIdBytes: joinResult.groupId,
        );
        expect(aliceMembers, hasLength(2));
        expect(bobMembers, hasLength(2));
      });

      test('Alice and Bob exchange messages', () async {
        // Setup: add Bob to group
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

    // =========================================================================
    // Proposals
    // =========================================================================
    group('proposals', () {
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

      test('propose and commit self-update', () async {
        final proposal = await alice.proposeSelfUpdate(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        expect(proposal.proposalMessage, isNotEmpty);

        final has = await alice.groupHasPendingProposals(
          groupIdBytes: groupIdBytes,
        );
        expect(has, isTrue);

        final commit = await alice.commitToPendingProposals(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        expect(commit.commit, isNotEmpty);

        await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

        final epoch = await alice.groupEpoch(groupIdBytes: groupIdBytes);
        expect(epoch, equals(BigInt.from(1)));
      });
    });

    // =========================================================================
    // Member removal
    // =========================================================================
    group('member removal', () {
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

        // Bob joins from welcome — Welcome already includes the add epoch
        await bob.joinGroupFromWelcome(
          config: defaultConfig(),
          welcomeBytes: addResult.welcome,
          signerBytes: bobId.signerBytes,
        );
      });

      test('Alice removes Bob', () async {
        // Find Bob's leaf index
        final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
        expect(members, hasLength(2));

        final bobMember = members.firstWhere(
          (m) =>
              utf8.decode(m.credentialIdentity) ==
              utf8.decode(bobId.credentialIdentity),
        );

        final removeResult = await alice.removeMembers(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          memberIndices: [bobMember.index],
        );
        expect(removeResult.commit, isNotEmpty);

        await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

        final membersAfter = await alice.groupMembers(
          groupIdBytes: groupIdBytes,
        );
        expect(membersAfter, hasLength(1));
      });
    });

    // =========================================================================
    // Exports
    // =========================================================================
    group('exports', () {
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

      test('export ratchet tree', () async {
        final tree = await alice.exportRatchetTree(groupIdBytes: groupIdBytes);
        expect(tree, isNotEmpty);
      });

      test('export group info', () async {
        final info = await alice.exportGroupInfo(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        expect(info, isNotEmpty);
      });

      test('export group context', () async {
        final ctx = await alice.exportGroupContext(groupIdBytes: groupIdBytes);
        expect(ctx.groupId, equals(groupIdBytes));
        expect(ctx.epoch, equals(BigInt.zero));
        expect(ctx.ciphersuite, equals(ciphersuite));
      });

      test('confirmation tag', () async {
        final tag = await alice.groupConfirmationTag(
          groupIdBytes: groupIdBytes,
        );
        expect(tag, isNotEmpty);
      });

      test('export secret', () async {
        final secret = await alice.exportSecret(
          groupIdBytes: groupIdBytes,
          label: 'test-label',
          context: utf8.encode('test-context'),
          keyLength: 32,
        );
        expect(secret, hasLength(32));
      });
    });

    // =========================================================================
    // InMemoryMlsStorage utilities
    // =========================================================================
    group('InMemoryMlsStorage utilities', () {
      test('isEmpty, isNotEmpty, and clear', () async {
        final storage = InMemoryMlsStorage();
        expect(storage.isEmpty, isTrue);
        expect(storage.isNotEmpty, isFalse);

        // Create a group to populate storage
        final client = MlsClient(storage);
        final id = TestIdentity.create('util-test');
        await client.createGroup(
          config: defaultConfig(),
          signerBytes: id.signerBytes,
          credentialIdentity: id.credentialIdentity,
          signerPublicKey: id.publicKey,
        );

        expect(storage.isEmpty, isFalse);
        expect(storage.isNotEmpty, isTrue);

        storage.clear();
        expect(storage.isEmpty, isTrue);
        expect(storage.length, equals(0));
      });
    });

    // =========================================================================
    // Storage isolation
    // =========================================================================
    group('storage isolation', () {
      test('separate storage instances are independent', () async {
        final storage1 = InMemoryMlsStorage();
        final storage2 = InMemoryMlsStorage();
        final client1 = MlsClient(storage1);
        final client2 = MlsClient(storage2);

        final id1 = TestIdentity.create('user1');
        final id2 = TestIdentity.create('user2');

        await client1.createGroup(
          config: defaultConfig(),
          signerBytes: id1.signerBytes,
          credentialIdentity: id1.credentialIdentity,
          signerPublicKey: id1.publicKey,
        );

        await client2.createGroup(
          config: defaultConfig(),
          signerBytes: id2.signerBytes,
          credentialIdentity: id2.credentialIdentity,
          signerPublicKey: id2.publicKey,
        );

        // Both storages have data but are independent
        expect(storage1.length, greaterThan(0));
        expect(storage2.length, greaterThan(0));
      });
    });

    // =========================================================================
    // Message utilities
    // =========================================================================
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

    // =========================================================================
    // Key pair operations
    // =========================================================================
    group('key pair operations', () {
      test('signature scheme matches ciphersuite', () {
        final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
        final scheme = keyPair.signatureScheme();
        // Ed25519 scheme value is 0x0807
        expect(scheme, equals(0x0807));
      });

      test('serialize and deserialize public key', () {
        final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
        final pubKey = keyPair.publicKey();
        final serialized = keyPair.serialize();

        final deserialized = MlsSignatureKeyPair.deserializePublic(
          bytes: serialized,
        );
        expect(deserialized.publicKey(), equals(pubKey));
      });

      test('from_raw reconstructs key pair', () {
        final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
        final pubKey = keyPair.publicKey();
        final privKey = keyPair.privateKey();

        final reconstructed = MlsSignatureKeyPair.fromRaw(
          ciphersuite: ciphersuite,
          privateKey: privKey,
          publicKey: pubKey,
        );
        expect(reconstructed.publicKey(), equals(pubKey));
        expect(reconstructed.privateKey(), equals(privKey));
      });
    });

    // =========================================================================
    // Key package with options
    // =========================================================================
    group('key package with options', () {
      test('creates key package with lifetime and last-resort', () async {
        final options = KeyPackageOptions(
          lifetimeSeconds: BigInt.from(86400), // 1 day
          lastResort: true,
        );
        final result = await alice.createKeyPackageWithOptions(
          ciphersuite: ciphersuite,
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
          options: options,
        );
        expect(result.keyPackageBytes, isNotEmpty);
      });
    });

    // =========================================================================
    // Group with builder
    // =========================================================================
    group('group with builder', () {
      test('creates group with builder', () async {
        final result = await alice.createGroupWithBuilder(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        expect(result.groupId, isNotEmpty);
      });
    });

    // =========================================================================
    // Welcome inspection
    // =========================================================================
    group('welcome inspection', () {
      test('inspect welcome before joining', () async {
        // Alice creates group
        final groupResult = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );

        // Bob creates key package
        final bobKp = await bob.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: bobId.signerBytes,
          credentialIdentity: bobId.credentialIdentity,
          signerPublicKey: bobId.publicKey,
        );

        // Alice adds Bob
        final addResult = await alice.addMembers(
          groupIdBytes: groupResult.groupId,
          signerBytes: aliceId.signerBytes,
          keyPackagesBytes: [bobKp.keyPackageBytes],
        );
        await alice.mergePendingCommit(groupIdBytes: groupResult.groupId);

        // Inspect welcome without joining
        final info = await bob.inspectWelcome(
          config: defaultConfig(),
          welcomeBytes: addResult.welcome,
        );
        expect(info.groupId, equals(groupResult.groupId));
        expect(info.ciphersuite, equals(ciphersuite));
        expect(info.epoch, equals(BigInt.from(1)));
      });
    });

    // =========================================================================
    // Additional state queries
    // =========================================================================
    group('additional state queries', () {
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

      test('group_id returns the group ID', () async {
        final id = await alice.groupId(groupIdBytes: groupIdBytes);
        expect(id, equals(groupIdBytes));
      });

      test('group extensions returns bytes', () async {
        final ext = await alice.groupExtensions(groupIdBytes: groupIdBytes);
        // Default group has empty extensions (but serialized, so may be non-empty)
        expect(ext, isNotNull);
      });

      test('pending proposals list is empty initially', () async {
        final proposals = await alice.groupPendingProposals(
          groupIdBytes: groupIdBytes,
        );
        expect(proposals, isEmpty);
      });

      test('member_at returns member by leaf index', () async {
        final member = await alice.groupMemberAt(
          groupIdBytes: groupIdBytes,
          leafIndex: 0,
        );
        expect(member, isNotNull);
        expect(member!.credentialIdentity, equals(aliceId.credentialIdentity));
      });

      test('member_at returns null for invalid index', () async {
        final member = await alice.groupMemberAt(
          groupIdBytes: groupIdBytes,
          leafIndex: 99,
        );
        expect(member, isNull);
      });

      test('member_leaf_index finds member by credential', () async {
        final idx = await alice.groupMemberLeafIndex(
          groupIdBytes: groupIdBytes,
          credentialIdentity: aliceId.credentialIdentity,
        );
        expect(idx, equals(0));
      });
    });

    // =========================================================================
    // Self-update operations
    // =========================================================================
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
          members.first.credentialIdentity,
          equals(newId.credentialIdentity),
        );
      });
    });

    // =========================================================================
    // Standalone proposals
    // =========================================================================
    group('standalone proposals', () {
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

      test('propose add member', () async {
        final charlieId = TestIdentity.create('charlie');
        final charlieStorage = InMemoryMlsStorage();
        final charlie = MlsClient(charlieStorage);
        final charlieKp = await charlie.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: charlieId.signerBytes,
          credentialIdentity: charlieId.credentialIdentity,
          signerPublicKey: charlieId.publicKey,
        );

        final proposal = await alice.proposeAdd(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          keyPackageBytes: charlieKp.keyPackageBytes,
        );
        expect(proposal.proposalMessage, isNotEmpty);

        // Check pending proposals
        final proposals = await alice.groupPendingProposals(
          groupIdBytes: groupIdBytes,
        );
        expect(proposals, hasLength(1));
        expect(proposals.first.proposalType, MlsProposalType.add);
      });

      test('propose remove member', () async {
        final bobIdx = await alice.groupMemberLeafIndex(
          groupIdBytes: groupIdBytes,
          credentialIdentity: bobId.credentialIdentity,
        );

        final proposal = await alice.proposeRemove(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          memberIndex: bobIdx!,
        );
        expect(proposal.proposalMessage, isNotEmpty);
      });

      test('propose remove member by credential', () async {
        final proposal = await alice.proposeRemoveMemberByCredential(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          credentialIdentity: bobId.credentialIdentity,
        );
        expect(proposal.proposalMessage, isNotEmpty);
      });

      test('propose custom proposal', () async {
        final proposal = await alice.proposeCustomProposal(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          proposalType: 0xF001, // private-use range
          payload: utf8.encode('custom-data'),
        );
        expect(proposal.proposalMessage, isNotEmpty);
      });
    });

    // =========================================================================
    // Clear operations
    // =========================================================================
    group('clear operations', () {
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

      test('clear pending proposals', () async {
        // Create a proposal
        await alice.proposeSelfUpdate(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        expect(
          await alice.groupHasPendingProposals(groupIdBytes: groupIdBytes),
          isTrue,
        );

        // Clear it
        await alice.clearPendingProposals(groupIdBytes: groupIdBytes);
        expect(
          await alice.groupHasPendingProposals(groupIdBytes: groupIdBytes),
          isFalse,
        );
      });

      test('clear pending commit does not error', () async {
        // Note: selfUpdate and commitToPendingProposals auto-merge in our API,
        // so there's no pending commit to clear. But clearPendingCommit should
        // not error even when there's nothing to clear.
        await alice.clearPendingCommit(groupIdBytes: groupIdBytes);

        final epoch = await alice.groupEpoch(groupIdBytes: groupIdBytes);
        expect(epoch, equals(BigInt.zero));
      });
    });

    // =========================================================================
    // Leave group
    // =========================================================================
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
        final ptAliceStorage = InMemoryMlsStorage();
        final ptBobStorage = InMemoryMlsStorage();
        final ptAlice = MlsClient(ptAliceStorage);
        final ptBob = MlsClient(ptBobStorage);
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

    // =========================================================================
    // Swap members
    // =========================================================================
    group('swap members', () {
      test('atomic remove and add', () async {
        // Create group with Alice and Bob
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
        final charlieStorage = InMemoryMlsStorage();
        final charlie = MlsClient(charlieStorage);
        final charlieKp = await charlie.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: charlieId.signerBytes,
          credentialIdentity: charlieId.credentialIdentity,
          signerPublicKey: charlieId.publicKey,
        );

        // Swap Bob for Charlie
        final bobIdx = await alice.groupMemberLeafIndex(
          groupIdBytes: groupIdBytes,
          credentialIdentity: bobId.credentialIdentity,
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
            .map((m) => utf8.decode(m.credentialIdentity))
            .toSet();
        expect(names, contains('alice'));
        expect(names, contains('charlie'));
        expect(names, isNot(contains('bob')));
      });
    });

    // =========================================================================
    // Flexible commit
    // =========================================================================
    group('flexible commit', () {
      test('add member via flexible commit', () async {
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

        final options = FlexibleCommitOptions(
          addKeyPackages: [bobKp.keyPackageBytes],
          removeIndices: Uint32List(0),
          forceSelfUpdate: false,
          consumePendingProposals: true,
          createGroupInfo: true,
          useRatchetTreeExtension: true,
        );

        final result = await alice.flexibleCommit(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          options: options,
        );
        expect(result.commit, isNotEmpty);
        expect(result.welcome, isNotEmpty);

        await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

        final members = await alice.groupMembers(groupIdBytes: groupIdBytes);
        expect(members, hasLength(2));
      });
    });

    // =========================================================================
    // Process commit and proposal messages
    // =========================================================================
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

    // =========================================================================
    // Three-member group
    // =========================================================================
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

        // Bob processes Alice's add commit (for Bob to be in sync)
        // Not needed — Bob joins via Welcome which already has the state

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
        final aliceMembers = await alice.groupMembers(
          groupIdBytes: groupIdBytes,
        );
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

    // =========================================================================
    // Set configuration
    // =========================================================================
    group('set configuration', () {
      test('update group configuration', () async {
        final result = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        final groupIdBytes = result.groupId;

        // Set a new config (same ciphersuite, different wire format)
        final newConfig = defaultConfig();
        await alice.setConfiguration(
          groupIdBytes: groupIdBytes,
          config: newConfig,
        );

        // Should not error — group still works
        final active = await alice.groupIsActive(groupIdBytes: groupIdBytes);
        expect(active, isTrue);
      });
    });

    // =========================================================================
    // Add members without update
    // =========================================================================
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

    // =========================================================================
    // Join group from welcome with options
    // =========================================================================
    group('join group from welcome with options', () {
      test('join with skip lifetime validation', () async {
        // Alice creates group
        final groupResult = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );
        final groupIdBytes = groupResult.groupId;

        // Bob creates key package
        final bobKp = await bob.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: bobId.signerBytes,
          credentialIdentity: bobId.credentialIdentity,
          signerPublicKey: bobId.publicKey,
        );

        // Alice adds Bob
        final addResult = await alice.addMembers(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          keyPackagesBytes: [bobKp.keyPackageBytes],
        );
        await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

        // Bob joins with skip lifetime validation
        final joinResult = await bob.joinGroupFromWelcomeWithOptions(
          config: defaultConfig(),
          welcomeBytes: addResult.welcome,
          signerBytes: bobId.signerBytes,
          skipLifetimeValidation: true,
        );
        expect(joinResult.groupId, equals(groupIdBytes));

        // Both see 2 members
        final members = await bob.groupMembers(
          groupIdBytes: joinResult.groupId,
        );
        expect(members, hasLength(2));
      });
    });

    // =========================================================================
    // External commit join
    // =========================================================================
    group('external commit join', () {
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

      test('join group via external commit (v1)', () async {
        // Alice exports group info and ratchet tree
        final groupInfo = await alice.exportGroupInfo(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        final ratchetTree = await alice.exportRatchetTree(
          groupIdBytes: groupIdBytes,
        );

        // Bob joins via external commit
        final joinResult = await bob.joinGroupExternalCommit(
          config: defaultConfig(),
          groupInfoBytes: groupInfo,
          ratchetTreeBytes: ratchetTree,
          signerBytes: bobId.signerBytes,
          credentialIdentity: bobId.credentialIdentity,
          signerPublicKey: bobId.publicKey,
        );
        expect(joinResult.groupId, equals(groupIdBytes));
        expect(joinResult.commit, isNotEmpty);

        // Alice processes Bob's external commit
        final processed = await alice.processMessage(
          groupIdBytes: groupIdBytes,
          messageBytes: joinResult.commit,
        );
        expect(processed.messageType, ProcessedMessageType.stagedCommit);

        // Both see 2 members
        final aliceMembers = await alice.groupMembers(
          groupIdBytes: groupIdBytes,
        );
        final bobMembers = await bob.groupMembers(groupIdBytes: groupIdBytes);
        expect(aliceMembers, hasLength(2));
        expect(bobMembers, hasLength(2));
      });

      test('join group via external commit v2', () async {
        // Alice exports group info and ratchet tree
        final groupInfo = await alice.exportGroupInfo(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        final ratchetTree = await alice.exportRatchetTree(
          groupIdBytes: groupIdBytes,
        );

        // Bob joins via external commit v2 with AAD
        final joinResult = await bob.joinGroupExternalCommitV2(
          config: defaultConfig(),
          groupInfoBytes: groupInfo,
          ratchetTreeBytes: ratchetTree,
          signerBytes: bobId.signerBytes,
          credentialIdentity: bobId.credentialIdentity,
          signerPublicKey: bobId.publicKey,
          aad: Uint8List.fromList(utf8.encode('external-aad')),
          skipLifetimeValidation: true,
        );
        expect(joinResult.groupId, equals(groupIdBytes));
        expect(joinResult.commit, isNotEmpty);

        // Alice processes the external commit
        await alice.processMessage(
          groupIdBytes: groupIdBytes,
          messageBytes: joinResult.commit,
        );

        // Both see 2 members
        final aliceMembers = await alice.groupMembers(
          groupIdBytes: groupIdBytes,
        );
        expect(aliceMembers, hasLength(2));
      });
    });

    // =========================================================================
    // PSK operations
    // =========================================================================
    group('PSK operations', () {
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

      test('propose external PSK', () async {
        final proposal = await alice.proposeExternalPsk(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          pskId: utf8.encode('my-psk-id'),
          pskNonce: utf8.encode('my-psk-nonce'),
        );
        expect(proposal.proposalMessage, isNotEmpty);

        final proposals = await alice.groupPendingProposals(
          groupIdBytes: groupIdBytes,
        );
        expect(proposals, hasLength(1));
        expect(proposals.first.proposalType, MlsProposalType.preSharedKey);
      });

      test('get past resumption PSK at epoch 0', () async {
        // The resumption PSK for the current epoch is available
        final psk = await alice.getPastResumptionPsk(
          groupIdBytes: groupIdBytes,
          epoch: BigInt.zero,
        );
        expect(psk, isNotNull);
        expect(psk, isNotEmpty);
      });
    });

    // =========================================================================
    // Group context extensions proposals and commits
    // =========================================================================
    group('group context extensions', () {
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

      test('propose group context extensions', () async {
        final ext = MlsExtension(
          extensionType: 0xFF01, // private-use range
          data: Uint8List.fromList(utf8.encode('ext-data')),
        );
        final proposal = await alice.proposeGroupContextExtensions(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          extensions: [ext],
        );
        expect(proposal.proposalMessage, isNotEmpty);

        final proposals = await alice.groupPendingProposals(
          groupIdBytes: groupIdBytes,
        );
        expect(proposals, hasLength(1));
        expect(
          proposals.first.proposalType,
          MlsProposalType.groupContextExtensions,
        );
      });

      test('update group context extensions via commit', () async {
        // Update with empty extensions (clears custom extensions)
        final result = await alice.updateGroupContextExtensions(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          extensions: [],
        );
        expect(result.commit, isNotEmpty);

        // updateGroupContextExtensions auto-merges, so epoch should advance
        final epoch = await alice.groupEpoch(groupIdBytes: groupIdBytes);
        expect(epoch, equals(BigInt.from(1)));
      });
    });

    // =========================================================================
    // Message with AAD
    // =========================================================================
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

    // =========================================================================
    // Error handling
    // =========================================================================
    group('error handling', () {
      test('process malformed message throws', () async {
        final groupResult = await alice.createGroup(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
        );

        expect(
          () => alice.processMessage(
            groupIdBytes: groupResult.groupId,
            messageBytes: Uint8List.fromList([0, 1, 2, 3]),
          ),
          throwsA(isA<Object>()),
        );
      });

      test('load non-existent group throws', () async {
        final fakeGroupId = Uint8List.fromList(utf8.encode('no-such-group'));

        expect(
          () => alice.groupIsActive(groupIdBytes: fakeGroupId),
          throwsA(isA<Object>()),
        );
      });

      test('extract group ID from invalid bytes throws', () {
        expect(
          () => mlsMessageExtractGroupId(
            messageBytes: Uint8List.fromList([0xFF, 0xFF]),
          ),
          throwsA(isA<Object>()),
        );
      });

      test('extract epoch from invalid bytes throws', () {
        expect(
          () => mlsMessageExtractEpoch(
            messageBytes: Uint8List.fromList([0xFF, 0xFF]),
          ),
          throwsA(isA<Object>()),
        );
      });

      test('content type from invalid bytes throws', () {
        expect(
          () => mlsMessageContentType(
            messageBytes: Uint8List.fromList([0xFF, 0xFF]),
          ),
          throwsA(isA<Object>()),
        );
      });
    });

    // =========================================================================
    // X.509 credentials
    // =========================================================================
    group('X.509 credentials', () {
      test('create and inspect X.509 credential', () {
        final cert1 = Uint8List.fromList([0x30, 0x82, 0x01, 0x22]); // mock DER
        final cert2 = Uint8List.fromList([0x30, 0x82, 0x01, 0x33]);
        final cred = MlsCredential.x509(certificateChain: [cert1, cert2]);

        expect(cred.credentialType(), equals(2)); // X509 = 2

        final certs = cred.certificates();
        expect(certs, hasLength(2));
        expect(certs[0], equals(cert1));
        expect(certs[1], equals(cert2));
      });

      test('serialized content round-trip', () {
        final cert = Uint8List.fromList([1, 2, 3, 4, 5]);
        final cred = MlsCredential.x509(certificateChain: [cert]);

        final content = cred.serializedContent();
        expect(content, isNotEmpty);
      });

      test('serialize/deserialize X.509 credential', () {
        final cert = Uint8List.fromList(utf8.encode('test-certificate'));
        final cred = MlsCredential.x509(certificateChain: [cert]);

        final serialized = cred.serialize();
        final deserialized = MlsCredential.deserialize(bytes: serialized);

        expect(deserialized.credentialType(), equals(2));
        final certs = deserialized.certificates();
        expect(certs, hasLength(1));
        expect(certs[0], equals(cert));
      });

      test('identity() fails on X.509 credential', () {
        final cert = Uint8List.fromList([1, 2, 3]);
        final cred = MlsCredential.x509(certificateChain: [cert]);

        expect(cred.identity, throwsA(isA<Object>()));
      });

      test('certificates() fails on Basic credential', () {
        final cred = MlsCredential.basic(identity: utf8.encode('alice'));

        expect(cred.certificates, throwsA(isA<Object>()));
      });
    });
  });
}
