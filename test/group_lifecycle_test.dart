import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

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

  group('group lifecycle', () {
    test('creates a group', () async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      expect(result.groupId, isNotEmpty);
    });

    test('creates group with specific group ID', () async {
      final customId = Uint8List.fromList(utf8.encode('my-group'));
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
        groupId: customId,
      );
      expect(result.groupId, equals(customId));
    });

    test('creates group with builder', () async {
      final result = await alice.createGroupWithBuilder(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      expect(result.groupId, isNotEmpty);
    });
  });

  group('welcome inspection', () {
    test('inspect welcome before joining', () async {
      // Alice creates group
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      // Bob creates key package
      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );

      // Alice adds Bob
      final addResult = await alice.addMembers(
        groupIdBytes: groupResult.groupId,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupResult.groupId);

      // Inspect welcome without joining
      final info = await bob.inspectWelcome(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
      );
      expect(info.groupId, equals(groupResult.groupId));
      expect(info.ciphersuite, equals(ciphersuite));
      expect(info.epoch, equals(BigInt.from(1)));
    });
  });

  group('join group from welcome with options', () {
    test('join with skip lifetime validation', () async {
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;

      final bobKp = await bob.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );

      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      final joinResult = await bob.joinGroupFromWelcomeWithOptions(
        config: defaultConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobId.signerBytes,
        skipLifetimeValidation: true,
      );
      expect(joinResult.groupId, equals(groupIdBytes));

      final members = await bob.groupMembers(groupIdBytes: joinResult.groupId);
      expect(members, hasLength(2));
    });
  });

  group('external commit join', () {
    late Uint8List groupIdBytes;

    setUp(() async {
      final result = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      groupIdBytes = result.groupId;
    });

    test('join group via external commit (v1)', () async {
      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final ratchetTree = await alice.exportRatchetTree(
        groupIdBytes: groupIdBytes,
      );

      final joinResult = await bob.joinGroupExternalCommit(
        config: defaultConfig(),
        groupInfoBytes: groupInfo,
        ratchetTreeBytes: ratchetTree,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
      );
      expect(joinResult.groupId, equals(groupIdBytes));
      expect(joinResult.commit, isNotEmpty);

      // Alice processes Bob's external commit
      final processed = await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: joinResult.commit,
      );
      expect(processed.messageType, ProcessedMessageType.stagedCommit);

      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      final bobMembers = await bob.groupMembers(groupIdBytes: groupIdBytes);
      expect(aliceMembers, hasLength(2));
      expect(bobMembers, hasLength(2));
    });

    test('join group via external commit v2', () async {
      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      final ratchetTree = await alice.exportRatchetTree(
        groupIdBytes: groupIdBytes,
      );

      final joinResult = await bob.joinGroupExternalCommitV2(
        config: defaultConfig(),
        groupInfoBytes: groupInfo,
        ratchetTreeBytes: ratchetTree,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
        aad: Uint8List.fromList(utf8.encode('external-aad')),
        skipLifetimeValidation: true,
      );
      expect(joinResult.groupId, equals(groupIdBytes));
      expect(joinResult.commit, isNotEmpty);

      await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: joinResult.commit,
      );

      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      expect(aliceMembers, hasLength(2));
    });
  });

  group('post-quantum ciphersuite (X-Wing)', () {
    const xwing = MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519;
    // Function, not a field: FRB sync calls require Openmls.init() (setUpAll),
    // which has not run yet at group-declaration time.
    MlsGroupConfig xwingConfig() => defaultConfig(suite: xwing);

    test('full lifecycle: create, add, welcome join, messaging', () async {
      final aliceXId = TestIdentity.create('alice-pq', ciphersuite: xwing);
      final bobXId = TestIdentity.create('bob-pq', ciphersuite: xwing);

      // Alice creates an X-Wing group.
      final groupResult = await alice.createGroup(
        config: xwingConfig(),
        signerBytes: aliceXId.signerBytes,
        credentialIdentity: aliceXId.credentialIdentity,
        signerPublicKey: aliceXId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;
      expect(groupIdBytes, isNotEmpty);

      // Round-trip: the stored group reports the X-Wing ciphersuite
      // (exercises native_to_ciphersuite for the new variant).
      final cs = await alice.groupCiphersuite(groupIdBytes: groupIdBytes);
      expect(cs, equals(xwing));

      // Bob creates an X-Wing key package.
      final bobKp = await bob.createKeyPackage(
        ciphersuite: xwing,
        signerBytes: bobXId.signerBytes,
        credentialIdentity: bobXId.credentialIdentity,
        signerPublicKey: bobXId.publicKey,
      );
      expect(bobKp.keyPackageBytes, isNotEmpty);

      // Alice adds Bob (commit + Welcome sealed to Bob's X-Wing key).
      final addResult = await alice.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceXId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      // Welcome inspection reports the X-Wing ciphersuite.
      final info = await bob.inspectWelcome(
        config: xwingConfig(),
        welcomeBytes: addResult.welcome,
      );
      expect(info.ciphersuite, equals(xwing));
      expect(info.groupId, equals(groupIdBytes));

      // Bob joins via Welcome (HPKE open with X-Wing key).
      final joinResult = await bob.joinGroupFromWelcome(
        config: xwingConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobXId.signerBytes,
      );
      expect(joinResult.groupId, equals(groupIdBytes));

      final aliceMembers = await alice.groupMembers(groupIdBytes: groupIdBytes);
      final bobMembers = await bob.groupMembers(groupIdBytes: groupIdBytes);
      expect(aliceMembers, hasLength(2));
      expect(bobMembers, hasLength(2));

      // Alice → Bob application message.
      final plaintext = Uint8List.fromList(utf8.encode('hello bob (xwing)'));
      final encrypted = await alice.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceXId.signerBytes,
        message: plaintext,
      );
      final received = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: encrypted.ciphertext,
      );
      expect(received.messageType, ProcessedMessageType.application);
      expect(received.applicationMessage, equals(plaintext));

      // Bob → Alice application message.
      final reply = Uint8List.fromList(utf8.encode('hi alice (xwing)'));
      final encryptedReply = await bob.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: bobXId.signerBytes,
        message: reply,
      );
      final receivedReply = await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: encryptedReply.ciphertext,
      );
      expect(receivedReply.messageType, ProcessedMessageType.application);
      expect(receivedReply.applicationMessage, equals(reply));
    });

    test('classical group is unaffected by X-Wing availability', () async {
      // A classical group continues to work end-to-end with the hybrid
      // provider in place (delegation regression check).
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      final cs = await alice.groupCiphersuite(
        groupIdBytes: groupResult.groupId,
      );
      expect(cs, equals(ciphersuite));
    });

    test('external commit join on X-Wing', () async {
      // External commits exercise the hpke_setup_sender_and_export /
      // hpke_setup_receiver_and_export delegation arms (external init via
      // schedule/mod.rs) — the only HPKE paths not covered by the
      // Welcome-based lifecycle test.
      final aliceXId = TestIdentity.create('alice-pq-ext', ciphersuite: xwing);
      final bobXId = TestIdentity.create('bob-pq-ext', ciphersuite: xwing);

      final groupResult = await alice.createGroup(
        config: xwingConfig(),
        signerBytes: aliceXId.signerBytes,
        credentialIdentity: aliceXId.credentialIdentity,
        signerPublicKey: aliceXId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;

      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceXId.signerBytes,
      );
      final ratchetTree = await alice.exportRatchetTree(
        groupIdBytes: groupIdBytes,
      );

      final joinResult = await bob.joinGroupExternalCommit(
        config: xwingConfig(),
        groupInfoBytes: groupInfo,
        ratchetTreeBytes: ratchetTree,
        signerBytes: bobXId.signerBytes,
        credentialIdentity: bobXId.credentialIdentity,
        signerPublicKey: bobXId.publicKey,
      );
      expect(joinResult.groupId, equals(groupIdBytes));

      final processed = await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: joinResult.commit,
      );
      expect(processed.messageType, ProcessedMessageType.stagedCommit);

      // Both sides share state: encrypted round-trip in both directions.
      final hello = Uint8List.fromList(utf8.encode('post-external (xwing)'));
      final enc = await bob.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: bobXId.signerBytes,
        message: hello,
      );
      final dec = await alice.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: enc.ciphertext,
      );
      expect(dec.applicationMessage, equals(hello));
    });

    test('X-Wing group state survives engine close and reopen', () async {
      // Persistence round-trip: X-Wing key material and group state are
      // serialized to the encrypted DB and restored on reopen.
      final dir = Directory.systemTemp.createTempSync('openmls_xwing_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dbPath = '${dir.path}/alice.db';
      final dbKey = testEncryptionKey();

      final aliceXId = TestIdentity.create('alice-pq-fs', ciphersuite: xwing);
      final bobXId = TestIdentity.create('bob-pq-fs', ciphersuite: xwing);

      var aliceFs = await MlsEngine.create(
        dbPath: dbPath,
        encryptionKey: dbKey,
      );
      final groupResult = await aliceFs.createGroup(
        config: xwingConfig(),
        signerBytes: aliceXId.signerBytes,
        credentialIdentity: aliceXId.credentialIdentity,
        signerPublicKey: aliceXId.publicKey,
      );
      final groupIdBytes = groupResult.groupId;

      final bobKp = await bob.createKeyPackage(
        ciphersuite: xwing,
        signerBytes: bobXId.signerBytes,
        credentialIdentity: bobXId.credentialIdentity,
        signerPublicKey: bobXId.publicKey,
      );
      final addResult = await aliceFs.addMembers(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceXId.signerBytes,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      await aliceFs.mergePendingCommit(groupIdBytes: groupIdBytes);
      await bob.joinGroupFromWelcome(
        config: xwingConfig(),
        welcomeBytes: addResult.welcome,
        signerBytes: bobXId.signerBytes,
      );

      // Close and reopen Alice's engine from the same encrypted DB file.
      await aliceFs.close();
      aliceFs = await MlsEngine.create(dbPath: dbPath, encryptionKey: dbKey);

      // Restored state still reports X-Wing and can exchange messages.
      final cs = await aliceFs.groupCiphersuite(groupIdBytes: groupIdBytes);
      expect(cs, equals(xwing));

      final msg = Uint8List.fromList(utf8.encode('after reopen (xwing)'));
      final enc = await aliceFs.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceXId.signerBytes,
        message: msg,
      );
      final dec = await bob.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: enc.ciphertext,
      );
      expect(dec.applicationMessage, equals(msg));

      final reply = Uint8List.fromList(utf8.encode('to reopened alice'));
      final encReply = await bob.createMessage(
        groupIdBytes: groupIdBytes,
        signerBytes: bobXId.signerBytes,
        message: reply,
      );
      final decReply = await aliceFs.processMessage(
        groupIdBytes: groupIdBytes,
        messageBytes: encReply.ciphertext,
      );
      expect(decReply.applicationMessage, equals(reply));

      await aliceFs.close();
    });
  });
}
