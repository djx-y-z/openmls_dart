import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// Group config with a wide sender-ratchet window.
///
/// Concurrent sends finish in a nondeterministic order, so the receiver sees
/// generations out of order. A wide window keeps these tests focused on state
/// integrity instead of ratchet-window policy.
MlsGroupConfig concurrentConfig() => MlsGroupConfig(
  ciphersuite: ciphersuite,
  wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
  useRatchetTreeExtension: true,
  maxPastEpochs: 0,
  paddingSize: 0,
  senderRatchetMaxOutOfOrder: 64,
  senderRatchetMaxForwardDistance: 1000,
  numberOfResumptionPsks: 0,
);

void main() {
  late MlsEngine alice;
  late MlsEngine bob;
  late TestIdentity aliceId;
  late TestIdentity bobId;
  late Uint8List groupIdBytes;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    alice = await createTestEngine();
    bob = await createTestEngine();
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');

    final created = await alice.createGroup(
      config: concurrentConfig(),
      signerBytes: aliceId.signerBytes,
      credentialIdentity: aliceId.credentialIdentity,
      signerPublicKey: aliceId.publicKey,
    );
    groupIdBytes = created.groupId;

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
    await bob.joinGroupFromWelcome(
      config: concurrentConfig(),
      welcomeBytes: addResult.welcome,
      signerBytes: bobId.signerBytes,
    );
  });

  /// Encrypt [text] with Alice's engine.
  Future<Uint8List> aliceSend(String text) async {
    final result = await alice.createMessage(
      groupIdBytes: groupIdBytes,
      signerBytes: aliceId.signerBytes,
      message: Uint8List.fromList(utf8.encode(text)),
    );
    return result.ciphertext;
  }

  /// Encrypt [text] with Bob's engine.
  Future<Uint8List> bobSend(String text) async {
    final result = await bob.createMessage(
      groupIdBytes: groupIdBytes,
      signerBytes: bobId.signerBytes,
      message: Uint8List.fromList(utf8.encode(text)),
    );
    return result.ciphertext;
  }

  /// Decrypt [ciphertext] with [receiver] and return the plaintext.
  Future<String> receive(MlsEngine receiver, Uint8List ciphertext) async {
    final processed = await receiver.processMessage(
      groupIdBytes: groupIdBytes,
      messageBytes: ciphertext,
    );
    return utf8.decode(processed.applicationMessage!);
  }

  group('concurrent operations on one engine', () {
    // Every engine method runs load-snapshot → operate → save-diff. Without a
    // lock spanning that whole sequence, two concurrent calls load the same
    // base snapshot and the second save silently overwrites the first one's
    // state (a lost update), which desynchronizes the MLS ratchet.

    test('concurrent createMessage calls all decrypt exactly once', () async {
      const count = 8;
      final sent = [for (var i = 0; i < count; i++) 'concurrent-$i'];

      final ciphertexts = await Future.wait([
        for (final text in sent) aliceSend(text),
      ]);

      // Each message must carry its own ratchet generation. If a send's state
      // update was lost, two ciphertexts share a generation and the second one
      // fails to decrypt (its key was consumed and deleted).
      final received = <String>[];
      for (final ciphertext in ciphertexts) {
        received.add(await receive(bob, ciphertext));
      }

      expect(received, unorderedEquals(sent));
    });

    test('concurrent send and receive keep the group usable', () async {
      final fromBob = await bobSend('bob-during-alice-send');

      // Alice encrypts while she is decrypting — the two calls touch the same
      // stored message secrets.
      final results = await Future.wait([
        aliceSend('alice-during-bob-receive'),
        receive(alice, fromBob),
      ]);
      expect(results[1], equals('bob-during-alice-send'));

      expect(
        await receive(bob, results[0] as Uint8List),
        equals('alice-during-bob-receive'),
      );

      // Both ratchets must still line up for the following messages.
      for (var i = 0; i < 3; i++) {
        expect(await receive(bob, await aliceSend('a$i')), equals('a$i'));
        expect(await receive(alice, await bobSend('b$i')), equals('b$i'));
      }
    });

    test('concurrent proposals are all retained', () async {
      final carolId = TestIdentity.create('carol');
      final daveId = TestIdentity.create('dave');
      final carol = await createTestEngine();
      final dave = await createTestEngine();

      final carolKp = await carol.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: carolId.signerBytes,
        credentialIdentity: carolId.credentialIdentity,
        signerPublicKey: carolId.publicKey,
      );
      final daveKp = await dave.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: daveId.signerBytes,
        credentialIdentity: daveId.credentialIdentity,
        signerPublicKey: daveId.publicKey,
      );

      // Two proposals stored concurrently: both must survive, because each
      // call rewrites the whole pending-proposal list.
      await Future.wait([
        alice.proposeAdd(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          keyPackageBytes: carolKp.keyPackageBytes,
        ),
        alice.proposeAdd(
          groupIdBytes: groupIdBytes,
          signerBytes: aliceId.signerBytes,
          keyPackageBytes: daveKp.keyPackageBytes,
        ),
      ]);

      final pending = await alice.groupPendingProposals(
        groupIdBytes: groupIdBytes,
      );
      expect(pending, hasLength(2));
    });
  });
}
