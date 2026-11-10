// Who is in a group: members added, removed and swapped, a member renewing its
// own leaf, with or without a new signature key, and the extensions every
// member's group context carries. Each commit is checked from every member's
// side: the same epoch, key schedule and tree, and the same member at each leaf.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

/// The commits that change who is in a group, or what a member's leaf holds.
void membershipCapabilities() {
  group('membership', () {
    capability(
      'addMembers brings the members and each newcomer into one epoch, the '
      'committer on a new leaf key',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final dave = await Party.create('dave');
        final group = await groupOf(alice, [bob]);
        final leaf = await alice.engine.groupOwnLeafNode(groupIdBytes: group);

        final added = await alice.engine.addMembers(
          groupIdBytes: group,
          signerBytes: alice.signer,
          keyPackagesBytes: [await carol.keyPackage(), await dave.keyPackage()],
        );
        // Merged by the call: the committer is in the new epoch already.
        expect(await alice.epochOf(group), BigInt.two);

        final seen = await bob.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: added.commit,
        );
        expect(seen.messageType, ProcessedMessageType.stagedCommit);
        expect(seen.senderIndex, 0);
        final commit = seen.stagedCommitInfo!;
        expect(
          commit.addCredentials.map(_identity),
          unorderedEquals(['carol', 'dave']),
        );
        // A commit with a path, which brings the committer's renewed leaf.
        expect(_identity(commit.committerCredential!), 'alice');
        expect(await carol.join(added.welcome), group);
        expect(await dave.join(added.welcome), group);

        final everyone = [alice, bob, carol, dave];
        await _expectInSync(
          everyone,
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob', 2: 'carol', 3: 'dave'},
        );
        final keys = {
          for (final (index, party) in everyone.indexed) index: party.publicKey,
        };
        for (final viewer in everyone) {
          expect(
            await _signatureKeys(viewer, group),
            keys,
            reason: 'signature keys as ${viewer.name} has them',
          );
        }
        final renewed = await alice.engine.groupOwnLeafNode(
          groupIdBytes: group,
        );
        expect(renewed.encryptionKey, isNot(leaf.encryptionKey));
        expect(renewed.signatureKey, alice.publicKey);
      },
    );

    capability(
      'addMembersWithoutUpdate adds members with no path: the committer keeps '
      'the leaf it had',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob]);
        final leaf = await alice.engine.groupOwnLeafNode(groupIdBytes: group);

        final added = await alice.engine.addMembersWithoutUpdate(
          groupIdBytes: group,
          signerBytes: alice.signer,
          keyPackagesBytes: [await carol.keyPackage()],
        );
        final seen = await bob.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: added.commit,
        );
        final commit = seen.stagedCommitInfo!;
        expect(commit.addCredentials.map(_identity), ['carol']);
        // No path, so no committer's leaf comes with it.
        expect(commit.committerCredential, isNull);
        expect(await carol.join(added.welcome), group);

        await _expectInSync(
          [alice, bob, carol],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob', 2: 'carol'},
        );
        final kept = await alice.engine.groupOwnLeafNode(groupIdBytes: group);
        expect(kept.encryptionKey, leaf.encryptionKey);
      },
    );

    capability(
      'removeMembers takes a member out for everyone, and the removed member '
      'is out once it applies the commit',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob, carol]);

        final removed = await alice.engine.removeMembers(
          groupIdBytes: group,
          signerBytes: alice.signer,
          memberIndices: [1],
        );
        expect(removed.welcome, isNull);

        // Bob, before he applies it: the commit names him, and he is still in.
        final inspected = await bob.engine.inspectMessage(
          groupIdBytes: group,
          messageBytes: removed.commit,
        );
        final commit = inspected.stagedCommitInfo!;
        expect(commit.selfRemoved, isTrue);
        expect(commit.removeIndices, [1]);
        expect(commit.removeCredentials.map(_identity), ['bob']);
        expect(await bob.engine.groupIsActive(groupIdBytes: group), isTrue);

        await bob.receive(group, removed.commit);
        expect(await bob.engine.groupIsActive(groupIdBytes: group), isFalse);

        // Removing Bob blanks his leaf and moves nobody: Carol keeps leaf 2.
        await carol.receive(group, removed.commit);
        await _expectInSync(
          [alice, carol],
          group,
          epoch: 2,
          names: {0: 'alice', 2: 'carol'},
        );
      },
    );

    capability(
      'swapMembers replaces a member in one commit, the newcomer on the leaf '
      'it frees',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final dave = await Party.create('dave');
        final group = await groupOf(alice, [bob, carol]);

        final swapped = await alice.engine.swapMembers(
          groupIdBytes: group,
          signerBytes: alice.signer,
          removeIndices: [1],
          addKeyPackagesBytes: [await dave.keyPackage()],
        );
        await carol.receive(group, swapped.commit);
        expect(await dave.join(swapped.welcome), group);

        // Both changes in one epoch. Removals apply before additions, and an
        // addition takes the leftmost free leaf: the one Bob left.
        await _expectInSync(
          [alice, carol, dave],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'dave', 2: 'carol'},
        );
        expect((await _signatureKeys(carol, group))[1], dave.publicKey);
      },
    );

    capability(
      'selfUpdate gives the committer a new encryption key, and the other '
      'members hold it in their tree',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob, carol]);
        final before = await alice.engine.groupOwnLeafNode(groupIdBytes: group);
        // What the check below looks for, found where it should be: Bob's copy
        // of the tree holds Alice's current key.
        expect(
          _holds(
            await bob.engine.exportRatchetTree(groupIdBytes: group),
            before.encryptionKey,
          ),
          isTrue,
        );

        final updated = await alice.engine.selfUpdate(
          groupIdBytes: group,
          signerBytes: alice.signer,
        );
        await deliver(group, updated.commit, [bob, carol]);
        await _expectInSync(
          [alice, bob, carol],
          group,
          epoch: 2,
          names: {0: 'alice', 1: 'bob', 2: 'carol'},
        );

        // A new encryption key; the same signature key and credential.
        final after = await alice.engine.groupOwnLeafNode(groupIdBytes: group);
        expect(after.encryptionKey, isNot(before.encryptionKey));
        expect(after.signatureKey, before.signatureKey);
        expect(after.credential, before.credential);
        for (final member in [bob, carol]) {
          final tree = await member.engine.exportRatchetTree(
            groupIdBytes: group,
          );
          expect(
            _holds(tree, after.encryptionKey),
            isTrue,
            reason: "Alice's new key, in the tree of ${member.name}",
          );
          expect(
            _holds(tree, before.encryptionKey),
            isFalse,
            reason: "Alice's old key, in the tree of ${member.name}",
          );
        }
      },
    );

    capability(
      'selfUpdateWithNewSigner moves a member to a new signature key and '
      'credential, for every member',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob, carol]);
        final rotated = _newSigner('alice-rotated');

        final updated = await alice.engine.selfUpdateWithNewSigner(
          groupIdBytes: group,
          oldSignerBytes: alice.signer,
          newSignerBytes: rotated.signer,
          newCredentialIdentity: rotated.identity,
          newSignerPublicKey: rotated.publicKey,
        );
        await deliver(group, updated.commit, [bob, carol]);
        await _expectInSync(
          [alice, bob, carol],
          group,
          epoch: 2,
          names: {0: 'alice-rotated', 1: 'bob', 2: 'carol'},
        );
        for (final viewer in [alice, bob, carol]) {
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
          message: bytesOf('signed with the new key'),
        );
        for (final member in [bob, carol]) {
          final received = await member.receive(group, message.ciphertext);
          expect(received.senderIndex, 0);
          expect(
            textOf(received.applicationMessage!),
            'signed with the new key',
          );
        }
      },
    );

    capability(
      'updateGroupContextExtensions replaces the extensions in the group '
      'context of every member',
      () async {
        final alice = await Party.create('alice');
        final bob = await Party.create('bob');
        final carol = await Party.create('carol');
        final group = await groupOf(alice, [bob, carol]);
        final none = await alice.engine.groupExtensions(groupIdBytes: group);
        final deliveryService = MlsSignatureKeyPair.generate(
          ciphersuite: defaultSuite,
        ).publicKey();
        final senders = _externalSenders(deliveryService, 'delivery-service');
        expect(
          decodeExternalSenders(data: senders.data).single.signatureKey,
          deliveryService,
        );

        final admit = await alice.engine.updateGroupContextExtensions(
          groupIdBytes: group,
          signerBytes: alice.signer,
          extensions: [senders],
        );
        final admitted = (await bob.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: admit.commit,
        )).stagedCommitInfo!;
        final proposal = admitted.proposals.single;
        expect(proposal.proposalType, MlsProposalType.groupContextExtensions);
        expect(proposal.senderIndex, 0);
        expect(proposal.extensions.single.extensionType, 0x0005);
        final sender = admitted.externalSenders.single;
        expect(sender.signatureKey, deliveryService);
        expect(_identity(sender.credential), 'delivery-service');
        await carol.receive(group, admit.commit);

        final names = {0: 'alice', 1: 'bob', 2: 'carol'};
        await _expectInSync([alice, bob, carol], group, epoch: 2, names: names);
        final carried = await alice.engine.groupExtensions(groupIdBytes: group);
        expect(carried, isNot(none));
        for (final member in [bob, carol]) {
          expect(
            await member.engine.groupExtensions(groupIdBytes: group),
            carried,
            reason: 'group context extensions of ${member.name}',
          );
        }

        // The list replaces the one before it: an empty one leaves none, where
        // the group started.
        final withdraw = await alice.engine.updateGroupContextExtensions(
          groupIdBytes: group,
          signerBytes: alice.signer,
          extensions: const [],
        );
        final withdrawn = (await bob.engine.processMessageWithInspect(
          groupIdBytes: group,
          messageBytes: withdraw.commit,
        )).stagedCommitInfo!;
        expect(withdrawn.externalSenders, isEmpty);
        await carol.receive(group, withdraw.commit);
        await _expectInSync([alice, bob, carol], group, epoch: 3, names: names);
        for (final party in [alice, bob, carol]) {
          expect(
            await party.engine.groupExtensions(groupIdBytes: group),
            none,
            reason: 'group context extensions of ${party.name}',
          );
        }
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

/// Whether [bytes] hold [part] somewhere, byte for byte.
bool _holds(List<int> bytes, List<int> part) {
  for (var start = 0; start + part.length <= bytes.length; start++) {
    var matched = 0;
    while (matched < part.length && bytes[start + matched] == part[matched]) {
      matched++;
    }
    if (matched == part.length) return true;
  }
  return false;
}
