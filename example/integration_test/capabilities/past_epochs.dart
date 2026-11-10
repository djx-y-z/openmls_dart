import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

/// Refused by the library with an error of its own — the message the Rust side
/// returns — and not a panic, which on the web would abort the module.
final _refused = throwsA(isA<String>());

/// The secrets of epochs a group has left: how many it keeps, the deletions an
/// application makes of them, and the resumption PSKs it keeps alongside.
///
/// An application message can only be read with the secrets of the epoch it was
/// sent in, so whether one sent just before a commit still reads after it is
/// what each of these decides.
void pastEpochCapabilities() {
  group('past epoch secrets', () {
    capability('a new group keeps no past epochs, so a message sent before '
        'a commit is lost', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      expect(
        await _policyOf(alice, group),
        const PastEpochDeletionPolicyResult(keepAll: false, maxEpochs: 0),
      );

      final delayed = await bob.send(group, 'sent before the commit');
      final commit = await _advance(alice, group);
      await expectLater(alice.receive(group, delayed), _refused);

      // The group itself goes on: what Bob sends once he follows reads.
      await bob.receive(group, commit);
      final fresh = await bob.send(group, 'sent after the commit');
      expect(await _read(alice, group, fresh), 'sent after the commit');
    });

    capability('the policy is the maxPastEpochs a group was made with, until '
        'a setter or setConfiguration writes another', () async {
      final alice = await Party.create('alice');
      final group = await alice.createGroup(
        config: _keeping(alice.config, maxPastEpochs: 5),
      );
      expect(
        await _policyOf(alice, group),
        const PastEpochDeletionPolicyResult(keepAll: false, maxEpochs: 5),
      );

      // Every call reads the group from storage, so each of these is a
      // round trip through it.
      await alice.engine.setPastEpochDeletionPolicyMaxEpochs(
        groupIdBytes: group,
        maxEpochs: 3,
      );
      expect(
        await _policyOf(alice, group),
        const PastEpochDeletionPolicyResult(keepAll: false, maxEpochs: 3),
      );
      await alice.engine.setPastEpochDeletionPolicyKeepAll(groupIdBytes: group);
      expect((await _policyOf(alice, group)).keepAll, isTrue);

      // The one number refused: what OpenMLS stores to mean keep-all where
      // usize is 32 bits, the web among them. Refused, it changes nothing.
      await expectLater(
        alice.engine.setPastEpochDeletionPolicyMaxEpochs(
          groupIdBytes: group,
          maxEpochs: 4294967295,
        ),
        _refused,
      );
      expect((await _policyOf(alice, group)).keepAll, isTrue);

      // A configuration carries its own maxPastEpochs, and writes it over
      // whatever was set.
      await alice.engine.setConfiguration(
        groupIdBytes: group,
        config: alice.config,
      );
      expect(
        await _policyOf(alice, group),
        const PastEpochDeletionPolicyResult(keepAll: false, maxEpochs: 0),
      );
    });

    capability('kept past epochs let a delayed message through: one epoch '
        'back under a number, several under keepAll', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);

      await alice.engine.setPastEpochDeletionPolicyMaxEpochs(
        groupIdBytes: group,
        maxEpochs: 1,
      );
      final oneBack = await bob.send(group, 'one epoch late');
      await _advance(alice, group, following: [bob]);
      expect(await _read(alice, group, oneBack), 'one epoch late');

      await alice.engine.setPastEpochDeletionPolicyKeepAll(groupIdBytes: group);
      final twoBack = await bob.send(group, 'two epochs late');
      await _advance(alice, group);
      await _advance(alice, group);
      expect(await alice.epochOf(group), BigInt.from(4));
      expect(await _read(alice, group, twoBack), 'two epochs late');
    });

    capability('deleting every past epoch makes them unreadable, and keeps '
        'the policy that records the next ones', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      await alice.engine.setPastEpochDeletionPolicyKeepAll(groupIdBytes: group);
      final first = await bob.send(group, 'first');
      final second = await bob.send(group, 'second');
      await _advance(alice, group, following: [bob]);

      // Readable to begin with...
      expect(await _read(alice, group, first), 'first');
      await alice.engine.deleteAllPastEpochSecrets(groupIdBytes: group);
      // ...and not after, though the policy is as it was.
      await expectLater(alice.receive(group, second), _refused);
      expect((await _policyOf(alice, group)).keepAll, isTrue);

      // A sweep, not a switch: the epoch that passes next is kept again.
      final afterSweep = await bob.send(group, 'after the sweep');
      await _advance(alice, group);
      expect(await _read(alice, group, afterSweep), 'after the sweep');
    });

    capability('a deletion by age keeps what is younger, one by instant takes '
        'what came before it, and a millisecond count is refused', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      await alice.engine.setPastEpochDeletionPolicyKeepAll(groupIdBytes: group);
      final first = await bob.send(group, 'first');
      final second = await bob.send(group, 'second');
      final third = await bob.send(group, 'third');
      await _advance(alice, group);

      // Recorded moments ago, so younger than an hour: kept.
      await alice.engine.deletePastEpochSecretsOlderThan(
        groupIdBytes: group,
        seconds: BigInt.from(3600),
      );
      expect(await _read(alice, group, first), 'first');

      // Milliseconds land past the year 9999: refused before anything is
      // deleted.
      final now = DateTime.now().millisecondsSinceEpoch;
      await expectLater(
        alice.engine.deletePastEpochSecretsBefore(
          groupIdBytes: group,
          unixSeconds: BigInt.from(now),
        ),
        _refused,
      );
      expect(await _read(alice, group, second), 'second');

      // Everything recorded before an hour from now: gone.
      await alice.engine.deletePastEpochSecretsBefore(
        groupIdBytes: group,
        unixSeconds: BigInt.from(now ~/ 1000 + 3600),
      );
      await expectLater(alice.receive(group, third), _refused);
    });

    capability('deleting undated secrets leaves these, which are all dated, '
        'and its cap keeps only the newest past epochs', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      await alice.engine.setPastEpochDeletionPolicyKeepAll(groupIdBytes: group);
      final fromEpoch1 = await bob.send(group, 'from epoch 1');
      final alsoFromEpoch1 = await bob.send(group, 'also from epoch 1');
      await _advance(alice, group, following: [bob]);
      final fromEpoch2 = await bob.send(group, 'from epoch 2');
      await _advance(alice, group);

      // Only secrets recorded by a build on OpenMLS 0.8.1 or earlier carry no
      // timestamp, so this migration step has nothing to do here.
      await alice.engine.deletePastEpochSecretsWithoutTimestamps(
        groupIdBytes: group,
      );
      expect(await _read(alice, group, fromEpoch1), 'from epoch 1');

      // With a cap the cap is what acts: of two past epochs, the newer stays.
      await alice.engine.deletePastEpochSecretsWithoutTimestamps(
        groupIdBytes: group,
        maxPastEpochs: 1,
      );
      expect(await _read(alice, group, fromEpoch2), 'from epoch 2');
      await expectLater(alice.receive(group, alsoFromEpoch1), _refused);
    });

    capability('every member derives the same resumption PSK for an epoch, '
        'and keeps it as the group moves on', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      // Room for three, so that nothing here is ever rolled over.
      final config = _keeping(alice.config, resumptionPsks: 3);
      final group = await groupOf(alice, [bob], config: config);
      Future<Uint8List?> psk(Party party, int epoch) => party.engine
          .getPastResumptionPsk(groupIdBytes: group, epoch: BigInt.from(epoch));

      final first = await psk(alice, 1);
      expect(first, isNotNull);
      expect(await psk(bob, 1), first);
      // Bob was not in the group in epoch 0, and epoch 2 has not happened.
      expect(await psk(bob, 0), isNull);
      expect(await psk(alice, 2), isNull);

      await _advance(alice, group, following: [bob]);
      final second = await psk(alice, 2);
      expect(second, isNotNull);
      expect(second, isNot(first));
      expect(await psk(bob, 2), second);
      // The past epoch's is still there, as it was, for both.
      expect(await psk(alice, 1), first);
      expect(await psk(bob, 1), first);
    });
  });
}

/// [base] keeping [maxPastEpochs] past epochs and [resumptionPsks] resumption
/// PSKs; [MlsGroupConfig] has no copyWith.
MlsGroupConfig _keeping(
  MlsGroupConfig base, {
  int? maxPastEpochs,
  int? resumptionPsks,
}) => MlsGroupConfig(
  ciphersuite: base.ciphersuite,
  wireFormatPolicy: base.wireFormatPolicy,
  useRatchetTreeExtension: base.useRatchetTreeExtension,
  maxPastEpochs: maxPastEpochs ?? base.maxPastEpochs,
  paddingSize: base.paddingSize,
  senderRatchetMaxOutOfOrder: base.senderRatchetMaxOutOfOrder,
  senderRatchetMaxForwardDistance: base.senderRatchetMaxForwardDistance,
  numberOfResumptionPsks: resumptionPsks ?? base.numberOfResumptionPsks,
);

Future<PastEpochDeletionPolicyResult> _policyOf(Party party, List<int> group) =>
    party.engine.pastEpochDeletionPolicy(groupIdBytes: group);

/// Moves [owner] to the next epoch with a commit of its own, which each of
/// [following] processes too; the others stay behind. Returns the commit.
Future<Uint8List> _advance(
  Party owner,
  List<int> group, {
  List<Party> following = const [],
}) async {
  final commit = await owner.engine.selfUpdate(
    groupIdBytes: group,
    signerBytes: owner.signer,
  );
  await deliver(group, commit.commit, following);
  return commit.commit;
}

/// What [message] says, as [reader] decrypts it.
Future<String> _read(Party reader, List<int> group, List<int> message) async {
  final received = await reader.receive(group, message);
  expect(received.messageType, ProcessedMessageType.application);
  return textOf(received.applicationMessage!);
}
