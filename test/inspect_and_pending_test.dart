import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// `inspectMessage` — judging a commit before it takes effect — and
/// `FlexibleCommitOptions.keepPending` — merging an own commit only once the
/// delivery service accepted it.
void main() {
  /// An application-defined group-context extension type (private use).
  const appExtensionType = 0xF0A1;

  /// What every leaf advertises, so the group context may carry the
  /// application's extension.
  final capabilities = MlsCapabilities(
    versions: Uint16List(0),
    ciphersuites: Uint16List.fromList([0x0001]),
    extensions: Uint16List.fromList([appExtensionType]),
    proposals: Uint16List(0),
    credentials: Uint16List(0),
  );

  /// A RequiredCapabilities extension (RFC 9420, 11.1) requiring
  /// [extensions]: three vectors of 16-bit types — extensions, proposals,
  /// credentials — each behind a one-byte length while it is under 64 bytes.
  MlsExtension requiredCapabilities({required List<int> extensions}) =>
      MlsExtension(
        extensionType: 0x0003,
        data: Uint8List.fromList([
          extensions.length * 2,
          for (final type in extensions) ...[type >> 8, type & 0xFF],
          0, // proposal types
          0, // credential types
        ]),
      );

  late MlsEngine alice;
  late MlsEngine bob;
  late MlsEngine carol;
  late TestIdentity aliceId;
  late TestIdentity bobId;
  late TestIdentity carolId;
  late Uint8List groupIdBytes;

  setUpAll(() async {
    await Openmls.init();
  });

  /// Alice's group with Bob and Carol in it, everyone in the same epoch.
  setUp(() async {
    alice = await createTestEngine();
    bob = await createTestEngine();
    carol = await createTestEngine();
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');
    carolId = TestIdentity.create('carol');

    final created = await alice.createGroupWithBuilder(
      config: defaultConfig(),
      signerBytes: aliceId.signerBytes,
      credentialIdentity: aliceId.credentialIdentity,
      signerPublicKey: aliceId.publicKey,
      capabilities: capabilities,
    );
    groupIdBytes = created.groupId;

    Future<Uint8List> keyPackage(MlsEngine engine, TestIdentity id) async =>
        (await engine.createKeyPackageWithOptions(
          ciphersuite: ciphersuite,
          signerBytes: id.signerBytes,
          credentialIdentity: id.credentialIdentity,
          signerPublicKey: id.publicKey,
          options: KeyPackageOptions(
            lastResort: false,
            capabilities: capabilities,
          ),
        )).keyPackageBytes;

    final added = await alice.addMembers(
      groupIdBytes: groupIdBytes,
      signerBytes: aliceId.signerBytes,
      keyPackagesBytes: [
        await keyPackage(bob, bobId),
        await keyPackage(carol, carolId),
      ],
    );
    for (final (engine, id) in [(bob, bobId), (carol, carolId)]) {
      await engine.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: added.welcome,
        signerBytes: id.signerBytes,
      );
    }
  });

  Future<int> indexOf(MlsEngine engine, TestIdentity id) async {
    for (final member in await engine.groupMembers(
      groupIdBytes: groupIdBytes,
    )) {
      if (utf8.decode(identityFromCredential(member.credential)) ==
          utf8.decode(id.credentialIdentity)) {
        return member.index;
      }
    }
    throw StateError('No member ${utf8.decode(id.credentialIdentity)}');
  }

  Future<BigInt> epochOf(MlsEngine engine) =>
      engine.groupEpoch(groupIdBytes: groupIdBytes);

  group('inspectMessage', () {
    test('reports a removal — whose, by whom — and applies nothing', () async {
      final carolIndex = await indexOf(alice, carolId);
      final commit = await alice.removeMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        memberIndices: [carolIndex],
      );
      final before = await epochOf(bob);

      final inspected = await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(inspected.messageType, ProcessedMessageType.stagedCommit);
      expect(inspected.senderIndex, await indexOf(bob, aliceId));
      final info = inspected.stagedCommitInfo!;
      expect(info.removeIndices, [carolIndex]);
      expect(
        info.removeCredentials.map(identityFromCredential).map(utf8.decode),
        ['carol'],
      );
      expect(info.proposals, hasLength(1));
      expect(info.proposals.single.proposalType, MlsProposalType.remove);
      expect(info.proposals.single.senderIndex, inspected.senderIndex);
      expect(info.proposals.single.byReference, isFalse);
      expect(
        utf8.decode(identityFromCredential(info.committerCredential!)),
        'alice',
      );
      expect(info.selfRemoved, isFalse);

      // Nothing happened: same epoch, Carol still in, and the same commit
      // inspects the same way again.
      expect(await epochOf(bob), before);
      expect(await bob.groupMembers(groupIdBytes: groupIdBytes), hasLength(3));
      final again = await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(again.stagedCommitInfo!.removeIndices, [carolIndex]);

      // Accepted, the same bytes then apply.
      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(await epochOf(bob), before + BigInt.one);
      expect(await bob.groupMembers(groupIdBytes: groupIdBytes), hasLength(2));
    });

    test('a member being removed sees it, and stays active until it '
        'processes the commit', () async {
      final commit = await alice.removeMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        memberIndices: [await indexOf(alice, carolId)],
      );
      final inspected = await carol.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(inspected.stagedCommitInfo!.selfRemoved, isTrue);
      expect(await carol.groupIsActive(groupIdBytes: groupIdBytes), isTrue);
    });

    test("names each proposal's own sender when a commit carries another "
        "member's proposal by reference", () async {
      final bobIndex = await indexOf(alice, bobId);
      final proposal = await bob.proposeRemove(
        groupIdBytes: groupIdBytes,
        signerBytes: bobId.signerBytes,
        memberIndex: await indexOf(bob, carolId),
      );
      // Every member receives the proposal; a commit refers to it by hash.
      for (final engine in [alice, carol]) {
        await engine.processMessage(
          groupIdBytes: groupIdBytes,
          messageBytes: proposal.proposalMessage,
        );
      }
      final commit = await alice.commitToPendingProposals(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );

      final inspected = await carol.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      final removal = inspected.stagedCommitInfo!.proposals.single;
      expect(removal.proposalType, MlsProposalType.remove);
      expect(removal.senderIndex, bobIndex);
      expect(removal.byReference, isTrue);
      expect(inspected.senderIndex, await indexOf(carol, aliceId));
    });

    test('shows the group context extensions a commit leads to — set with a '
        'typed RequiredCapabilities, which OpenMLS insists on', () async {
      final commit = await alice.flexibleCommit(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        options: FlexibleCommitOptions(
          addKeyPackages: const [],
          removeIndices: Uint32List(0),
          forceSelfUpdate: true,
          consumePendingProposals: false,
          groupContextExtensions: [
            requiredCapabilities(extensions: [appExtensionType]),
            MlsExtension(
              extensionType: appExtensionType,
              data: Uint8List.fromList([1, 2, 3]),
            ),
          ],
          createGroupInfo: false,
          useRatchetTreeExtension: false,
        ),
      );
      final info = (await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      )).stagedCommitInfo!;
      expect(
        info.proposals.map((proposal) => proposal.proposalType),
        contains(MlsProposalType.groupContextExtensions),
      );
      // The application's own; RequiredCapabilities is OpenMLS's.
      final extension = info.groupContextExtensions.single;
      expect(extension.extensionType, appExtensionType);
      expect(extension.data, [1, 2, 3]);

      // Applied, the group context carries both, and keeps them.
      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      final update = await alice.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final later = (await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: update.commit,
      )).stagedCommitInfo!;
      expect(later.groupContextExtensions.single.data, [1, 2, 3]);
    });

    test('an extension of a type OpenMLS defines must be well-formed', () {
      expect(
        alice.flexibleCommit(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          options: FlexibleCommitOptions(
            addKeyPackages: const [],
            removeIndices: Uint32List(0),
            forceSelfUpdate: true,
            consumePendingProposals: false,
            groupContextExtensions: [
              MlsExtension(
                extensionType: 0x0003,
                data: Uint8List.fromList([0xFF]),
              ),
            ],
            createGroupInfo: false,
            useRatchetTreeExtension: false,
          ),
        ),
        throwsA(
          predicate((error) => '$error'.contains('Invalid extension 0x0003')),
        ),
      );
    });

    test('an application message inspected first is still processed '
        'afterwards', () async {
      final message = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: Uint8List.fromList(utf8.encode('hello')),
      );
      final inspected = await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: message.ciphertext,
      );
      expect(utf8.decode(inspected.applicationMessage!), 'hello');
      final processed = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: message.ciphertext,
      );
      expect(utf8.decode(processed.applicationMessage!), 'hello');
    });
  });

  group('FlexibleCommitOptions.keepPending', () {
    FlexibleCommitOptions selfUpdate({required bool keepPending}) =>
        FlexibleCommitOptions(
          addKeyPackages: const [],
          removeIndices: Uint32List(0),
          forceSelfUpdate: true,
          consumePendingProposals: false,
          createGroupInfo: false,
          useRatchetTreeExtension: false,
          keepPending: keepPending,
        );

    test('defaults to merging, as before', () async {
      final before = await epochOf(alice);
      await alice.flexibleCommit(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        options: FlexibleCommitOptions(
          addKeyPackages: const [],
          removeIndices: Uint32List(0),
          forceSelfUpdate: true,
          consumePendingProposals: false,
          createGroupInfo: false,
          useRatchetTreeExtension: false,
        ),
      );
      expect(await epochOf(alice), before + BigInt.one);
    });

    test('keeps the commit pending until it is merged', () async {
      final before = await epochOf(alice);
      final commit = await alice.flexibleCommit(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        options: selfUpdate(keepPending: true),
      );
      expect(await epochOf(alice), before);

      // The delivery service accepted it.
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);
      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(await epochOf(alice), before + BigInt.one);
      expect(await epochOf(bob), before + BigInt.one);

      final message = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: Uint8List.fromList(utf8.encode('after')),
      );
      final received = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: message.ciphertext,
      );
      expect(utf8.decode(received.applicationMessage!), 'after');
    });

    test("a commit that lost the race is replaced by the winner's, and the "
        'group carries on', () async {
      final before = await epochOf(alice);
      await alice.flexibleCommit(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        options: selfUpdate(keepPending: true),
      );
      // Bob's commit to the same epoch is the one the delivery service took.
      final winner = await bob.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: bobId.signerBytes,
      );

      await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: winner.commit,
      );
      expect(await epochOf(alice), before + BigInt.one);

      final message = await bob.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: bobId.signerBytes,
        message: Uint8List.fromList(utf8.encode('winner')),
      );
      final received = await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: message.ciphertext,
      );
      expect(utf8.decode(received.applicationMessage!), 'winner');
    });

    test(
      'a pending commit can be dropped, leaving the group as it was',
      () async {
        final before = await epochOf(alice);
        await alice.flexibleCommit(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          options: selfUpdate(keepPending: true),
        );
        await alice.clearPendingCommit(groupIdBytes: groupIdBytes);
        expect(await epochOf(alice), before);

        final message = await alice.createMessage(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          message: Uint8List.fromList(utf8.encode('same epoch')),
        );
        final received = await bob.processMessage(
          groupIdBytes: groupIdBytes,
          messageBytes: message.ciphertext,
        );
        expect(utf8.decode(received.applicationMessage!), 'same epoch');
      },
    );
  });
}
