// Proposals: one member proposes, another commits, and in between the proposal
// waits in each member's store. Then the commits an application assembles from
// options with flexibleCommit, one of them kept pending until the delivery
// service has accepted it.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';
import '../support/refs.dart';

/// Proposals, the store that holds them, and the commits built from them.
void proposalCapabilities() {
  group('proposals', () {
    capability(
      'an Add proposal waits in the store, by its sender, until another member '
      'commits it and the newcomer joins',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob]);
        expect(
          await alice.engine.groupHasPendingProposals(groupIdBytes: group),
          isFalse,
        );

        final proposal = await bob.engine.proposeAdd(
          groupIdBytes: group,
          signerBytes: bob.signer,
          keyPackageBytes: await carol.keyPackage(),
        );
        // The proposer keeps it, and so does each member it reaches.
        const addByBob = [
          MlsPendingProposalInfo(
            proposalType: MlsProposalType.add,
            senderIndex: 1,
          ),
        ];
        expect(
          await bob.engine.groupPendingProposals(groupIdBytes: group),
          addByBob,
        );
        final received = await alice.receive(group, proposal.proposalMessage);
        expect(received.messageType, ProcessedMessageType.proposal);
        expect(received.proposalType, MlsProposalType.add);
        expect(received.senderIndex, 1);
        expect(
          await alice.engine.groupHasPendingProposals(groupIdBytes: group),
          isTrue,
        );
        expect(
          await alice.engine.groupPendingProposals(groupIdBytes: group),
          addByBob,
        );
        // A proposal changes nothing by itself.
        expect(await alice.epochOf(group), BigInt.one);

        final commit = await alice.engine.commitToPendingProposals(
          groupIdBytes: group,
          signerBytes: alice.signer,
        );
        await bob.receive(group, commit.commit);
        expect(await carol.join(commit.welcome!), group);

        await _expectInSync(
          [alice, bob, carol],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob', 2: 'carol'},
        );
        for (final party in [alice, bob]) {
          expect(
            await party.engine.groupHasPendingProposals(groupIdBytes: group),
            isFalse,
            reason: 'the store of ${party.name}, once the commit is in',
          );
        }
      },
    );

    capability(
      'Remove proposals name a member by leaf or by credential, and the commit '
      'that carries them removes both',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final dave = await Party.create('dave');
        final group = await groupOf(alice, [bob, carol, dave]);

        final byLeaf = await bob.engine.proposeRemove(
          groupIdBytes: group,
          signerBytes: bob.signer,
          memberIndex: 2,
        );
        final byCredential = await bob.engine.proposeRemoveMemberByCredential(
          groupIdBytes: group,
          signerBytes: bob.signer,
          credentialBytes: dave.credential,
        );

        // Whom each one takes out, as Alice reads it on arrival: the
        // credential resolved to the leaf that holds it.
        for (final (proposal, leaf, name) in [
          (byLeaf, 2, 'carol'),
          (byCredential, 3, 'dave'),
        ]) {
          final received = await alice.engine.processMessageWithInspect(
            groupIdBytes: group,
            messageBytes: proposal.proposalMessage,
          );
          expect(received.proposalType, MlsProposalType.remove);
          expect(received.senderIndex, 1);
          final removes = received.proposalInfo!.affectedMember!;
          expect(removes.index, leaf);
          expect(_identity(removes.credential), name);
          // A commit refers to a proposal by reference, so each member that
          // processes the commit has to hold it, the ones it removes included.
          await deliver(group, proposal.proposalMessage, [carol, dave]);
        }
        const removeByBob = MlsPendingProposalInfo(
          proposalType: MlsProposalType.remove,
          senderIndex: 1,
        );
        expect(
          await alice.engine.groupPendingProposals(groupIdBytes: group),
          const [removeByBob, removeByBob],
        );

        final commit = await alice.engine.commitToPendingProposals(
          groupIdBytes: group,
          signerBytes: alice.signer,
        );
        expect(commit.welcome, isNull);
        await deliver(group, commit.commit, [bob, carol, dave]);
        for (final removed in [carol, dave]) {
          expect(
            await removed.engine.groupIsActive(groupIdBytes: group),
            isFalse,
            reason: '${removed.name} is out',
          );
        }
        await _expectInSync(
          [alice, bob],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob'},
        );
      },
    );

    capability(
      'an Update proposal, committed by another member, puts its sender on the '
      'encryption key it announced',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob, carol]);
        final leaf = await bob.engine.groupOwnLeafNode(groupIdBytes: group);

        final proposal = await bob.engine.proposeSelfUpdate(
          groupIdBytes: group,
          signerBytes: bob.signer,
        );
        expect(await bob.engine.groupPendingProposals(groupIdBytes: group), [
          const MlsPendingProposalInfo(
            proposalType: MlsProposalType.update,
            senderIndex: 1,
          ),
        ]);
        // Alice reads the leaf it proposes next to the one it replaces: a new
        // encryption key under the same signature key.
        final received = await alice.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: proposal.proposalMessage,
        );
        expect(received.proposalType, MlsProposalType.update);
        final update = received.proposalInfo!;
        expect(update.affectedMember!.index, 1);
        expect(update.affectedMember!.signatureKey, bob.publicKey);
        expect(update.leaf!.signatureKey, bob.publicKey);
        final announced = update.leaf!.encryptionKey;
        expect(announced, isNot(leaf.encryptionKey));
        await carol.receive(group, proposal.proposalMessage);

        // An Update is carried by somebody else's commit.
        final commit = await alice.engine.commitToPendingProposals(
          groupIdBytes: group,
          signerBytes: alice.signer,
        );
        await deliver(group, commit.commit, [bob, carol]);
        await _expectInSync(
          [alice, bob, carol],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob', 2: 'carol'},
        );
        final renewed = await bob.engine.groupOwnLeafNode(groupIdBytes: group);
        expect(renewed.encryptionKey, announced);
        expect(renewed.signatureKey, bob.publicKey);
      },
    );

    capability(
      'an Update proposal with a new signer, committed by another member, '
      'moves its sender to the new key and credential',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final group = await groupOf(alice, [bob]);
        final rotated = _newSigner('alice-rotated');

        // The envelope is signed with the key Alice's leaf still has, the leaf
        // inside it with the new one.
        final proposal = await alice.engine.proposeSelfUpdateWithNewSigner(
          groupIdBytes: group,
          oldSignerBytes: alice.signer,
          newSignerBytes: rotated.signer,
          newCredentialIdentity: rotated.identity,
          newSignerPublicKey: rotated.publicKey,
        );
        expect(await alice.engine.groupPendingProposals(groupIdBytes: group), [
          const MlsPendingProposalInfo(
            proposalType: MlsProposalType.update,
            senderIndex: 0,
          ),
        ]);
        final received = await bob.receive(group, proposal.proposalMessage);
        expect(received.messageType, ProcessedMessageType.proposal);
        expect(received.proposalType, MlsProposalType.update);
        expect(received.senderIndex, 0);

        final commit = await bob.engine.commitToPendingProposals(
          groupIdBytes: group,
          signerBytes: bob.signer,
        );
        await alice.receive(group, commit.commit);
        await _expectInSync(
          [alice, bob],
          group,
          epoch: 2,
          names: {0: 'alice-rotated', 1: 'bob'},
        );
        for (final viewer in [alice, bob]) {
          expect(
            (await _signatureKeys(viewer, group))[0],
            rotated.publicKey,
            reason: "Alice's signature key as ${viewer.name} has it",
          );
        }

        // From here on Alice signs with the new key, and that is what verifies.
        final message = await alice.engine.createMessage(
          groupIdBytes: group,
          signerBytes: rotated.signer,
          message: bytesOf('after rotation'),
        );
        final read = await bob.receive(group, message.ciphertext);
        expect(read.senderIndex, 0);
        expect(textOf(read.applicationMessage!), 'after rotation');
      },
    );

    capability(
      'a GroupContextExtensions proposal, carried by reference in another '
      "member's commit, sets the group context of all",
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob, carol]);
        final before = await alice.engine.groupExtensions(groupIdBytes: group);
        final deliveryService = MlsSignatureKeyPair.generate(
          ciphersuite: defaultSuite,
        ).publicKey();
        final senders = _externalSenders(deliveryService, 'delivery-service');
        expect(
          decodeExternalSenders(data: senders.data).single.signatureKey,
          deliveryService,
        );

        final proposal = await bob.engine.proposeGroupContextExtensions(
          groupIdBytes: group,
          signerBytes: bob.signer,
          extensions: [senders],
        );
        await deliver(group, proposal.proposalMessage, [alice, carol]);
        expect(await alice.engine.groupPendingProposals(groupIdBytes: group), [
          const MlsPendingProposalInfo(
            proposalType: MlsProposalType.groupContextExtensions,
            senderIndex: 1,
          ),
        ]);
        // Proposed, not yet applied.
        expect(await alice.engine.groupExtensions(groupIdBytes: group), before);

        final commit = await alice.engine.commitToPendingProposals(
          groupIdBytes: group,
          signerBytes: alice.signer,
        );
        final info = (await carol.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: commit.commit,
        )).stagedCommitInfo!;
        final carried = info.proposals.single;
        expect(carried.proposalType, MlsProposalType.groupContextExtensions);
        expect(carried.senderIndex, 1);
        expect(carried.byReference, isTrue);
        final admitted = info.externalSenders.single;
        expect(admitted.signatureKey, deliveryService);
        expect(_identity(admitted.credential), 'delivery-service');
        await bob.receive(group, commit.commit);

        await _expectInSync(
          [alice, bob, carol],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob', 2: 'carol'},
        );
        final after = await alice.engine.groupExtensions(groupIdBytes: group);
        expect(after, isNot(before));
        for (final member in [bob, carol]) {
          expect(
            await member.engine.groupExtensions(groupIdBytes: group),
            after,
            reason: 'group context extensions of ${member.name}',
          );
        }
      },
    );

    capability(
      'proposals wait in the store by type and sender until withdrawn, which '
      'moves no epoch',
      () async {
        final alice = await Party.create('alice');
        final group = await alice.createGroup();
        expect(
          await alice.engine.groupHasPendingProposals(groupIdBytes: group),
          isFalse,
        );

        // Neither is committed here: no pre-shared key is stored for the
        // first, and no member advertises the type of the second.
        await alice.engine.proposeExternalPsk(
          groupIdBytes: group,
          signerBytes: alice.signer,
          pskId: bytesOf('psk-id'),
          pskNonce: _nonce(),
        );
        await alice.engine.proposeCustomProposal(
          groupIdBytes: group,
          signerBytes: alice.signer,
          proposalType: 0xF001, // private use
          payload: bytesOf('custom-data'),
        );
        const pending = [
          MlsPendingProposalInfo(
            proposalType: MlsProposalType.preSharedKey,
            senderIndex: 0,
          ),
          MlsPendingProposalInfo(
            proposalType: MlsProposalType.custom,
            senderIndex: 0,
          ),
        ];
        expect(
          await alice.engine.groupHasPendingProposals(groupIdBytes: group),
          isTrue,
        );
        expect(
          await alice.engine.groupPendingProposals(groupIdBytes: group),
          unorderedEquals(pending),
        );

        // Bytes that are no proposal reference are refused before anything
        // in the store is touched.
        await expectLater(
          alice.engine.removePendingProposal(
            groupIdBytes: group,
            proposalRefBytes: [1, 2, 3],
          ),
          throwsA(isA<Object>()),
        );
        expect(
          await alice.engine.groupPendingProposals(groupIdBytes: group),
          unorderedEquals(pending),
        );

        await alice.engine.clearPendingProposals(groupIdBytes: group);
        expect(
          await alice.engine.groupHasPendingProposals(groupIdBytes: group),
          isFalse,
        );
        expect(
          await alice.engine.groupPendingProposals(groupIdBytes: group),
          isEmpty,
        );
        expect(await alice.epochOf(group), BigInt.zero);
      },
    );

    capability(
      'a pending proposal is withdrawn by its reference, and only that one',
      () async {
        // The reference is made from the message (support/refs.dart), which
        // takes the message in the clear: this group sends its handshake
        // messages as plaintext.
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
        final alice = await Party.create('alice');
        final group = await alice.createGroup(config: config);
        final psk = await alice.engine.proposeExternalPsk(
          groupIdBytes: group,
          signerBytes: alice.signer,
          pskId: bytesOf('psk-id'),
          pskNonce: _nonce(),
        );
        await alice.engine.proposeCustomProposal(
          groupIdBytes: group,
          signerBytes: alice.signer,
          proposalType: 0xF001, // private use
          payload: bytesOf('custom-data'),
        );

        // The reference the engine returns is the one RFC 9420 §5.2 makes
        // from the message.
        final reference = psk.proposalRef;
        expect(reference, proposalRef(psk.proposalMessage));
        await alice.engine.removePendingProposal(
          groupIdBytes: group,
          proposalRefBytes: reference,
        );
        expect(await alice.engine.groupPendingProposals(groupIdBytes: group), [
          const MlsPendingProposalInfo(
            proposalType: MlsProposalType.custom,
            senderIndex: 0,
          ),
        ]);
        // It is gone: withdrawing it again finds nothing to take.
        await expectLater(
          alice.engine.removePendingProposal(
            groupIdBytes: group,
            proposalRefBytes: reference,
          ),
          throwsA(anything),
        );
        expect(await alice.epochOf(group), BigInt.zero);
      },
    );

    capability(
      "a custom proposal under a type that is not the application's own is "
      'refused, and nothing is stored',
      () async {
        final alice = await Party.create('alice');
        final group = await alice.createGroup();
        // Add, Remove, one the MLS extensions draft takes that OpenMLS reads
        // as custom, SelfRemove, and a GREASE value (RFC 9420 §13.5).
        for (final type in [1, 3, 0x0008, 0x000a, 0x0A0A]) {
          await expectLater(
            alice.engine.proposeCustomProposal(
              groupIdBytes: group,
              signerBytes: alice.signer,
              proposalType: type,
              payload: bytesOf('not really custom'),
            ),
            throwsA(anything),
            reason: 'type $type',
          );
        }
        expect(
          await alice.engine.groupHasPendingProposals(groupIdBytes: group),
          isFalse,
        );
      },
    );

    capability(
      'a commit kept pending changes nothing until mergePendingCommit applies '
      'it',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final dave = await Party.create('dave');
        final group = await groupOf(alice, [bob, carol]);
        final names = {0: 'alice', 1: 'bob', 2: 'carol'};

        final commit = await alice.engine.flexibleCommit(
          groupIdBytes: group,
          signerBytes: alice.signer,
          options: FlexibleCommitOptions(
            addKeyPackages: [await dave.keyPackage()],
            removeIndices: Uint32List(0),
            forceSelfUpdate: false,
            consumePendingProposals: true,
            createGroupInfo: true,
            // The Welcome carries the tree, so Dave needs nothing else.
            useRatchetTreeExtension: true,
            keepPending: true,
          ),
        );
        expect(commit.welcome, isNotNull);
        expect(commit.groupInfo, isNotNull);
        // Alice has not moved: the same epoch, the same members.
        expect(await alice.epochOf(group), BigInt.one);
        expect(await _names(alice, group), names);

        // The delivery service accepted the commit and handed it out. Only
        // then does Alice merge it, and send the Welcome.
        await deliver(group, commit.commit, [bob, carol]);
        await alice.engine.mergePendingCommit(groupIdBytes: group);
        expect(await dave.join(commit.welcome!), group);

        await _expectInSync(
          [alice, bob, carol, dave],
          group,
          epoch: 2,
          names: {...names, 3: 'dave'},
        );
      },
    );

    capability(
      'clearPendingCommit drops a commit kept pending: the epoch stays, and '
      'the group goes on from there',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final group = await groupOf(alice, [bob]);
        final leaf = await alice.engine.groupOwnLeafNode(groupIdBytes: group);

        await alice.engine.flexibleCommit(
          groupIdBytes: group,
          signerBytes: alice.signer,
          options: _selfUpdate(keepPending: true),
        );
        // One pending commit at a time, kept pending or not.
        for (final keepPending in [true, false]) {
          await expectLater(
            alice.engine.flexibleCommit(
              groupIdBytes: group,
              signerBytes: alice.signer,
              options: _selfUpdate(keepPending: keepPending),
            ),
            throwsA(predicate((error) => '$error'.contains('already pending'))),
          );
        }

        await alice.engine.clearPendingCommit(groupIdBytes: group);
        // As if it had never been made: the same epoch, the same leaf, and a
        // message in that epoch reads.
        expect(await alice.epochOf(group), BigInt.one);
        expect(
          (await alice.engine.groupOwnLeafNode(
            groupIdBytes: group,
          )).encryptionKey,
          leaf.encryptionKey,
        );
        final message = await alice.send(group, 'same epoch');
        expect(
          textOf((await bob.receive(group, message)).applicationMessage!),
          'same epoch',
        );

        // The next commit goes through, merged at once without keepPending,
        // and forceSelfUpdate renews the leaf this time.
        final next = await alice.engine.flexibleCommit(
          groupIdBytes: group,
          signerBytes: alice.signer,
          options: _selfUpdate(keepPending: false),
        );
        expect(await alice.epochOf(group), BigInt.two);
        await bob.receive(group, next.commit);
        await _expectInSync(
          [alice, bob],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob'},
        );
        expect(
          (await alice.engine.groupOwnLeafNode(
            groupIdBytes: group,
          )).encryptionKey,
          isNot(leaf.encryptionKey),
        );
      },
    );

    capability(
      'flexibleCommit carries what its options name: a removal in, the '
      'pending proposals left out, no GroupInfo unless asked for',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final dave = await Party.create('dave');
        final group = await groupOf(alice, [bob, carol]);
        final proposal = await bob.engine.proposeAdd(
          groupIdBytes: group,
          signerBytes: bob.signer,
          keyPackageBytes: await dave.keyPackage(),
        );
        await alice.receive(group, proposal.proposalMessage);
        expect(await alice.engine.groupPendingProposals(groupIdBytes: group), [
          const MlsPendingProposalInfo(
            proposalType: MlsProposalType.add,
            senderIndex: 1,
          ),
        ]);

        final commit = await alice.engine.flexibleCommit(
          groupIdBytes: group,
          signerBytes: alice.signer,
          options: FlexibleCommitOptions(
            addKeyPackages: const [],
            removeIndices: Uint32List.fromList([2]),
            forceSelfUpdate: false,
            consumePendingProposals: false,
            createGroupInfo: false,
            useRatchetTreeExtension: false,
          ),
        );
        // Bob's Add stayed out of it, so nobody is invited; and no GroupInfo
        // was asked for.
        expect(commit.welcome, isNull);
        expect(commit.groupInfo, isNull);

        final info = (await bob.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: commit.commit,
        )).stagedCommitInfo!;
        expect(info.addCredentials, isEmpty);
        expect(info.removeIndices, [2]);
        final removal = info.proposals.single;
        expect(removal.proposalType, MlsProposalType.remove);
        expect(removal.byReference, isFalse);
        expect(removal.senderIndex, 0);

        // Carol is out, and Dave never came in.
        await _expectInSync(
          [alice, bob],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob'},
        );
      },
    );
  });
}

/// Checks that [parties] are all in [epoch] of [group], on one key schedule and
/// one tree, with the members [names] lists at the leaves it gives them.
Future<void> _expectInSync(
  List<Party> parties,
  List<int> group, {
  required int epoch,
  required Map<int, String> names,
}) async {
  final first = parties.first.engine;
  final authenticator = await first.groupEpochAuthenticator(
    groupIdBytes: group,
  );
  final treeHash = (await first.exportGroupContext(
    groupIdBytes: group,
  )).treeHash;
  for (final party in parties) {
    final engine = party.engine;
    expect(
      await party.epochOf(group),
      BigInt.from(epoch),
      reason: 'epoch of ${party.name}',
    );
    expect(
      await engine.groupEpochAuthenticator(groupIdBytes: group),
      authenticator,
      reason: 'epoch authenticator of ${party.name}',
    );
    expect(
      (await engine.exportGroupContext(groupIdBytes: group)).treeHash,
      treeHash,
      reason: 'tree hash of ${party.name}',
    );
    expect(
      await _names(party, group),
      names,
      reason: 'members as ${party.name} has them',
    );
  }
}

/// The identity at each leaf of [group], by leaf index, as [viewer] has it.
Future<Map<int, String>> _names(Party viewer, List<int> group) async => {
  for (final member in await viewer.engine.groupMembers(groupIdBytes: group))
    member.index: _identity(member.credential),
};

/// The signature key at each leaf of [group], by leaf index, as [viewer] has
/// it.
Future<Map<int, Uint8List>> _signatureKeys(
  Party viewer,
  List<int> group,
) async => {
  for (final member in await viewer.engine.groupMembers(groupIdBytes: group))
    member.index: member.signatureKey,
};

/// The identity a TLS-serialized basic credential names.
String _identity(List<int> credential) =>
    textOf(MlsCredential.deserialize(bytes: credential).identity());

/// A new key pair for a member to move to, as the engine takes it, and the
/// identity of the basic credential that goes with it.
({Uint8List signer, Uint8List publicKey, Uint8List identity}) _newSigner(
  String name,
) {
  final keys = MlsSignatureKeyPair.generate(ciphersuite: defaultSuite);
  return (
    signer: serializeSigner(
      ciphersuite: defaultSuite,
      privateKey: keys.privateKey(),
      publicKey: keys.publicKey(),
    ),
    publicKey: keys.publicKey(),
    identity: bytesOf(name),
  );
}

/// An ExternalSenders extension (RFC 9420, 12.1.8.1) admitting one party: its
/// [signatureKey], and a basic credential naming it [name].
///
/// It is a type OpenMLS takes into a group context without any member listing
/// it among its capabilities, which a default key package does not do for an
/// application's own types.
MlsExtension _externalSenders(List<int> signatureKey, String name) {
  final credential = MlsCredential.basic(identity: bytesOf(name)).serialize();
  // The signature key, then the credential; the list behind a one-byte length
  // while it is under 64 bytes.
  final sender = [signatureKey.length, ...signatureKey, ...credential];
  expect(sender.length, lessThan(64));
  return MlsExtension(
    extensionType: 0x0005,
    data: Uint8List.fromList([sender.length, ...sender]),
  );
}

/// The options of a commit that only renews the committer's own leaf.
FlexibleCommitOptions _selfUpdate({required bool keepPending}) =>
    FlexibleCommitOptions(
      addKeyPackages: const [],
      removeIndices: Uint32List(0),
      forceSelfUpdate: true,
      consumePendingProposals: false,
      createGroupInfo: false,
      useRatchetTreeExtension: false,
      keepPending: keepPending,
    );

/// A nonce for a pre-shared key: random, as long as the suite's hash output
/// (RFC 9420, 8.4).
Uint8List _nonce() {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
}
