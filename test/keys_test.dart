import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late MlsEngine alice;
  late TestIdentity aliceId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    alice = await createTestEngine();
    aliceId = TestIdentity.create('alice');
  });

  group('key pair operations', () {
    test('signature scheme matches ciphersuite', () {
      final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final scheme = keyPair.signatureScheme();
      // Ed25519 scheme value is 0x0807
      expect(scheme, equals(0x0807));
    });

    test('serialize and deserialize public key', () {
      final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final pubKey = keyPair.publicKey();
      final serialized = keyPair.serialize();

      final deserialized = MlsSignatureKeyPair.deserializePublic(
        bytes: serialized,
      );
      expect(deserialized.publicKey(), equals(pubKey));
    });

    test('from_raw reconstructs key pair', () {
      final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final pubKey = keyPair.publicKey();
      final privKey = keyPair.privateKey();

      final reconstructed = MlsSignatureKeyPair.fromRaw(
        ciphersuite: ciphersuite,
        privateKey: privKey,
        publicKey: pubKey,
      );
      expect(reconstructed.publicKey(), equals(pubKey));
      expect(reconstructed.privateKey(), equals(privKey));
    });
  });

  group('key packages', () {
    test('creates a key package', () async {
      final result = await alice.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );
      expect(result.keyPackageBytes, isNotEmpty);
    });

    test('creates key package with lifetime and last-resort', () async {
      final options = KeyPackageOptions(
        lifetimeSeconds: BigInt.from(86400), // 1 day
        lastResort: true,
      );
      final result = await alice.createKeyPackageWithOptions(
        ciphersuite: ciphersuite,
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
        options: options,
      );
      expect(result.keyPackageBytes, isNotEmpty);
    });
  });

  group('last-resort key packages', () {
    /// The last_resort extension type (draft-ietf-mls-extensions).
    const lastResort = 0x000a;

    /// Bob's last-resort key package, added by Alice, and the extension types
    /// his leaf advertises once he has joined.
    Future<List<int>> joinOnLastResort(MlsCapabilities? capabilities) async {
      final bob = await createTestEngine();
      final bobId = TestIdentity.create('bob');
      final package = await bob.createKeyPackageWithOptions(
        ciphersuite: ciphersuite,
        signerBytes: bobId.signerBytes,
        credentialIdentity: bobId.credentialIdentity,
        signerPublicKey: bobId.publicKey,
        options: KeyPackageOptions(
          lastResort: true,
          capabilities: capabilities,
        ),
      );
      final group = (await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      )).groupId;
      final added = await alice.addMembers(
        groupIdBytes: group,
        signerBytes: aliceId.signerBytes,
        keyPackagesBytes: [package.keyPackageBytes],
      );
      await bob.joinGroupFromWelcome(
        config: defaultConfig(),
        welcomeBytes: added.welcome,
        signerBytes: bobId.signerBytes,
      );
      return (await bob.groupOwnLeafNode(
        groupIdBytes: group,
      )).capabilities.extensions;
    }

    test(
      'is accepted by whoever adds it, with no capabilities given',
      () async {
        // A key package's extensions have to be among its leaf's capabilities
        // (RFC 9420 §10.1); the engine lists last_resort itself.
        expect(await joinOnLastResort(null), contains(lastResort));
      },
    );

    test('keeps the capabilities it is given, and adds last_resort to '
        'them', () async {
      final extensions = await joinOnLastResort(
        MlsCapabilities(
          versions: Uint16List(0),
          ciphersuites: Uint16List(0),
          extensions: Uint16List.fromList([0xff0a]),
          proposals: Uint16List(0),
          credentials: Uint16List(0),
        ),
      );
      expect(extensions, containsAll([0xff0a, lastResort]));
    });
  });

  group('X-Wing post-quantum keys', () {
    const xwing = MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519;

    test('X-Wing ciphersuite uses Ed25519 signature scheme', () {
      final keyPair = MlsSignatureKeyPair.generate(ciphersuite: xwing);
      // X-Wing suite signs with Ed25519 (scheme value 0x0807).
      expect(keyPair.signatureScheme(), equals(0x0807));
    });

    test('creates an X-Wing key package', () async {
      final xwingId = TestIdentity.create('alice-pq', ciphersuite: xwing);
      final result = await alice.createKeyPackage(
        ciphersuite: xwing,
        signerBytes: xwingId.signerBytes,
        credentialIdentity: xwingId.credentialIdentity,
        signerPublicKey: xwingId.publicKey,
      );
      expect(result.keyPackageBytes, isNotEmpty);
    });
  });
}
