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

    test('X-Wing ciphersuite uses Ed25519 signatures', () {
      final keyPair = MlsSignatureKeyPair.generate(
        ciphersuite: MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519,
      );
      expect(keyPair.signatureScheme(), equals(0x0807));
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

    test(
      'creates a key package with X-Wing post-quantum ciphersuite',
      () async {
        const pqCiphersuite =
            MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519;
        final identity = TestIdentity.create(
          'alice-pq',
          ciphersuite: pqCiphersuite,
        );

        final result = await alice.createKeyPackage(
          ciphersuite: pqCiphersuite,
          signerBytes: identity.signerBytes,
          credentialIdentity: identity.credentialIdentity,
          signerPublicKey: identity.publicKey,
        );
        expect(result.keyPackageBytes, isNotEmpty);
      },
    );

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
}
