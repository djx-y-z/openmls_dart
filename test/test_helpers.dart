import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

/// Default ciphersuite used in tests.
final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

/// Create a default group config for tests.
MlsGroupConfig defaultConfig() =>
    MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

/// Extract identity bytes from a TLS-serialized Credential.
Uint8List identityFromCredential(List<int> credentialBytes) =>
    MlsCredential.deserialize(
      bytes: Uint8List.fromList(credentialBytes),
    ).identity();

/// Helper to create a test identity (key pair + credential + signer bytes).
class TestIdentity {
  TestIdentity._({
    required this.signerBytes,
    required this.publicKey,
    required this.credentialIdentity,
  });

  factory TestIdentity.create(
    String name, {
    MlsCiphersuite ciphersuite =
        MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
  }) {
    final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
    final pubKey = keyPair.publicKey();
    final privKey = keyPair.privateKey();
    final identity = Uint8List.fromList(utf8.encode(name));
    final signer = serializeSigner(
      ciphersuite: ciphersuite,
      privateKey: privKey,
      publicKey: pubKey,
    );
    return TestIdentity._(
      signerBytes: signer,
      publicKey: pubKey,
      credentialIdentity: identity,
    );
  }

  final Uint8List signerBytes;
  final Uint8List publicKey;
  final Uint8List credentialIdentity;

  /// TLS-serialized credential for use with APIs that accept serialized credentials.
  Uint8List get serializedCredential =>
      MlsCredential.basic(identity: credentialIdentity).serialize();
}

/// Generate a random 32-byte encryption key for test databases.
Uint8List testEncryptionKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}

/// Create a test MlsEngine with an in-memory SQLCipher database.
Future<MlsEngine> createTestEngine() async =>
    MlsEngine.create(dbPath: ':memory:', encryptionKey: testEncryptionKey());
