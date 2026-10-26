import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show PanicException;
import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// What `inspectMessage`, `decodeExternalSenders` and the pending-commit guard
/// promise, held from the outside: written when #57 was merged, apart from
/// that pull request's own tests.
void main() {
  setUpAll(() async {
    await Openmls.init();
  });

  late Directory dir;
  late MlsEngine alice;
  late MlsEngine bob;
  late TestIdentity aliceId;
  late TestIdentity bobId;
  late Uint8List groupIdBytes;

  /// Alice's group with Bob in it. Bob keeps his state in a database file, so
  /// whatever an inspection leaves behind shows in its bytes.
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('openmls_inspect_');
    alice = await createTestEngine();
    bob = await MlsEngine.create(
      dbPath: '${dir.path}/bob.db',
      encryptionKey: testEncryptionKey(),
    );
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');
    groupIdBytes = (await alice.createGroup(
      config: defaultConfig(),
      signerBytes: aliceId.signerBytes,
      credentialIdentity: aliceId.credentialIdentity,
      signerPublicKey: aliceId.publicKey,
    )).groupId;
    final keyPackage = await bob.createKeyPackage(
      ciphersuite: ciphersuite,
      signerBytes: bobId.signerBytes,
      credentialIdentity: bobId.credentialIdentity,
      signerPublicKey: bobId.publicKey,
    );
    final added = await alice.addMembers(
      groupIdBytes: groupIdBytes,
      signerBytes: aliceId.signerBytes,
      keyPackagesBytes: [keyPackage.keyPackageBytes],
    );
    await bob.joinGroupFromWelcome(
      config: defaultConfig(),
      welcomeBytes: added.welcome,
      signerBytes: bobId.signerBytes,
    );
  });

  tearDown(() async {
    await bob.close();
    dir.deleteSync(recursive: true);
  });

  /// Every file Bob's engine keeps — the database, a journal, the lock
  /// sidecar — so a write to any of them shows.
  Map<String, List<int>> bobFiles() => {
    for (final file in dir.listSync().whereType<File>())
      file.uri.pathSegments.last: file.readAsBytesSync(),
  };

  Future<BigInt> epochOf(MlsEngine engine) =>
      engine.groupEpoch(groupIdBytes: groupIdBytes);

  /// An ExternalSenders body (RFC 9420, 12.1.8.1) admitting [sender]: the
  /// list behind its length, then the signature key and the credential, each
  /// length a single byte while it is under 64.
  Uint8List externalSendersBody(TestIdentity sender) {
    final credential = MlsCredential.basic(
      identity: sender.credentialIdentity,
    ).serialize();
    final entry = [sender.publicKey.length, ...sender.publicKey, ...credential];
    expect(entry.length, lessThan(64));
    return Uint8List.fromList([entry.length, ...entry]);
  }

  group('inspectMessage changes nothing', () {
    test('for a commit, which then processes as usual', () async {
      final commit = await alice.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final epoch = await epochOf(bob);
      final before = bobFiles();

      final inspected = await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(inspected.messageType, ProcessedMessageType.stagedCommit);
      expect(bobFiles(), before);
      expect(await epochOf(bob), epoch);

      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(await epochOf(bob), epoch + BigInt.one);
      // The comparison does see a write when there is one.
      expect(bobFiles(), isNot(before));
    });

    test('for a proposal, which is not stored until processed', () async {
      final proposal = await alice.proposeSelfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final before = bobFiles();

      final inspected = await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: proposal.proposalMessage,
      );
      expect(inspected.messageType, ProcessedMessageType.proposal);
      expect(bobFiles(), before);
      expect(
        await bob.groupHasPendingProposals(groupIdBytes: groupIdBytes),
        isFalse,
      );

      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: proposal.proposalMessage,
      );
      expect(
        await bob.groupHasPendingProposals(groupIdBytes: groupIdBytes),
        isTrue,
      );
    });

    test('for an application message, which still decrypts after', () async {
      final message = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        message: utf8.encode('hello'),
      );
      final before = bobFiles();

      final inspected = await bob.inspectMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: message.ciphertext,
      );
      expect(utf8.decode(inspected.applicationMessage!), 'hello');
      expect(bobFiles(), before);

      final processed = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: message.ciphertext,
      );
      expect(utf8.decode(processed.applicationMessage!), 'hello');
    });

    // The two share one code path and differ in a single flag, so the
    // applying side is held here directly; elsewhere only the resync tests of
    // group_lifecycle_test.dart notice, in passing, if it stops applying.
    test(
      'while processMessageWithInspect does apply the commit it reports',
      () async {
        final commit = await alice.selfUpdate(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        );
        final epoch = await epochOf(bob);
        final before = bobFiles();

        final result = await bob.processMessageWithInspect(
          groupIdBytes: groupIdBytes,
          messageBytes: commit.commit,
        );
        expect(result.messageType, ProcessedMessageType.stagedCommit);
        expect(result.stagedCommitInfo, isNotNull);
        expect(await epochOf(bob), epoch + BigInt.one);
        expect(bobFiles(), isNot(before));
        expect(
          await bob.groupEpochAuthenticator(groupIdBytes: groupIdBytes),
          await alice.groupEpochAuthenticator(groupIdBytes: groupIdBytes),
        );
      },
    );
  });

  group('decodeExternalSenders', () {
    test('reads the body it is given', () {
      final ds = TestIdentity.create('delivery-service');
      final senders = decodeExternalSenders(data: externalSendersBody(ds));
      expect(senders.single.signatureKey, ds.publicKey);
    });

    // The bytes are the caller's, and on the web a panic aborts the module.
    test('answers hostile bytes with an error, never a panic', () {
      final valid = externalSendersBody(TestIdentity.create('ds'));

      /// What the decoder read, or null when it refused the bytes.
      List<MlsExternalSenderInfo>? decode(List<int> bytes) {
        try {
          return decodeExternalSenders(data: Uint8List.fromList(bytes));
        } on PanicException catch (error) {
          fail('panicked on ${bytes.length} bytes: $error');
        } catch (_) {
          return null;
        }
      }

      // What does not encode a list of senders is refused: every truncation
      // of a valid body, lengths that claim more than follows, and data after
      // the list. An empty list is one.
      for (var n = 0; n < valid.length; n++) {
        expect(decode(valid.sublist(0, n)), isNull, reason: 'first $n bytes');
      }
      for (final bytes in const [
        [0x3F],
        [0x7F, 0xFF],
        [0xBF, 0xFF, 0xFF, 0xFF],
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
      ]) {
        expect(decode(bytes), isNull, reason: '$bytes');
      }
      expect(decode([...valid, ...valid]), isNull);
      expect(decode([0, 1, 2, 3]), isNull);
      expect(decode([0]), isEmpty);

      // Every byte set to each boundary of a variable-length prefix, and
      // random bytes: whatever it makes of them — a key's or a credential's
      // bytes changed still decode — the decoder answers.
      for (var i = 0; i < valid.length; i++) {
        for (final b in const [
          0x00,
          0x3F,
          0x40,
          0x7F,
          0x80,
          0xBF,
          0xC0,
          0xFF,
        ]) {
          decode(List.of(valid)..[i] = b);
        }
      }
      final random = Random(57);
      for (var i = 0; i < 2000; i++) {
        decode(List.generate(random.nextInt(300), (_) => random.nextInt(256)));
      }
    });
  });

  group('a pending commit', () {
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

    test('is replaced by no call that makes a commit, and still merges as '
        'the one the others applied', () async {
      final carol = await createTestEngine();
      final carolId = TestIdentity.create('carol');
      final carolKeyPackage = (await carol.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: carolId.signerBytes,
        credentialIdentity: carolId.credentialIdentity,
        signerPublicKey: carolId.publicKey,
      )).keyPackageBytes;
      final bobIndex = (await alice.groupMembers(
        groupIdBytes: groupIdBytes,
      )).singleWhere((member) => member.index != 0).index;

      final pending = await alice.flexibleCommit(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        options: selfUpdate(keepPending: true),
      );
      final epoch = await epochOf(alice);

      final attempts = <String, Future<Object?> Function()>{
        'flexibleCommit, kept pending': () => alice.flexibleCommit(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          options: selfUpdate(keepPending: true),
        ),
        'flexibleCommit, merged': () => alice.flexibleCommit(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          options: selfUpdate(keepPending: false),
        ),
        'selfUpdate': () => alice.selfUpdate(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        ),
        'addMembers': () => alice.addMembers(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          keyPackagesBytes: [carolKeyPackage],
        ),
        'removeMembers': () => alice.removeMembers(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          memberIndices: [bobIndex],
        ),
        'commitToPendingProposals': () => alice.commitToPendingProposals(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
        ),
        'updateGroupContextExtensions': () =>
            alice.updateGroupContextExtensions(
              groupIdBytes: groupIdBytes,
              signerBytes: aliceId.signerBytes,
              extensions: const [],
            ),
      };
      for (final MapEntry(key: name, value: attempt) in attempts.entries) {
        await expectLater(
          attempt(),
          throwsA(isNot(isA<PanicException>())),
          reason: name,
        );
        expect(await epochOf(alice), epoch, reason: name);
      }

      // The pending commit is the one Bob applies and Alice merges.
      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: pending.commit,
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);
      expect(await epochOf(alice), epoch + BigInt.one);
      expect(await epochOf(bob), epoch + BigInt.one);
      expect(
        await bob.groupEpochAuthenticator(groupIdBytes: groupIdBytes),
        await alice.groupEpochAuthenticator(groupIdBytes: groupIdBytes),
      );
    });

    test('clears by hand, after which a commit goes through', () async {
      await alice.flexibleCommit(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        options: selfUpdate(keepPending: true),
      );
      await alice.clearPendingCommit(groupIdBytes: groupIdBytes);
      final epoch = await epochOf(alice);
      final commit = await alice.selfUpdate(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: commit.commit,
      );
      expect(await epochOf(alice), epoch + BigInt.one);
      expect(await epochOf(bob), epoch + BigInt.one);
    });
  });

  test('an ExternalSenders change proposed on its own shows before it is '
      'stored, and in the commit that applies it', () async {
    final ds = TestIdentity.create('delivery-service');
    final proposal = await bob.proposeGroupContextExtensions(
      groupIdBytes: groupIdBytes,
      signerBytes: bobId.signerBytes,
      extensions: [
        MlsExtension(extensionType: 0x0005, data: externalSendersBody(ds)),
      ],
    );

    final inspected = await alice.inspectMessage(
      groupIdBytes: groupIdBytes,
      messageBytes: proposal.proposalMessage,
    );
    expect(inspected.sender!.kind, MlsSenderKind.member);
    expect(
      inspected.proposalInfo!.extensions.map((e) => e.extensionType),
      contains(0x0005),
    );

    await alice.processMessage(
      groupIdBytes: groupIdBytes,
      messageBytes: proposal.proposalMessage,
    );
    final commit = await alice.commitToPendingProposals(
      groupIdBytes: groupIdBytes,
      signerBytes: aliceId.signerBytes,
    );
    final info = (await bob.inspectMessage(
      groupIdBytes: groupIdBytes,
      messageBytes: commit.commit,
    )).stagedCommitInfo!;
    expect(info.externalSenders.single.signatureKey, ds.publicKey);
    final applied = info.proposals.single;
    expect(applied.byReference, isTrue);
    expect(applied.sender.kind, MlsSenderKind.member);
    expect(applied.extensions.map((e) => e.extensionType), contains(0x0005));
  });
}
