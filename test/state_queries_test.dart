import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late MlsClient alice;
  late TestIdentity aliceId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() {
    alice = MlsClient(InMemoryMlsStorage());
    aliceId = TestIdentity.create('alice');
  });

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
        identityFromCredential(members.first.credential),
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

    test('group credential returns serialized credential', () async {
      final cred = await alice.groupCredential(groupIdBytes: groupIdBytes);
      expect(cred, isNotEmpty);
      // Verify it's a valid TLS-serialized Credential that can be deserialized
      final parsed = MlsCredential.deserialize(bytes: Uint8List.fromList(cred));
      expect(parsed.identity(), equals(aliceId.credentialIdentity));
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
      expect(
        identityFromCredential(leaf.credential),
        equals(aliceId.credentialIdentity),
      );
    });
  });

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
      expect(
        identityFromCredential(member!.credential),
        equals(aliceId.credentialIdentity),
      );
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
        credentialBytes: aliceId.serializedCredential,
      );
      expect(idx, equals(0));
    });
  });

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
      expect(ctx.treeHash, isNotEmpty);
      // confirmed_transcript_hash is empty at epoch 0 (initialized from first commit)
    });

    test('confirmation tag', () async {
      final tag = await alice.groupConfirmationTag(groupIdBytes: groupIdBytes);
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
}
