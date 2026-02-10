import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import '../utils.dart';
import '../widgets/demo_card.dart';

Uint8List _testKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}

class KeysDemoTab extends StatefulWidget {
  const KeysDemoTab({super.key});

  @override
  State<KeysDemoTab> createState() => _KeysDemoTabState();
}

class _KeysDemoTabState extends State<KeysDemoTab> {
  String? _result;
  bool _loading = false;

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _result = null;
    });
    try {
      final r = StringBuffer();
      final cs = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

      final signer = MlsSignatureKeyPair.generate(ciphersuite: cs);
      final pub = signer.publicKey();
      r.writeln('1. MlsSignatureKeyPair generated');
      r.writeln('   Public key: ${hex(pub, max: 32)}');
      r.writeln('   Scheme: ${signer.signatureScheme()}');
      r.writeln();

      final ser = signer.serialize();
      final des = MlsSignatureKeyPair.deserializePublic(bytes: ser);
      r.writeln('2. Serialize / deserialize');
      r.writeln('   Match: ${hex(pub) == hex(des.publicKey())}');
      r.writeln();

      final priv = signer.privateKey();
      final raw = MlsSignatureKeyPair.fromRaw(
        ciphersuite: cs,
        privateKey: priv,
        publicKey: pub,
      );
      r.writeln('3. Reconstruct from raw bytes');
      r.writeln('   Match: ${hex(pub) == hex(raw.publicKey())}');
      r.writeln();

      final cred = MlsCredential.basic(identity: utf8.encode('alice'));
      r.writeln('4. BasicCredential');
      r.writeln('   Identity: "${utf8.decode(cred.identity())}"');
      r.writeln('   Type: ${cred.credentialType()} (1 = Basic)');
      r.writeln();

      final credBytes = cred.serialize();
      final credRes = MlsCredential.deserialize(bytes: credBytes);
      r.writeln('5. Credential round-trip');
      r.writeln('   Restored: "${utf8.decode(credRes.identity())}"');
      r.writeln();

      final suites = supportedCiphersuites();
      r.writeln('6. Supported ciphersuites');
      for (final s in suites) {
        r.writeln('   - $s');
      }
      r.writeln();

      final client = await MlsEngine.create(
        dbPath: ':memory:',
        encryptionKey: _testKey(),
      );
      final signerBytes = serializeSigner(
        ciphersuite: cs,
        privateKey: signer.privateKey(),
        publicKey: signer.publicKey(),
      );
      final kpResult = await client.createKeyPackageWithOptions(
        ciphersuite: cs,
        signerBytes: signerBytes,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: signer.publicKey(),
        options: KeyPackageOptions(
          lifetimeSeconds: BigInt.from(86400),
          lastResort: true,
        ),
      );
      r.writeln('7. Key package with options');
      r.writeln('   Lifetime: 86400s, Last resort: true');
      r.writeln('   Size: ${kpResult.keyPackageBytes.length} bytes');
      r.writeln();

      final cert = Uint8List.fromList(utf8.encode('mock-x509-cert'));
      final x509 = MlsCredential.x509(certificateChain: [cert]);
      final x509Ser = x509.serialize();
      final x509Res = MlsCredential.deserialize(bytes: x509Ser);
      r.writeln('8. X.509 credential');
      r.writeln('   Type: ${x509.credentialType()} (2 = X.509)');
      r.writeln(
        '   Round-trip: ${utf8.decode(x509Res.certificates()[0]) == utf8.decode(cert)}',
      );

      setState(() => _result = r.toString());
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: DemoCard(
        title: 'Key Generation & Credentials',
        description:
            'Generate key pairs, serialize/deserialize, create Basic and '
            'X.509 credentials, key packages with options.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
