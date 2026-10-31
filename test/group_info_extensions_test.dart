import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// An application's own extension type, from the private-use range.
const appExtensionType = 0xff0a;

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
    groupIdBytes = (await alice.createGroup(
      config: defaultConfig(),
      signerBytes: aliceId.signerBytes,
      credentialIdentity: aliceId.credentialIdentity,
      signerPublicKey: aliceId.publicKey,
    )).groupId;
  });

  final secret = MlsExtension(
    extensionType: appExtensionType,
    data: Uint8List.fromList(utf8.encode('for the newcomer only')),
  );

  /// Alice adds Bob, keeping the commit pending, with [extensions] in the
  /// Welcome's GroupInfo.
  Future<CommitResult> addBob({
    List<MlsExtension>? extensions,
    bool createGroupInfo = false,
  }) async {
    final bobKp = await bob.createKeyPackage(
      ciphersuite: ciphersuite,
      signerBytes: bobId.signerBytes,
      credentialIdentity: bobId.credentialIdentity,
      signerPublicKey: bobId.publicKey,
    );
    return alice.flexibleCommit(
      groupIdBytes: groupIdBytes,
      signerBytes: aliceId.signerBytes,
      options: FlexibleCommitOptions(
        addKeyPackages: [bobKp.keyPackageBytes],
        removeIndices: Uint32List(0),
        forceSelfUpdate: false,
        consumePendingProposals: false,
        createGroupInfo: createGroupInfo,
        useRatchetTreeExtension: true,
        keepPending: true,
        groupInfoExtensions: extensions,
      ),
    );
  }

  group('group info extensions', () {
    test('reach the newcomer through the Welcome, before it joins', () async {
      final commit = await addBob(extensions: [secret]);

      // Read while the commit is still pending on Alice's side: the
      // newcomer needs them to decide whether to join at all.
      final read = await bob.welcomeGroupInfoExtensions(
        config: defaultConfig(),
        welcomeBytes: commit.welcome!,
      );
      expect(read, hasLength(1));
      expect(read.single.extensionType, appExtensionType);
      expect(read.single.data, secret.data);

      // Reading wrote nothing: the key package is still there for the join.
      await alice.mergePendingCommit(groupIdBytes: groupIdBytes);
      final joined = await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: commit.welcome!,
        signerBytes: bobId.signerBytes,
      );
      expect(joined.groupId, groupIdBytes);
    });

    test(
      'leave the ratchet tree out, and are empty when none were given',
      () async {
        final commit = await addBob();
        expect(
          await bob.welcomeGroupInfoExtensions(
            config: defaultConfig(),
            welcomeBytes: commit.welcome!,
          ),
          isEmpty,
        );
      },
    );

    test('stay out of an exported GroupInfo nobody asked for', () async {
      // The exported GroupInfo is not encrypted. The ratchet tree extension
      // alone would turn it on; with extensions it needs createGroupInfo.
      final commit = await addBob(extensions: [secret]);
      expect(commit.groupInfo, isNull);
      expect(commit.welcome, isNotNull);
    });

    test('are in the exported GroupInfo when it is asked for', () async {
      final commit = await addBob(extensions: [secret], createGroupInfo: true);
      expect(commit.groupInfo, isNotNull);
      // Plaintext: the bytes are there for anyone to read.
      expect(_contains(commit.groupInfo!, secret.data), isTrue);
      // The Welcome's copy is encrypted.
      expect(_contains(commit.welcome!, secret.data), isFalse);
    });

    test('are refused from a Welcome that was tampered with', () async {
      final commit = await addBob(extensions: [secret]);
      final tampered = Uint8List.fromList(commit.welcome!);
      tampered[tampered.length - 1] ^= 0x01;
      await expectLater(
        bob.welcomeGroupInfoExtensions(
          config: defaultConfig(),
          welcomeBytes: tampered,
        ),
        throwsA(isA<Object>()),
      );
    });

    test('are not readable by a member the Welcome is not for', () async {
      final commit = await addBob(extensions: [secret]);
      // Alice holds no key package the Welcome is addressed to.
      await expectLater(
        alice.welcomeGroupInfoExtensions(
          config: defaultConfig(),
          welcomeBytes: commit.welcome!,
        ),
        throwsA(isA<Object>()),
      );
    });

    test('reject a message that is not a Welcome', () async {
      final groupInfo = await alice.exportGroupInfo(
        groupIdBytes: groupIdBytes,
        signerBytes: aliceId.signerBytes,
      );
      await expectLater(
        bob.welcomeGroupInfoExtensions(
          config: defaultConfig(),
          welcomeBytes: groupInfo,
        ),
        throwsA(isA<Object>()),
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
