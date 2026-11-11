import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

/// An application's own extension type, from the private-use range.
const _appExtensionType = 0xff0a;

/// The self_remove proposal type (draft-ietf-mls-extensions).
const _selfRemoveProposal = 0x000a;

/// The refusal of a create or a Welcome under a group ID the engine stores:
/// that one, and not any failure on the way.
final _storedIdRefused = throwsA(
  predicate(
    (e) => '$e'.contains('already exists') && '$e'.contains('deleteGroup'),
  ),
);

/// The refusal of an external join into a group the engine stores, unless
/// told to replace it: that one, and not a stored group that fails to load.
final _externalJoinRefused = throwsA(
  predicate(
    (e) =>
        '$e'.contains('already exists') && '$e'.contains('replaceStoredGroup'),
  ),
);

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

    capability('a deleted group takes only its own state with it', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final deleted = bytesOf('group');
      // An ID that starts with the deleted one's: a purge that matched keys
      // by prefix would take this one too.
      final kept = bytesOf('group-and-more');
      for (final id in [deleted, kept]) {
        await alice.engine.createGroup(
          config: alice.config,
          signerBytes: alice.signer,
          credentialIdentity: alice.identity,
          signerPublicKey: alice.publicKey,
          groupId: id,
        );
      }
      final added = await alice.engine.addMembers(
        groupIdBytes: kept,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      expect(await bob.join(added.welcome), kept);

      await alice.engine.deleteGroup(groupIdBytes: deleted);

      await expectLater(
        alice.engine.groupIsActive(groupIdBytes: deleted),
        throwsA(anything),
      );
      await expectLater(
        alice.engine.deleteGroup(groupIdBytes: deleted),
        throwsA(anything),
        reason: 'there is nothing left to delete',
      );
      // The other group is whole, and goes on working.
      expect(await alice.epochOf(kept), BigInt.one);
      expect(await alice.engine.groupMembers(groupIdBytes: kept), hasLength(2));
      final hello = await alice.send(kept, 'still here');
      expect(
        textOf((await bob.receive(kept, hello)).applicationMessage!),
        'still here',
      );
    });

    capability('the engine lists every group it stores, an inactive one '
        'too, until it is deleted', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      expect(await alice.engine.groupIds(), isEmpty);

      final first = await alice.createGroup();
      final second = await alice.createGroup();
      final bobs = await groupOf(bob, [alice]);
      expect(
        await alice.engine.groupIds(),
        unorderedEquals([first, second, bobs]),
      );

      // Removed from Bob's group, Alice still stores it, inactive.
      final removal = await bob.engine.removeMembers(
        groupIdBytes: bobs,
        signerBytes: bob.signer,
        memberIndices: [1],
      );
      await alice.receive(bobs, removal.commit);
      expect(await alice.engine.groupIsActive(groupIdBytes: bobs), isFalse);
      expect(
        await alice.engine.groupIds(),
        unorderedEquals([first, second, bobs]),
      );

      await alice.engine.deleteGroup(groupIdBytes: bobs);
      expect(await alice.engine.groupIds(), unorderedEquals([first, second]));
      expect(await bob.engine.groupIds(), [bobs]);
    });

    capability('a group ID this engine already stores is refused, to a '
        'create and to a Welcome, and the refusal writes nothing', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final id = bytesOf('a group ID in use');
      await alice.engine.createGroup(
        config: alice.config,
        signerBytes: alice.signer,
        credentialIdentity: alice.identity,
        signerPublicKey: alice.publicKey,
        groupId: id,
      );

      await expectLater(
        alice.engine.createGroup(
          config: alice.config,
          signerBytes: alice.signer,
          credentialIdentity: alice.identity,
          signerPublicKey: alice.publicKey,
          groupId: id,
        ),
        _storedIdRefused,
      );
      await expectLater(
        alice.engine.createGroupWithBuilder(
          config: alice.config,
          signerBytes: alice.signer,
          credentialIdentity: alice.identity,
          signerPublicKey: alice.publicKey,
          groupId: id,
        ),
        _storedIdRefused,
      );

      // Bob makes a group of his own under the same ID and invites Alice.
      final package = await alice.keyPackage();
      final bobs = (await bob.engine.createGroup(
        config: bob.config,
        signerBytes: bob.signer,
        credentialIdentity: bob.identity,
        signerPublicKey: bob.publicKey,
        groupId: id,
      )).groupId;
      final invitation = await bob.engine.addMembers(
        groupIdBytes: bobs,
        signerBytes: bob.signer,
        keyPackagesBytes: [package],
      );
      // Reading the Welcome checks nothing against storage, as documented:
      // the reads go through, and the join after them is still refused.
      final inspected = await alice.engine.inspectWelcome(
        config: alice.config,
        welcomeBytes: invitation.welcome,
      );
      expect(inspected.groupId, id);
      await alice.engine.welcomeGroupInfoExtensions(
        config: alice.config,
        welcomeBytes: invitation.welcome,
      );
      await expectLater(alice.join(invitation.welcome), _storedIdRefused);
      await expectLater(
        alice.engine.joinGroupFromWelcomeWithOptions(
          config: alice.config,
          welcomeBytes: invitation.welcome,
          signerBytes: alice.signer,
          skipLifetimeValidation: true,
        ),
        _storedIdRefused,
      );

      // Her group is as it was.
      expect(await alice.epochOf(id), BigInt.zero);
      final members = await alice.engine.groupMembers(groupIdBytes: id);
      expect(members.single.signatureKey, alice.publicKey);
      // And the key package the refused Welcome was addressed to is still
      // there: a Welcome to it into another group joins.
      final other = await bob.createGroup();
      final second = await bob.engine.addMembers(
        groupIdBytes: other,
        signerBytes: bob.signer,
        keyPackagesBytes: [package],
      );
      expect(await alice.join(second.welcome), other);
    });

    for (final v2 in [false, true]) {
      capability(
        'an external join${v2 ? ' (v2)' : ''} into a group this '
        'engine stores is refused, and replaces it only when told to',
        () async {
          final alice = await Party.create('alice');
          final bob = await Party.create('bob');
          final carol = await Party.create('carol');
          final group = await groupOf(alice, [bob]);

          // Bob stores a proposal and misses the commit that applies it.
          final proposal = await alice.engine.proposeAdd(
            groupIdBytes: group,
            signerBytes: alice.signer,
            keyPackageBytes: await carol.keyPackage(),
          );
          await bob.receive(group, proposal.proposalMessage);
          await alice.engine.commitToPendingProposals(
            groupIdBytes: group,
            signerBytes: alice.signer,
          );
          await alice.engine.mergePendingCommit(groupIdBytes: group);
          final groupInfo = await alice.engine.exportGroupInfo(
            groupIdBytes: group,
            signerBytes: alice.signer,
          );
          final tree = await alice.engine.exportRatchetTree(
            groupIdBytes: group,
          );

          Future<ExternalJoinResult> rejoin({bool? replace}) => v2
              ? bob.engine.joinGroupExternalCommitV2(
                  config: bob.config,
                  groupInfoBytes: groupInfo,
                  ratchetTreeBytes: tree,
                  signerBytes: bob.signer,
                  credentialIdentity: bob.identity,
                  signerPublicKey: bob.publicKey,
                  skipLifetimeValidation: false,
                  replaceStoredGroup: replace,
                )
              : bob.engine.joinGroupExternalCommit(
                  config: bob.config,
                  groupInfoBytes: groupInfo,
                  ratchetTreeBytes: tree,
                  signerBytes: bob.signer,
                  credentialIdentity: bob.identity,
                  signerPublicKey: bob.publicKey,
                  replaceStoredGroup: replace,
                );

          await expectLater(rejoin(), _externalJoinRefused);
          await expectLater(rejoin(replace: false), _externalJoinRefused);
          // Nothing was written: Bob's group is where he left it.
          expect(await bob.epochOf(group), BigInt.one);
          expect(
            await bob.engine.groupPendingProposals(groupIdBytes: group),
            hasLength(1),
          );

          final joined = await rejoin(replace: true);
          expect(joined.groupId, group);
          if (!v2) {
            await bob.engine.mergePendingCommit(groupIdBytes: group);
          }
          await alice.receive(group, joined.commit);
          expect(await bob.epochOf(group), await alice.epochOf(group));
          // No proposal of the old group is left pending (OpenMLS refuses to
          // send a message while one is), and the group works.
          expect(
            await bob.engine.groupPendingProposals(groupIdBytes: group),
            isEmpty,
          );
          final hello = await bob.send(group, 'back in');
          expect(
            textOf((await alice.receive(group, hello)).applicationMessage!),
            'back in',
          );
        },
      );
    }

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
