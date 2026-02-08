import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../utils.dart';

/// Demonstrates key generation, serialization, and credentials.
Future<void> runKeysDemo() async {
  printHeader('Keys Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

  // 1. Generate a signature key pair
  final signer = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final publicKey = signer.publicKey();
  printStep(1, 'MlsSignatureKeyPair generated', [
    'Ciphersuite: $ciphersuite',
    'Public key size: ${publicKey.length} bytes',
    'Public key: ${bytesToHex(publicKey, maxLength: 32)}',
    'Signature scheme: ${signer.signatureScheme()}',
  ]);
  print('');

  // 2. Serialize and deserialize
  final serialized = signer.serialize();
  final deserialized = MlsSignatureKeyPair.deserializePublic(bytes: serialized);
  final deserializedPubKey = deserialized.publicKey();
  printStep(2, 'Serialize / deserialize round-trip', [
    'Serialized size: ${serialized.length} bytes',
    'Public keys match: ${bytesToHex(publicKey) == bytesToHex(deserializedPubKey)}',
  ]);
  print('');

  // 3. Create from raw key bytes
  final privateKey = signer.privateKey();
  final fromRaw = MlsSignatureKeyPair.fromRaw(
    ciphersuite: ciphersuite,
    privateKey: privateKey,
    publicKey: publicKey,
  );
  printStep(3, 'Reconstruct from raw bytes', [
    'Private key size: ${privateKey.length} bytes',
    'Public keys match: ${bytesToHex(publicKey) == bytesToHex(fromRaw.publicKey())}',
  ]);
  print('');

  // 4. Create a BasicCredential
  final credential = MlsCredential.basic(identity: utf8.encode('alice'));
  final identity = credential.identity();
  printStep(4, 'BasicCredential created', [
    'Identity: "${utf8.decode(identity)}"',
    'Credential type: ${credential.credentialType()} (1 = Basic)',
  ]);
  print('');

  // 5. Serialize / deserialize credential
  final credBytes = credential.serialize();
  final credRestored = MlsCredential.deserialize(bytes: credBytes);
  printStep(5, 'Credential round-trip', [
    'Serialized size: ${credBytes.length} bytes',
    'Restored identity: "${utf8.decode(credRestored.identity())}"',
  ]);
  print('');

  // 6. List supported ciphersuites
  final suites = supportedCiphersuites();
  printStep(6, 'Supported ciphersuites', [for (final s in suites) '- $s']);
  print('');

  // 7. Create key package with options (lifetime, last-resort)
  final storage = InMemoryMlsStorage();
  final client = MlsClient(storage);
  final signerBytes = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: signer.privateKey(),
    publicKey: signer.publicKey(),
  );
  final kpOptions = KeyPackageOptions(
    lifetimeSeconds: BigInt.from(86400), // 1 day
    lastResort: true,
  );
  final kpResult = await client.createKeyPackageWithOptions(
    ciphersuite: ciphersuite,
    signerBytes: signerBytes,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: signer.publicKey(),
    options: kpOptions,
  );
  printStep(7, 'Key package with options', [
    'Lifetime: 86400 seconds (1 day)',
    'Last resort: true',
    'Key package size: ${kpResult.keyPackageBytes.length} bytes',
  ]);
  print('');

  // 8. X.509 credential
  final cert = Uint8List.fromList(utf8.encode('mock-x509-certificate'));
  final x509Cred = MlsCredential.x509(certificateChain: [cert]);
  final x509Serialized = x509Cred.serialize();
  final x509Restored = MlsCredential.deserialize(bytes: x509Serialized);
  final restoredCerts = x509Restored.certificates();
  printStep(8, 'X.509 credential', [
    'Credential type: ${x509Cred.credentialType()} (2 = X.509)',
    'Certificate chain length: 1',
    'Serialized size: ${x509Serialized.length} bytes',
    'Round-trip match: ${utf8.decode(restoredCerts[0]) == utf8.decode(cert)}',
  ]);

  // No dispose() needed - FRB handles memory automatically
}
