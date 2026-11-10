import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

/// The ExternalSenders extension type (RFC 9420 §12.1.8.1).
const _externalSendersType = 0x0005;

/// The creator of a group, as a sender: the member in the first leaf.
const _creator = MlsSenderInfo(kind: MlsSenderKind.member, index: 0);

/// Refused by the library with an error of its own — the message the Rust side
/// returns — and not a panic, which on the web would abort the module.
final _refused = throwsA(isA<String>());

/// Messages between members: sending and reading them, what can be read off
/// one before it is decrypted, and inspecting one before deciding to apply it.
void messageCapabilities() {
  group('messages', () {
    capability('a message from one member reads the same to every '
        'other', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');
      final group = await groupOf(alice, [bob, carol]);

      final fromAlice = await alice.send(group, 'hello, both of you');
      for (final reader in [bob, carol]) {
        final received = await reader.engine.processMessage(
          groupIdBytes: group,
          messageBytes: fromAlice,
        );
        expect(received.messageType, ProcessedMessageType.application);
        expect(textOf(received.applicationMessage!), 'hello, both of you');
        expect(received.senderIndex, 0);
        expect(received.epoch, BigInt.one);
        expect(received.hasStagedCommit, isFalse);
        expect(received.hasProposal, isFalse);
        expect(received.proposalType, isNull);
      }

      final bobIndex = await bob.engine.groupOwnIndex(groupIdBytes: group);
      final fromBob = await bob.send(group, 'and back');
      for (final reader in [alice, carol]) {
        final received = await reader.receive(group, fromBob);
        expect(textOf(received.applicationMessage!), 'and back');
        expect(received.senderIndex, bobIndex);
      }
      // Application messages move no epoch.
      for (final party in [alice, bob, carol]) {
        expect(await party.epochOf(group), BigInt.one);
      }
    });

    capability('additional authenticated data travels in the clear, bound '
        'to its one message', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      final aad = bytesOf('route: room 7');
      final message = (await alice.engine.createMessage(
        groupIdBytes: group,
        signerBytes: alice.signer,
        message: bytesOf('the content'),
        aad: aad,
      )).ciphertext;

      // Authenticated, not encrypted: the AAD is on the wire as it was
      // given, and the content is not.
      final at = _indexOf(message, aad);
      expect(at, isNonNegative);
      expect(_indexOf(message, bytesOf('the content')), -1);

      // Changed on the way, it no longer authenticates the message...
      final tampered = Uint8List.fromList(message)..[at] ^= 0x01;
      await expectLater(bob.receive(group, tampered), _refused);
      // ...which as sent still reads: the refusal used nothing up.
      final received = await bob.receive(group, message);
      expect(textOf(received.applicationMessage!), 'the content');

      // The AAD went with that message alone.
      final next = await alice.send(group, 'no AAD this time');
      expect(_indexOf(next, aad), -1);
      final plain = await bob.receive(group, next);
      expect(textOf(plain.applicationMessage!), 'no AAD this time');
    });

    capability('a message names its group, epoch and content type to '
        'whoever routes it, before anyone decrypts it', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await alice.createGroup();
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);
      expect(await bob.join(added.welcome), group);

      final application = await alice.send(group, 'routed');
      final proposal = await bob.engine.proposeSelfUpdate(
        groupIdBytes: group,
        signerBytes: bob.signer,
      );
      final commit = await alice.engine.selfUpdate(
        groupIdBytes: group,
        signerBytes: alice.signer,
      );
      final later = await alice.send(group, 'routed, an epoch on');

      // A commit is sent in the epoch it ends.
      for (final (message, contentType, epoch) in [
        (added.commit, 'commit', 0),
        (application, 'application', 1),
        (proposal.proposalMessage, 'proposal', 1),
        (commit.commit, 'commit', 1),
        (later, 'application', 2),
      ]) {
        final reason = '$contentType from epoch $epoch';
        expect(
          mlsMessageExtractGroupId(messageBytes: message),
          group,
          reason: reason,
        );
        expect(
          mlsMessageExtractEpoch(messageBytes: message),
          BigInt.from(epoch),
          reason: reason,
        );
        expect(
          mlsMessageContentType(messageBytes: message),
          contentType,
          reason: reason,
        );
      }

      // A Welcome is for a newcomer, not for the group: it has none of the
      // three to route by.
      expect(
        () => mlsMessageExtractGroupId(messageBytes: added.welcome),
        _refused,
      );
      expect(
        () => mlsMessageExtractEpoch(messageBytes: added.welcome),
        _refused,
      );
      expect(
        () => mlsMessageContentType(messageBytes: added.welcome),
        _refused,
      );
    });

    capability('inspecting a commit tells what it does and by whom, and '
        'applies none of it until it is processed', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');
      final group = await groupOf(alice, [bob, carol]);
      final carolIndex = await carol.engine.groupOwnIndex(groupIdBytes: group);
      final removed = await alice.engine.removeMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        memberIndices: [carolIndex],
      );
      final commit = removed.commit;
      final authenticator = await bob.engine.groupEpochAuthenticator(
        groupIdBytes: group,
      );

      final inspected = await bob.engine.inspectMessage(
        groupIdBytes: group,
        messageBytes: commit,
      );
      expect(inspected.messageType, ProcessedMessageType.stagedCommit);
      expect(inspected.sender, _creator);
      expect(inspected.senderIndex, 0);
      expect(inspected.epoch, BigInt.one);
      final info = inspected.stagedCommitInfo!;
      expect(info.removeIndices, [carolIndex]);
      expect(info.removeCredentials.map(_identityOf), ['carol']);
      expect(info.addCredentials, isEmpty);
      expect(info.selfRemoved, isFalse);
      expect(_identityOf(info.committerCredential!), 'alice');
      final removal = info.proposals.single;
      expect(removal.proposalType, MlsProposalType.remove);
      expect(removal.sender, _creator);
      expect(removal.byReference, isFalse);
      expect(removal.leaf, isNull);
      expect(removal.affectedMember!.index, carolIndex);
      expect(removal.affectedMember!.signatureKey, carol.publicKey);

      // Nothing applied: the same epoch and members, and the same commit
      // inspects the same way again.
      expect(await bob.epochOf(group), BigInt.one);
      expect(
        await bob.engine.groupEpochAuthenticator(groupIdBytes: group),
        authenticator,
      );
      expect(await bob.engine.groupMembers(groupIdBytes: group), hasLength(3));
      final again = await bob.engine.inspectMessage(
        groupIdBytes: group,
        messageBytes: commit,
      );
      expect(again.stagedCommitInfo!.removeIndices, [carolIndex]);

      // The member it removes sees that, and is in until it processes it.
      final seen = await carol.engine.inspectMessage(
        groupIdBytes: group,
        messageBytes: commit,
      );
      expect(seen.stagedCommitInfo!.selfRemoved, isTrue);
      expect(await carol.engine.groupIsActive(groupIdBytes: group), isTrue);

      // Accepted, the same bytes apply.
      final processed = await bob.engine.processMessage(
        groupIdBytes: group,
        messageBytes: commit,
      );
      expect(processed.messageType, ProcessedMessageType.stagedCommit);
      expect(processed.hasStagedCommit, isTrue);
      expect(await bob.epochOf(group), BigInt.two);
      expect(await bob.engine.groupMembers(groupIdBytes: group), hasLength(2));
      expect(
        await bob.engine.groupEpochAuthenticator(groupIdBytes: group),
        await alice.engine.groupEpochAuthenticator(groupIdBytes: group),
      );
    });

    capability("inspecting a commit names each proposal's own sender, when "
        "it carries another member's proposal by reference", () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');
      final group = await groupOf(alice, [bob, carol]);
      final bobIndex = await bob.engine.groupOwnIndex(groupIdBytes: group);
      final carolIndex = await carol.engine.groupOwnIndex(groupIdBytes: group);

      final proposal = await bob.engine.proposeRemove(
        groupIdBytes: group,
        signerBytes: bob.signer,
        memberIndex: carolIndex,
      );
      await deliver(group, proposal.proposalMessage, [alice, carol]);
      final commit = await alice.engine.commitToPendingProposals(
        groupIdBytes: group,
        signerBytes: alice.signer,
      );

      final inspected = await carol.engine.inspectMessage(
        groupIdBytes: group,
        messageBytes: commit.commit,
      );
      // Alice committed it...
      expect(inspected.sender, _creator);
      // ...and Bob proposed what it does.
      final removal = inspected.stagedCommitInfo!.proposals.single;
      expect(removal.proposalType, MlsProposalType.remove);
      expect(removal.byReference, isTrue);
      expect(
        removal.sender,
        MlsSenderInfo(kind: MlsSenderKind.member, index: bobIndex),
      );
      expect(removal.senderIndex, bobIndex);
      expect(removal.affectedMember!.index, carolIndex);
      expect(inspected.stagedCommitInfo!.selfRemoved, isTrue);
    });

    capability('processMessageWithInspect reports the member a commit adds, '
        'and applies it', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');
      final group = await groupOf(alice, [bob]);
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [await carol.keyPackage()],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);

      final result = await bob.engine.processMessageWithInspect(
        groupIdBytes: group,
        messageBytes: added.commit,
      );
      expect(result.messageType, ProcessedMessageType.stagedCommit);
      expect(result.sender, _creator);
      final info = result.stagedCommitInfo!;
      expect(info.addCredentials.map(_identityOf), ['carol']);
      expect(info.removeIndices, isEmpty);
      expect(info.selfRemoved, isFalse);
      final add = info.proposals.single;
      expect(add.proposalType, MlsProposalType.add);
      expect(add.sender, _creator);
      expect(add.byReference, isFalse);
      expect(_identityOf(add.leaf!.credential), 'carol');
      expect(add.leaf!.signatureKey, carol.publicKey);

      // Applied: Bob is in the epoch the commit made, with Carol in it...
      expect(await bob.epochOf(group), BigInt.two);
      final members = await bob.engine.groupMembers(groupIdBytes: group);
      final keys = [for (final member in members) member.signatureKey];
      expect(keys, hasLength(3));
      expect(keys, contains(equals(carol.publicKey)));
      // ...which is the epoch Carol joins from the Welcome.
      expect(await carol.join(added.welcome), group);
      final authenticator = await alice.engine.groupEpochAuthenticator(
        groupIdBytes: group,
      );
      for (final party in [bob, carol]) {
        expect(
          await party.engine.groupEpochAuthenticator(groupIdBytes: group),
          authenticator,
          reason: party.name,
        );
      }
    });

    capability('an application message inspected is not used up: it reads '
        'again, and then processes', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      final message = await alice.send(group, 'read before it is taken');

      for (var time = 0; time < 2; time++) {
        final inspected = await bob.engine.inspectMessage(
          groupIdBytes: group,
          messageBytes: message,
        );
        expect(inspected.messageType, ProcessedMessageType.application);
        expect(
          textOf(inspected.applicationMessage!),
          'read before it is taken',
        );
        expect(inspected.sender, _creator);
        expect(inspected.epoch, BigInt.one);
        expect(inspected.stagedCommitInfo, isNull);
        expect(inspected.proposalInfo, isNull);
      }

      final processed = await bob.receive(group, message);
      expect(textOf(processed.applicationMessage!), 'read before it is taken');
    });

    capability('inspecting a proposal describes it and stores nothing; '
        'processing it stores it', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      final proposal = await alice.engine.proposeSelfUpdate(
        groupIdBytes: group,
        signerBytes: alice.signer,
      );

      final inspected = await bob.engine.inspectMessage(
        groupIdBytes: group,
        messageBytes: proposal.proposalMessage,
      );
      expect(inspected.messageType, ProcessedMessageType.proposal);
      expect(inspected.proposalType, MlsProposalType.update);
      expect(inspected.sender, _creator);
      // The leaf it would put in, and the member whose leaf that replaces.
      final update = inspected.proposalInfo!;
      expect(update.proposalType, MlsProposalType.update);
      expect(_identityOf(update.leaf!.credential), 'alice');
      expect(update.leaf!.signatureKey, alice.publicKey);
      expect(update.affectedMember!.index, 0);
      expect(update.affectedMember!.signatureKey, alice.publicKey);
      expect(
        await bob.engine.groupHasPendingProposals(groupIdBytes: group),
        isFalse,
      );

      final processed = await bob.engine.processMessage(
        groupIdBytes: group,
        messageBytes: proposal.proposalMessage,
      );
      expect(processed.messageType, ProcessedMessageType.proposal);
      expect(processed.hasProposal, isTrue);
      expect(processed.proposalType, MlsProposalType.update);
      expect(await bob.engine.groupPendingProposals(groupIdBytes: group), [
        const MlsPendingProposalInfo(
          proposalType: MlsProposalType.update,
          senderIndex: 0,
        ),
      ]);
    });

    capability('a commit that admits an external sender shows it, and '
        'decodeExternalSenders reads the extension', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      final key = MlsSignatureKeyPair.generate(
        ciphersuite: defaultSuite,
      ).publicKey();
      final credential = MlsCredential.basic(
        identity: bytesOf('delivery service'),
      ).serialize();
      final data = _externalSenders(key, credential);

      // What is written reads back as it was written.
      final decoded = decodeExternalSenders(data: data).single;
      expect(decoded.signatureKey, key);
      expect(decoded.credential, credential);

      final commit = await alice.engine.flexibleCommit(
        groupIdBytes: group,
        signerBytes: alice.signer,
        options: FlexibleCommitOptions(
          addKeyPackages: const [],
          removeIndices: Uint32List(0),
          forceSelfUpdate: false,
          consumePendingProposals: false,
          groupContextExtensions: [
            MlsExtension(extensionType: _externalSendersType, data: data),
          ],
          createGroupInfo: false,
          useRatchetTreeExtension: false,
        ),
      );
      final info = (await bob.engine.inspectMessage(
        groupIdBytes: group,
        messageBytes: commit.commit,
      )).stagedCommitInfo!;

      final admitted = info.externalSenders.single;
      expect(admitted.signatureKey, key);
      expect(_identityOf(admitted.credential), 'delivery service');
      final reported = info.groupContextExtensions.singleWhere(
        (extension) => extension.extensionType == _externalSendersType,
      );
      expect(reported.data, data);
      final read = decodeExternalSenders(data: reported.data).single;
      expect(read.signatureKey, key);
      expect(read.credential, credential);
      final change = info.proposals.single;
      expect(change.proposalType, MlsProposalType.groupContextExtensions);
      expect(change.sender, _creator);
      expect(change.extensions.single.extensionType, _externalSendersType);
    });

    capability('decodeExternalSenders answers bytes that hold no list of '
        'senders with an error, never a panic', () async {
      final key = MlsSignatureKeyPair.generate(
        ciphersuite: defaultSuite,
      ).publicKey();
      final valid = _externalSenders(
        key,
        MlsCredential.basic(identity: bytesOf('ds')).serialize(),
      );

      // An empty list is a list.
      expect(decodeExternalSenders(data: [0]), isEmpty);

      // Every cut of a valid list, sizes that claim more than follows, a
      // size no encoding has, and data after the list.
      for (var n = 0; n < valid.length; n++) {
        expect(
          () => decodeExternalSenders(data: valid.sublist(0, n)),
          _refused,
          reason: 'the first $n bytes',
        );
      }
      for (final bytes in [
        [0x3f],
        [0x7f, 0xff],
        [0xbf, 0xff, 0xff, 0xff],
        [0xff, 0xff, 0xff, 0xff, 0xff],
        [0, 1, 2, 3],
        [...valid, ...valid],
      ]) {
        expect(
          () => decodeExternalSenders(data: bytes),
          _refused,
          reason: '$bytes',
        );
      }

      // On the web a panic aborts the module; that it still decodes shows
      // none did.
      expect(decodeExternalSenders(data: valid).single.signatureKey, key);
    });
  });
}

/// The identity a basic credential names, as text.
String _identityOf(List<int> credential) =>
    textOf(MlsCredential.deserialize(bytes: credential).identity());

/// Where [part] first occurs in [bytes], or -1.
int _indexOf(List<int> bytes, List<int> part) {
  for (var start = 0; start + part.length <= bytes.length; start++) {
    var matches = true;
    for (var i = 0; i < part.length && matches; i++) {
      matches = bytes[start + i] == part[i];
    }
    if (matches) return start;
  }
  return -1;
}

/// An ExternalSenders extension's data (RFC 9420 §12.1.8.1): a list of
/// entries, each a signature key and then a credential.
Uint8List _externalSenders(List<int> signatureKey, List<int> credential) {
  final entry = [
    ..._length(signatureKey.length),
    ...signatureKey,
    ...credential,
  ];
  return Uint8List.fromList([..._length(entry.length), ...entry]);
}

/// The variable-length size prefix of RFC 9420 §2.1.2, in its shortest form.
List<int> _length(int length) {
  if (length < 1 << 6) return [length];
  if (length < 1 << 14) return [0x40 | (length >> 8), length & 0xff];
  return [
    0x80 | (length >> 24),
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
  ];
}
