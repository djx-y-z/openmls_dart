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

  group('group lifecycle', () {
    test('creates a group', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      expect(result.groupId, isNotEmpty);
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

  group('join group from welcome with options', () {
    test('join with skip lifetime validation', () async {
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

      final joinResult = await bob.joinGroupFromWelcomeWithOptions(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
        skipLifetimeValidation: true,
      );
      expect(joinResult.groupId, equals(groupIdBytes));

      final members = await bob.groupMembers(groupIdBytes: joinResult.groupId);
      expect(members, hasLength(2));
    });
  });

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
      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final ratchetTree = await alice.exportRatchetTree(
        groupIdBytes: groupIdBytes,
      );

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

      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      final bobMembers = await bob.groupMembers(groupIdBytes: groupIdBytes);
      expect(aliceMembers, hasLength(2));
      expect(bobMembers, hasLength(2));
    });

    test('join group via external commit v2', () async {
      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final ratchetTree = await alice.exportRatchetTree(
        groupIdBytes: groupIdBytes,
      );

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

      await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: joinResult.commit,
      );

      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(aliceMembers, hasLength(2));
    });
  });
}
