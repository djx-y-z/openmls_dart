import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// An application's own extension type, from the private-use range.
const appExtensionType = 0xff0a;

/// Fails unless the call throws an error whose text contains [text].
Matcher throwsWith(String text) => throwsA(
  predicate((error) => '$error'.contains(text), 'an error naming "$text"'),
);

void main() {
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

  setUp(() async {
    alice = await createTestEngine();
    bob = await createTestEngine();
    carol = await createTestEngine();
    aliceId = TestIdentity.create('alice');
    bobId = TestIdentity.create('bob');
    carolId = TestIdentity.create('carol');
    groupIdBytes = (await alice.createGroup(
      config: defaultConfig(),
      signerBytes: aliceId.signerBytes,
      credentialIdentity: aliceId.credentialIdentity,
      signerPublicKey: aliceId.publicKey,
    )).groupId;
  });

  final shared = MlsExtension(
    extensionType: appExtensionType,
    data: Uint8List.fromList(utf8.encode('for the new epoch')),
  );

  Future<Uint8List> keyPackage(MlsEngine engine, TestIdentity id) async =>
      (await engine.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: id.signerBytes,
        credentialIdentity: id.credentialIdentity,
        signerPublicKey: id.publicKey,
      )).keyPackageBytes;

  /// Alice commits adding [keyPackages], with [extensions] for the GroupInfo.
  /// Merged at once unless [keepPending].
  Future<CommitResult> commit({
    List<Uint8List> keyPackages = const [],
    List<MlsExtension>? extensions,
    bool createGroupInfo = false,
    bool useRatchetTreeExtension = true,
    bool keepPending = false,
  }) => alice.flexibleCommit(
    groupIdBytes: groupIdBytes,
    signerBytes: aliceId.signerBytes,
    options: FlexibleCommitOptions(
      addKeyPackages: keyPackages,
      removeIndices: Uint32List(0),
      forceSelfUpdate: keyPackages.isEmpty,
      consumePendingProposals: false,
      createGroupInfo: createGroupInfo,
      useRatchetTreeExtension: useRatchetTreeExtension,
      keepPending: keepPending,
      groupInfoExtensions: extensions,
    ),
  );

  Future<WelcomeGroupInfoExtensions> read(
    MlsEngine engine,
    Uint8List welcome, {
    Uint8List? ratchetTree,
  }) => engine.welcomeGroupInfoExtensions(
    config: defaultConfig(),
    welcomeBytes: welcome,
    ratchetTreeBytes: ratchetTree,
  );

  group('group info extensions', () {
    test('reach the newcomer before it joins, with the member that signed '
        'them', () async {
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [shared],
      );

      final got = await read(bob, result.welcome!);
      expect(got.extensions, hasLength(1));
      expect(got.extensions.single.extensionType, appExtensionType);
      expect(got.extensions.single.data, shared.data);
      // Alice signed the GroupInfo, from her leaf: index 0 of the new tree.
      expect(got.signer.index, 0);
      expect(
        identityFromCredential(got.signer.credential),
        aliceId.credentialIdentity,
      );
      expect(got.signer.signatureKey, aliceId.publicKey);

      // Reading wrote nothing: the key package is still there for the join.
      final joined = await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: result.welcome!,
        signerBytes: bobId.signerBytes,
      );
      expect(joined.groupId, groupIdBytes);
    });

    test('are read in the documented order: the commit merged first, then '
        'the Welcome sent', () async {
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [shared],
        keepPending: true,
      );
      // The delivery service accepted the commit.
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);

      final got = await read(bob, result.welcome!);
      expect(got.extensions.single.data, shared.data);
    });

    test('are the same copy for every member one commit adds', () async {
      final result = await commit(
        keyPackages: [
          await keyPackage(bob, bobId),
          await keyPackage(carol, carolId),
        ],
        extensions: [shared],
      );

      final byBob = await read(bob, result.welcome!);
      final byCarol = await read(carol, result.welcome!);
      expect(byBob.extensions.single.data, shared.data);
      expect(byCarol.extensions.single.data, shared.data);
    });

    test(
      'leave the ratchet tree out, and are empty when none were given',
      () async {
        final result = await commit(
          keyPackages: [await keyPackage(bob, bobId)],
        );
        expect((await read(bob, result.welcome!)).extensions, isEmpty);
      },
    );

    test('an empty list is the same as none', () async {
      // The ratchet tree extension turns the exported GroupInfo on by itself;
      // with no extension to keep out of it, that is what happens.
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [],
      );
      expect(result.groupInfo, isNotNull);
    });

    test('stay out of an exported GroupInfo nobody asked for', () async {
      // The exported GroupInfo is not encrypted. The ratchet tree extension
      // alone would turn it on; with extensions it needs createGroupInfo.
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [shared],
      );
      expect(result.groupInfo, isNull);
      expect(result.welcome, isNotNull);
    });

    test('are in the exported GroupInfo when it is asked for', () async {
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [shared],
        createGroupInfo: true,
      );
      expect(result.groupInfo, isNotNull);
      // Plaintext: the bytes are there for anyone to read.
      expect(_contains(result.groupInfo!, shared.data), isTrue);
      // The Welcome's copy is encrypted.
      expect(_contains(result.welcome!, shared.data), isFalse);
    });

    test('are read only from a Welcome that stages: without its ratchet tree '
        'extension, the tree of its epoch is required', () async {
      final before = await alice.exportRatchetTree(groupIdBytes: groupIdBytes);
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [shared],
        useRatchetTreeExtension: false,
      );
      final current = await alice.exportRatchetTree(groupIdBytes: groupIdBytes);

      await expectLater(
        read(bob, result.welcome!),
        throwsWith('No ratchet tree available'),
      );
      await expectLater(
        read(bob, result.welcome!, ratchetTree: before),
        throwsWith('tree hash does not match'),
      );
      final got = await read(bob, result.welcome!, ratchetTree: current);
      expect(got.extensions.single.data, shared.data);
      expect(got.signer.index, 0);
    });

    test(
      'are refused, rather than dropped, when nothing would carry them',
      () async {
        // Adding nobody, the commit has no Welcome, and without createGroupInfo
        // no exported GroupInfo either.
        await expectLater(
          commit(extensions: [shared]),
          throwsWith('nothing to carry them'),
        );
        // Refused before anything was written: the group is where it was.
        expect(await alice.groupEpoch(groupIdBytes: groupIdBytes), BigInt.zero);

        // With createGroupInfo they go into the exported GroupInfo, in the clear.
        final result = await commit(
          extensions: [shared],
          createGroupInfo: true,
        );
        expect(result.welcome, isNull);
        expect(_contains(result.groupInfo!, shared.data), isTrue);
      },
    );

    test('of a type a GroupInfo may not carry are refused', () async {
      final bobKp = await keyPackage(bob, bobId);
      for (final extension in [
        // RequiredCapabilities, which belongs in the group context.
        MlsExtension(
          extensionType: 0x0003,
          data: Uint8List.fromList([0, 0, 0]),
        ),
        // LastResort, which belongs in a key package.
        MlsExtension(extensionType: 0x000a, data: Uint8List(0)),
      ]) {
        await expectLater(
          commit(keyPackages: [bobKp], extensions: [extension]),
          throwsWith('not allowed in the group info'),
          reason: 'type 0x${extension.extensionType.toRadixString(16)}',
        );
      }
      // Nothing of either attempt was kept: the group is at its epoch, and no
      // commit is pending, for one would refuse the next (flexibleCommit
      // does not replace a pending commit).
      expect(await alice.groupEpoch(groupIdBytes: groupIdBytes), BigInt.zero);
      final added = await commit(keyPackages: [bobKp]);
      expect(added.welcome, isNotNull);
    });

    // The last byte is in encrypted_group_info, which is also the HPKE context
    // of the group secrets: decryption fails, before staging, as it would
    // for inspectWelcome. The staging test above is the one that shows the
    // checks gate the result.
    test('are refused from a Welcome that does not decrypt', () async {
      final result = await commit(
        keyPackages: [await keyPackage(bob, bobId)],
        extensions: [shared],
      );
      final tampered = Uint8List.fromList(result.welcome!);
      tampered[tampered.length - 1] ^= 0x01;
      await expectLater(
        read(bob, tampered),
        throwsWith('Failed to process welcome'),
      );
    });

    test(
      'cannot be read by a client the Welcome is not addressed to',
      () async {
        final result = await commit(
          keyPackages: [await keyPackage(bob, bobId)],
          extensions: [shared],
        );
        // Carol holds no key package the Welcome is addressed to.
        await expectLater(
          read(carol, result.welcome!),
          throwsWith('Failed to process welcome'),
        );
      },
    );

    test('reject a message that is not a Welcome', () async {
      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      await expectLater(
        read(bob, groupInfo),
        throwsWith('Message is not a Welcome'),
      );
    });
  });
}

bool _contains(Uint8List haystack, Uint8List needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
