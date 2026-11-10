import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

/// An application's own extension type, from the private-use range.
const _appExtensionType = 0xff0a;

/// The self_remove proposal type (draft-ietf-mls-extensions).
const _selfRemoveProposal = 0x000a;

void groupCapabilities() {
  group('groups', () {
    capability('a new group holds its creator alone, at epoch 0', () async {
      final alice = await Party.create('alice');
      final group = await alice.createGroup();

      expect(await alice.engine.groupId(groupIdBytes: group), group);
      expect(await alice.epochOf(group), BigInt.zero);
      expect(await alice.engine.groupIsActive(groupIdBytes: group), isTrue);
      final members = await alice.engine.groupMembers(groupIdBytes: group);
      expect(members.single.signatureKey, alice.publicKey);
      expect(members.single.credential, alice.credential);
    });

    capability('a group gets the ID it is given, from either way of '
        'creating one', () async {
      final alice = await Party.create('alice');
      final plain = bytesOf('a group ID of our own');
      final built = bytesOf('another one, from the builder');

      final created = await alice.engine.createGroup(
        config: alice.config,
        signerBytes: alice.signer,
        credentialIdentity: alice.identity,
        signerPublicKey: alice.publicKey,
        groupId: plain,
      );
      expect(created.groupId, plain);

      final fromBuilder = await alice.engine.createGroupWithBuilder(
        config: alice.config,
        signerBytes: alice.signer,
        credentialIdentity: alice.identity,
        signerPublicKey: alice.publicKey,
        groupId: built,
        lifetimeSeconds: BigInt.from(3600),
      );
      expect(fromBuilder.groupId, built);
      expect(await alice.epochOf(built), BigInt.zero);

      // The builder's group is a working group: Bob joins it.
      final bob = await Party.create('bob');
      final added = await alice.engine.addMembers(
        groupIdBytes: built,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: built);
      expect(await bob.join(added.welcome), built);
    });

    capability('a newcomer reads a Welcome before joining, and joins the '
        'group it read', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await alice.createGroup();
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);

      final inspected = await bob.engine.inspectWelcome(
        config: bob.config,
        welcomeBytes: added.welcome,
      );
      expect(inspected.groupId, group);
      expect(inspected.ciphersuite, defaultSuite);
      expect(inspected.epoch, BigInt.one);
      expect(inspected.pskCount, 0);

      final context = bytesOf('context');
      final fromWelcome = await bob.engine.exportWelcomeSecret(
        config: bob.config,
        welcomeBytes: added.welcome,
        label: 'exporter',
        context: context,
        keyLength: 32,
      );

      // Neither read used up the key package the Welcome is addressed to.
      expect(await bob.join(added.welcome), group);
      final fromGroup = await bob.engine.exportSecret(
        groupIdBytes: group,
        label: 'exporter',
        context: context,
        keyLength: 32,
      );
      final fromAlice = await alice.engine.exportSecret(
        groupIdBytes: group,
        label: 'exporter',
        context: context,
        keyLength: 32,
      );
      expect(fromWelcome, fromGroup);
      expect(fromWelcome, fromAlice);
    });

    capability('extensions for the GroupInfo reach the newcomer before it '
        'joins, with the member that signed them', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await alice.createGroup();
      final extension = MlsExtension(
        extensionType: _appExtensionType,
        data: bytesOf('for the new epoch'),
      );

      final commit = await alice.engine.flexibleCommit(
        groupIdBytes: group,
        signerBytes: alice.signer,
        options: FlexibleCommitOptions(
          addKeyPackages: [await bob.keyPackage()],
          removeIndices: Uint32List(0),
          forceSelfUpdate: false,
          consumePendingProposals: false,
          createGroupInfo: false,
          useRatchetTreeExtension: true,
          keepPending: false,
          groupInfoExtensions: [extension],
        ),
      );

      final read = await bob.engine.welcomeGroupInfoExtensions(
        config: bob.config,
        welcomeBytes: commit.welcome!,
      );
      expect(read.extensions.single.extensionType, _appExtensionType);
      expect(read.extensions.single.data, extension.data);
      // Alice signed the GroupInfo, from her leaf, index 0 of the new tree.
      expect(read.signer.index, 0);
      expect(read.signer.signatureKey, alice.publicKey);
      expect(read.signer.credential, alice.credential);

      // Reading wrote nothing: the key package is still there for the join.
      expect(await bob.join(commit.welcome!), group);
    });

    capability('a newcomer can join with the lifetime checks left '
        'out', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await alice.createGroup();
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);

      final joined = await bob.engine.joinGroupFromWelcomeWithOptions(
        config: bob.config,
        welcomeBytes: added.welcome,
        signerBytes: bob.signer,
        skipLifetimeValidation: true,
      );
      expect(joined.groupId, group);
      expect(await bob.engine.groupMembers(groupIdBytes: group), hasLength(2));
      final hello = await bob.send(group, 'hello from the newcomer');
      final received = await alice.receive(group, hello);
      expect(textOf(received.applicationMessage!), 'hello from the newcomer');
    });

    for (final v2 in [false, true]) {
      capability('a newcomer joins by external commit${v2 ? ' (v2)' : ''}, '
          'from what a member exported', () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final group = await alice.createGroup();
        final groupInfo = await alice.engine.exportGroupInfo(
          groupIdBytes: group,
          signerBytes: alice.signer,
        );
        final tree = await alice.engine.exportRatchetTree(groupIdBytes: group);

        final joined = v2
            ? await bob.engine.joinGroupExternalCommitV2(
                config: bob.config,
                groupInfoBytes: groupInfo,
                ratchetTreeBytes: tree,
                signerBytes: bob.signer,
                credentialIdentity: bob.identity,
                signerPublicKey: bob.publicKey,
                aad: bytesOf('joining from outside'),
                skipLifetimeValidation: false,
              )
            : await bob.engine.joinGroupExternalCommit(
                config: bob.config,
                groupInfoBytes: groupInfo,
                ratchetTreeBytes: tree,
                signerBytes: bob.signer,
                credentialIdentity: bob.identity,
                signerPublicKey: bob.publicKey,
              );
        expect(joined.groupId, group);

        final processed = await alice.receive(group, joined.commit);
        expect(processed.messageType, ProcessedMessageType.stagedCommit);
        expect(await alice.epochOf(group), BigInt.one);
        expect(await bob.epochOf(group), BigInt.one);
        for (final party in [alice, bob]) {
          final members = await party.engine.groupMembers(groupIdBytes: group);
          expect(
            [for (final member in members) member.signatureKey],
            [alice.publicKey, bob.publicKey],
          );
        }

        final hello = await bob.send(group, 'in by external commit');
        expect(
          textOf((await alice.receive(group, hello)).applicationMessage!),
          'in by external commit',
        );
      });
    }

    capability('a member that leaves is out once another one commits '
        'it', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);

      final leaving = await bob.engine.leaveGroup(
        groupIdBytes: group,
        signerBytes: bob.signer,
      );
      final proposal = await alice.receive(group, leaving.message);
      expect(proposal.messageType, ProcessedMessageType.proposal);
      expect(proposal.proposalType, MlsProposalType.remove);

      final commit = await alice.engine.commitToPendingProposals(
        groupIdBytes: group,
        signerBytes: alice.signer,
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);
      await bob.receive(group, commit.commit);

      expect(await bob.engine.groupIsActive(groupIdBytes: group), isFalse);
      final members = await alice.engine.groupMembers(groupIdBytes: group);
      expect(members.single.signatureKey, alice.publicKey);
    });

    capability('a member can leave by a self-remove proposal, where every '
        'member supports one', () async {
      // OpenMLS sends a SelfRemove proposal only as a plaintext message, so
      // the group sends its handshakes in the clear.
      final config = MlsGroupConfig(
        ciphersuite: defaultSuite,
        wireFormatPolicy: MlsWireFormatPolicy.plaintext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      // And it is a proposal type of the MLS extensions, which a commit may
      // carry only when every member's leaf lists it: the default
      // capabilities do not.
      final selfRemove = MlsCapabilities(
        versions: Uint16List(0),
        ciphersuites: Uint16List(0),
        extensions: Uint16List(0),
        proposals: Uint16List.fromList([_selfRemoveProposal]),
        credentials: Uint16List(0),
      );
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = (await alice.engine.createGroupWithBuilder(
        config: config,
        signerBytes: alice.signer,
        credentialIdentity: alice.identity,
        signerPublicKey: alice.publicKey,
        capabilities: selfRemove,
      )).groupId;
      final bobPackage = await bob.engine.createKeyPackageWithOptions(
        ciphersuite: defaultSuite,
        signerBytes: bob.signer,
        credentialIdentity: bob.identity,
        signerPublicKey: bob.publicKey,
        options: KeyPackageOptions(lastResort: false, capabilities: selfRemove),
      );
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [bobPackage.keyPackageBytes],
      );
      expect(await bob.join(added.welcome, config: config), group);

      final leaving = await bob.engine.leaveGroupViaSelfRemove(
        groupIdBytes: group,
        signerBytes: bob.signer,
      );
      final proposal = await alice.receive(group, leaving.message);
      expect(proposal.messageType, ProcessedMessageType.proposal);

      final commit = await alice.engine.commitToPendingProposals(
        groupIdBytes: group,
        signerBytes: alice.signer,
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);
      await bob.receive(group, commit.commit);

      expect(await bob.engine.groupIsActive(groupIdBytes: group), isFalse);
      expect(
        await alice.engine.groupMembers(groupIdBytes: group),
        hasLength(1),
      );
    });

    capability('a deleted group is gone from its engine', () async {
      final alice = await Party.create('alice');
      final group = await alice.createGroup();

      await alice.engine.deleteGroup(groupIdBytes: group);

      await expectLater(
        alice.engine.groupIsActive(groupIdBytes: group),
        throwsA(anything),
      );
      await expectLater(
        alice.engine.deleteGroup(groupIdBytes: group),
        throwsA(anything),
        reason: 'there is nothing left to delete',
      );
    });

    capability('a closed engine refuses work, and says why', () async {
      final alice = await Party.create('alice');
      final group = await alice.createGroup();
      expect(alice.engine.schemaVersion(), 1);
      expect(alice.engine.isClosed(), isFalse);

      await alice.engine.close();
      expect(alice.engine.isClosed(), isTrue);
      // Closing again is allowed: the capability's teardown does it too.
      await alice.engine.close();
      await expectLater(
        alice.engine.groupEpoch(groupIdBytes: group),
        throwsA(predicate((error) => '$error'.contains('MlsEngine is closed'))),
      );
    });
  });
}
