import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

/// The ExternalSenders extension type (RFC 9420 §12.1.8.1).
const _externalSendersType = 0x0005;

/// What a group tells its members about itself: who is in it, the epoch and
/// its context, what is derived and exported from them, and the configuration
/// the group runs on.
void stateCapabilities() {
  group('group state', () {
    capability('every member reads the same roster, and finds itself in it '
        'by index, credential and key', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      final stranger = MlsCredential.basic(identity: bytesOf('carol'));

      final roster = _roster(
        await alice.engine.groupMembers(groupIdBytes: group),
      );
      expect(roster, hasLength(2));
      // The creator holds the first leaf.
      expect(await alice.engine.groupOwnIndex(groupIdBytes: group), 0);

      for (final party in [alice, bob]) {
        final engine = party.engine;
        final members = await engine.groupMembers(groupIdBytes: group);
        expect(_roster(members), roster, reason: party.name);

        final own = await engine.groupOwnIndex(groupIdBytes: group);
        final me = members.singleWhere((member) => member.index == own);
        expect(_identityOf(me.credential), party.name);
        expect(me.signatureKey, party.publicKey);

        // Looked up by credential or by leaf, it is the same member...
        expect(
          await engine.groupMemberLeafIndex(
            groupIdBytes: group,
            credentialBytes: party.credential,
          ),
          own,
        );
        final at = await engine.groupMemberAt(
          groupIdBytes: group,
          leafIndex: own,
        );
        expect(at, isNotNull);
        expect(_roster([at!]), _roster([me]));

        // ...holding the credential and the leaf this member signs with.
        expect(
          await engine.groupCredential(groupIdBytes: group),
          me.credential,
        );
        final leaf = await engine.groupOwnLeafNode(groupIdBytes: group);
        expect(leaf.credential, me.credential);
        expect(leaf.signatureKey, party.publicKey);
        expect(leaf.encryptionKey, isNotEmpty);

        // A leaf past the last holds nobody, and a stranger's credential
        // names no leaf.
        expect(
          await engine.groupMemberAt(groupIdBytes: group, leafIndex: 2),
          isNull,
        );
        expect(
          await engine.groupMemberLeafIndex(
            groupIdBytes: group,
            credentialBytes: stranger.serialize(),
          ),
          isNull,
        );
      }
    });

    capability('a commit moves every member to the same next epoch, with a '
        'new context, authenticator, confirmation tag and tree', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);

      final before = await _view(alice, group);
      expect(before['group ID'], group);
      expect(before['context: group ID'], group);
      expect(before['epoch'], BigInt.one);
      expect(before['context: epoch'], BigInt.one);
      expect(before['ciphersuite'], defaultSuite);
      expect(before['context: ciphersuite'], defaultSuite);
      expect(before['active'], isTrue);
      // The group's extensions are its context's.
      expect(before['extensions'], before['context: extensions']);
      expect(await _view(bob, group), before);

      final commit = await alice.engine.selfUpdate(
        groupIdBytes: group,
        signerBytes: alice.signer,
      );
      await bob.receive(group, commit.commit);

      final after = await _view(alice, group);
      expect(await _view(bob, group), after);
      expect(after['epoch'], BigInt.two);
      expect(after['context: epoch'], BigInt.two);
      for (final moved in [
        'context: tree hash',
        'context: confirmed transcript hash',
        'epoch authenticator',
        'confirmation tag',
        'ratchet tree',
        'exported secret',
      ]) {
        expect(after[moved], isNot(before[moved]), reason: moved);
      }
    });

    capability('every member exports the same secret for a label and '
        'context, and another label, context or length gives another '
        'one', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      Future<Uint8List> exported(
        Party party,
        String label,
        String context,
        int length,
      ) => party.engine.exportSecret(
        groupIdBytes: group,
        label: label,
        context: bytesOf(context),
        keyLength: length,
      );

      final secret = await exported(alice, 'app key', 'room 1', 32);
      expect(secret, hasLength(32));
      expect(await exported(bob, 'app key', 'room 1', 32), secret);

      expect(
        await exported(alice, 'app key, too', 'room 1', 32),
        isNot(secret),
      );
      expect(await exported(bob, 'app key', 'room 2', 32), isNot(secret));

      // The length is part of the derivation, not a cut of a longer secret.
      final shorter = await exported(bob, 'app key', 'room 1', 16);
      expect(shorter, hasLength(16));
      expect(shorter, isNot(secret.sublist(0, 16)));
      expect(await exported(alice, 'app key', 'room 1', 16), shorter);
    });

    capability('the group context extensions a commit sets are what every '
        'member reports', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);
      // None to begin with: an empty list.
      for (final party in [alice, bob]) {
        expect(
          await party.engine.groupExtensions(groupIdBytes: group),
          _wireExtensions(const []),
        );
      }

      final deliveryService = MlsSignatureKeyPair.generate(
        ciphersuite: defaultSuite,
      );
      final externalSenders = MlsExtension(
        extensionType: _externalSendersType,
        data: _externalSenders(
          deliveryService.publicKey(),
          MlsCredential.basic(
            identity: bytesOf('delivery service'),
          ).serialize(),
        ),
      );
      final commit = await alice.engine.flexibleCommit(
        groupIdBytes: group,
        signerBytes: alice.signer,
        options: FlexibleCommitOptions(
          addKeyPackages: const [],
          removeIndices: Uint32List(0),
          forceSelfUpdate: false,
          consumePendingProposals: false,
          groupContextExtensions: [externalSenders],
          createGroupInfo: false,
          useRatchetTreeExtension: false,
        ),
      );
      await bob.receive(group, commit.commit);

      final expected = _wireExtensions([externalSenders]);
      for (final party in [alice, bob]) {
        expect(
          await party.engine.groupExtensions(groupIdBytes: group),
          expected,
          reason: party.name,
        );
        final context = await party.engine.exportGroupContext(
          groupIdBytes: group,
        );
        expect(context.extensions, expected, reason: party.name);
      }
    });

    capability('what members export lets newcomers in: the ratchet tree a '
        'Welcome left out, and a GroupInfo for an external commit', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final carol = await Party.create('carol');
      // The Welcomes of this group carry no ratchet tree.
      final config = _config(alice.config, useRatchetTreeExtension: false);
      final group = await alice.createGroup(config: config);
      final added = await alice.engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      await alice.engine.mergePendingCommit(groupIdBytes: group);

      // The tree of the epoch the Welcome is for, which the join checks
      // against the Welcome before it takes it.
      final tree = await alice.engine.exportRatchetTree(groupIdBytes: group);
      expect(
        await bob.join(added.welcome, ratchetTree: tree, config: config),
        group,
      );
      // Every member exports the same tree.
      expect(await bob.engine.exportRatchetTree(groupIdBytes: group), tree);

      // A GroupInfo from any member, not only the creator, admits a
      // newcomer by external commit.
      final groupInfo = await bob.engine.exportGroupInfo(
        groupIdBytes: group,
        signerBytes: bob.signer,
      );
      final joined = await carol.engine.joinGroupExternalCommit(
        config: carol.config,
        groupInfoBytes: groupInfo,
        ratchetTreeBytes: tree,
        signerBytes: carol.signer,
        credentialIdentity: carol.identity,
        signerPublicKey: carol.publicKey,
      );
      expect(joined.groupId, group);
      await deliver(group, joined.commit, [alice, bob]);

      final authenticator = await alice.engine.groupEpochAuthenticator(
        groupIdBytes: group,
      );
      for (final party in [alice, bob, carol]) {
        expect(await party.epochOf(group), BigInt.two, reason: party.name);
        expect(
          await party.engine.groupMembers(groupIdBytes: group),
          hasLength(3),
          reason: party.name,
        );
        expect(
          await party.engine.groupEpochAuthenticator(groupIdBytes: group),
          authenticator,
          reason: party.name,
        );
      }
    });

    capability('a group runs on the configuration it was made with, until '
        'setConfiguration replaces it', () async {
      final alice = await Party.create('alice');
      final made = _config(
        alice.config,
        paddingSize: 128,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 500,
      );
      final group = await alice.createGroup(config: made);
      expect(
        await alice.engine.groupConfiguration(groupIdBytes: group),
        _reported(made),
      );

      final replaced = _config(
        alice.config,
        wireFormatPolicy: MlsWireFormatPolicy.plaintext,
        paddingSize: 32,
        senderRatchetMaxOutOfOrder: 20,
        senderRatchetMaxForwardDistance: 2000,
      );
      await alice.engine.setConfiguration(
        groupIdBytes: group,
        config: replaced,
      );
      // Read back from storage, as every call reads the group.
      expect(
        await alice.engine.groupConfiguration(groupIdBytes: group),
        _reported(replaced),
      );
    });
  });
}

/// Every state query [party] answers about [group], by name, so that two
/// members' answers compare in one expectation and a difference names what
/// differs.
Future<Map<String, Object>> _view(Party party, Uint8List group) async {
  final engine = party.engine;
  final context = await engine.exportGroupContext(groupIdBytes: group);
  return {
    'group ID': await engine.groupId(groupIdBytes: group),
    'epoch': await engine.groupEpoch(groupIdBytes: group),
    'active': await engine.groupIsActive(groupIdBytes: group),
    'ciphersuite': await engine.groupCiphersuite(groupIdBytes: group),
    'extensions': await engine.groupExtensions(groupIdBytes: group),
    'context: group ID': context.groupId,
    'context: epoch': context.epoch,
    'context: ciphersuite': context.ciphersuite,
    'context: tree hash': context.treeHash,
    'context: confirmed transcript hash': context.confirmedTranscriptHash,
    'context: extensions': context.extensions,
    'epoch authenticator': await engine.groupEpochAuthenticator(
      groupIdBytes: group,
    ),
    'confirmation tag': await engine.groupConfirmationTag(groupIdBytes: group),
    'ratchet tree': await engine.exportRatchetTree(groupIdBytes: group),
    'exported secret': await engine.exportSecret(
      groupIdBytes: group,
      label: 'state',
      context: const [],
      keyLength: 32,
    ),
  };
}

/// [members] as values that compare by content: the generated classes
/// compare their byte fields by identity.
List<List<Object>> _roster(List<MlsMemberInfo> members) => [
  for (final member in members)
    [member.index, member.credential, member.signatureKey],
];

/// The identity a basic credential names, as text.
String _identityOf(List<int> credential) =>
    textOf(MlsCredential.deserialize(bytes: credential).identity());

/// [base] with the fields given replaced; [MlsGroupConfig] has no copyWith.
MlsGroupConfig _config(
  MlsGroupConfig base, {
  MlsWireFormatPolicy? wireFormatPolicy,
  bool? useRatchetTreeExtension,
  int? paddingSize,
  int? senderRatchetMaxOutOfOrder,
  int? senderRatchetMaxForwardDistance,
}) => MlsGroupConfig(
  ciphersuite: base.ciphersuite,
  wireFormatPolicy: wireFormatPolicy ?? base.wireFormatPolicy,
  useRatchetTreeExtension:
      useRatchetTreeExtension ?? base.useRatchetTreeExtension,
  maxPastEpochs: base.maxPastEpochs,
  paddingSize: paddingSize ?? base.paddingSize,
  senderRatchetMaxOutOfOrder:
      senderRatchetMaxOutOfOrder ?? base.senderRatchetMaxOutOfOrder,
  senderRatchetMaxForwardDistance:
      senderRatchetMaxForwardDistance ?? base.senderRatchetMaxForwardDistance,
  numberOfResumptionPsks: base.numberOfResumptionPsks,
);

/// What `groupConfiguration` reports for a group running on [config].
GroupConfigurationResult _reported(MlsGroupConfig config) =>
    GroupConfigurationResult(
      ciphersuite: config.ciphersuite,
      wireFormatPolicy: config.wireFormatPolicy,
      paddingSize: config.paddingSize,
      senderRatchetMaxOutOfOrder: config.senderRatchetMaxOutOfOrder,
      senderRatchetMaxForwardDistance: config.senderRatchetMaxForwardDistance,
    );

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

/// [extensions] as a group context carries them on the wire: a list of
/// entries, each a 16-bit type and then its data behind its length.
Uint8List _wireExtensions(List<MlsExtension> extensions) {
  final entries = [
    for (final extension in extensions) ...[
      extension.extensionType >> 8,
      extension.extensionType & 0xff,
      ..._length(extension.data.length),
      ...extension.data,
    ],
  ];
  return Uint8List.fromList([..._length(entries.length), ...entries]);
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
