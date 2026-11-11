import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// Fails unless the call throws an error whose text contains every one of
/// [texts].
Matcher throwsNaming(List<String> texts) => throwsA(
  predicate(
    (error) => texts.every('$error'.contains),
    'an error naming ${texts.join(' and ')}',
  ),
);

/// The refusal of a create or a Welcome under a stored group ID.
final refusedAsStored = throwsNaming(['already exists', 'deleteGroup']);

/// The refusal of an external join into a stored group.
final refusedUntold = throwsNaming(['already exists', 'replaceStoredGroup']);

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

  Future<Uint8List> create(
    MlsEngine engine,
    TestIdentity id, {
    List<int>? groupId,
  }) async => (await engine.createGroup(
    config: defaultConfig(),
    signerBytes: id.signerBytes,
    credentialIdentity: id.credentialIdentity,
    signerPublicKey: id.publicKey,
    groupId: groupId == null ? null : Uint8List.fromList(groupId),
  )).groupId;

  Future<Uint8List> keyPackage(MlsEngine engine, TestIdentity id) async =>
      (await engine.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: id.signerBytes,
        credentialIdentity: id.credentialIdentity,
        signerPublicKey: id.publicKey,
      )).keyPackageBytes;

  /// [owner] adds [joiner] to [group], and the joiner joins.
  Future<void> addAndJoin(
    Uint8List group,
    MlsEngine owner,
    TestIdentity ownerId,
    MlsEngine joiner,
    TestIdentity joinerId,
  ) async {
    final added = await owner.addMembers(
      groupIdBytes: group,
      signerBytes: ownerId.signerBytes,
      keyPackagesBytes: [await keyPackage(joiner, joinerId)],
    );
    await owner.mergePendingCommit(groupIdBytes: group);
    await joiner.joinGroupFromWelcome(
      config: defaultConfig(),
      welcomeBytes: added.welcome,
      signerBytes: joinerId.signerBytes,
    );
  }

  group('a group ID this engine stores', () {
    test('is refused to a create, either way of creating', () async {
      final id = utf8.encode('in use');
      await create(alice, aliceId, groupId: id);

      await expectLater(create(alice, aliceId, groupId: id), refusedAsStored);
      await expectLater(
        alice.createGroupWithBuilder(
          config: defaultConfig(),
          signerBytes: aliceId.signerBytes,
          credentialIdentity: aliceId.credentialIdentity,
          signerPublicKey: aliceId.publicKey,
          groupId: Uint8List.fromList(id),
        ),
        refusedAsStored,
      );
      // The stored group is as it was, and free again once deleted.
      expect(await alice.groupEpoch(groupIdBytes: id), BigInt.zero);
      await alice.deleteGroup(groupIdBytes: id);
      await create(alice, aliceId, groupId: id);
    });

    test('is refused to a Welcome, which writes nothing', () async {
      final id = utf8.encode('in use');
      await create(alice, aliceId, groupId: id);
      // Bob's group of his own, under the same ID, invites Alice.
      await create(bob, bobId, groupId: id);
      final package = await keyPackage(alice, aliceId);
      final invitation = await bob.addMembers(
        groupIdBytes: id,
        signerBytes: bobId.signerBytes,
        keyPackagesBytes: [package],
      );

      await expectLater(
        alice.joinGroupFromWelcome(
          config: defaultConfig(),
          welcomeBytes: invitation.welcome,
          signerBytes: aliceId.signerBytes,
        ),
        refusedAsStored,
      );
      final members = await alice.groupMembers(groupIdBytes: id);
      expect(members.single.signatureKey, aliceId.publicKey);
      // The key package the Welcome was addressed to is still there.
      await alice.deleteGroup(groupIdBytes: id);
      await alice.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: invitation.welcome,
        signerBytes: aliceId.signerBytes,
      );
      expect(await alice.groupMembers(groupIdBytes: id), hasLength(2));
    });

    for (final v2 in [false, true]) {
      test('is refused to an external join${v2 ? ' v2' : ''} unless told to '
          'replace the group, and then rejoins', () async {
        final carol = await createTestEngine();
        final carolId = TestIdentity.create('carol');
        final group = await create(alice, aliceId);
        await addAndJoin(group, alice, aliceId, bob, bobId);

        // Bob stores a proposal and misses the commit that applies it.
        final proposal = await alice.proposeAdd(
          groupIdBytes: group,
          signerBytes: aliceId.signerBytes,
          keyPackageBytes: await keyPackage(carol, carolId),
        );
        await bob.processMessage(
          groupIdBytes: group,
          messageBytes: proposal.proposalMessage,
        );
        await alice.commitToPendingProposals(
          groupIdBytes: group,
          signerBytes: aliceId.signerBytes,
        );
        await alice.mergePendingCommit(groupIdBytes: group);
        final groupInfo = await alice.exportGroupInfo(
          groupIdBytes: group,
          signerBytes: aliceId.signerBytes,
        );
        final tree = await alice.exportRatchetTree(groupIdBytes: group);

        Future<ExternalJoinResult> rejoin({bool? replace}) => v2
            ? bob.joinGroupExternalCommitV2(
                config: defaultConfig(),
                groupInfoBytes: groupInfo,
                ratchetTreeBytes: tree,
                signerBytes: bobId.signerBytes,
                credentialIdentity: bobId.credentialIdentity,
                signerPublicKey: bobId.publicKey,
                skipLifetimeValidation: false,
                replaceStoredGroup: replace,
              )
            : bob.joinGroupExternalCommit(
                config: defaultConfig(),
                groupInfoBytes: groupInfo,
                ratchetTreeBytes: tree,
                signerBytes: bobId.signerBytes,
                credentialIdentity: bobId.credentialIdentity,
                signerPublicKey: bobId.publicKey,
                replaceStoredGroup: replace,
              );

        await expectLater(rejoin(), refusedUntold);
        await expectLater(rejoin(replace: false), refusedUntold);
        expect(await bob.groupEpoch(groupIdBytes: group), BigInt.one);
        expect(
          await bob.groupPendingProposals(groupIdBytes: group),
          hasLength(1),
        );

        final joined = await rejoin(replace: true);
        if (!v2) await bob.mergePendingCommit(groupIdBytes: group);
        await alice.processMessage(
          groupIdBytes: group,
          messageBytes: joined.commit,
        );
        expect(
          await bob.groupEpoch(groupIdBytes: group),
          await alice.groupEpoch(groupIdBytes: group),
        );
        expect(await bob.groupPendingProposals(groupIdBytes: group), isEmpty);
        // With the old proposal gone, Bob commits again.
        await bob.selfUpdate(
          groupIdBytes: group,
          signerBytes: bobId.signerBytes,
        );
      });
    }
  });
}
