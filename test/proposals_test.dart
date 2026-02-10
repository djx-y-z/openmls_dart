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
      final charlie = await createTestEngine();
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
        credentialBytes: bobId.serializedCredential,
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
        credentialBytes: bobId.serializedCredential,
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
}
