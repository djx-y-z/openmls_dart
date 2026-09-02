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

/// Post-quantum demo: runs the full group lifecycle on a classical suite (a
/// regression check), then on three experimental post-quantum suites chosen to
/// hit three different backend paths — libcrux-backed X-Wing, a RustCrypto
/// hybrid suite that shares X-Wing's KEM but carries an ML-DSA signature, and a
/// pure ML-KEM suite. On web this doubles as the WASM runtime smoke test; no CI
/// gate builds or runs wasm32, so it has to be re-run by hand after any change
/// to ciphersuites or crypto routing.
class PostQuantumDemoTab extends StatefulWidget {
  const PostQuantumDemoTab({super.key});

  @override
  State<PostQuantumDemoTab> createState() => _PostQuantumDemoTabState();
}

class _PostQuantumDemoTabState extends State<PostQuantumDemoTab> {
  String? _result;
  bool _loading = false;

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _result = null;
    });
    try {
      final r = StringBuffer();

      // 1. Classical-suite regression: the hybrid crypto provider must not
      //    affect existing ciphersuites.
      const classical = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
      r.writeln('1. classical lifecycle ($classical)');
      await _lifecycle(classical, 'classical', r);

      // 2. X-Wing — the one suite delegated to the libcrux provider.
      const xwing = MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519;
      r.writeln('2. X-Wing lifecycle, libcrux-backed ($xwing)');
      await _lifecycle(xwing, 'X-Wing', r);

      // 3. ML-KEM-768 + X25519 with an ML-DSA-44 signature. Two things only
      //    this suite covers: it shares X-Wing's KEM yet must run on
      //    RustCrypto (a routing regression would send it to libcrux, which
      //    has no ML-DSA and rejects it outright), and it is the only
      //    post-quantum *signature* in this demo.
      const mldsa =
          MlsCiphersuite.mls128Mlkem768X25519Chacha20Poly1305Sha384Mldsa44;
      r.writeln('3. ML-KEM-768+X25519 / ML-DSA-44 lifecycle ($mldsa)');
      await _lifecycle(mldsa, 'ML-DSA-44', r);

      // 4. A pure ML-KEM suite — no hybrid KEM, a different code path again.
      const mlkem = MlsCiphersuite.mls128Mlkem768Aes256GcmSha384Ed25519;
      r.writeln('4. ML-KEM-768 lifecycle ($mlkem)');
      await _lifecycle(mlkem, 'ML-KEM-768', r);

      r.writeln(
        'RESULT: PASS — classical, X-Wing, ML-DSA and ML-KEM lifecycles '
        'verified on this platform',
      );
      setState(() => _result = r.toString());
    } catch (e) {
      setState(() => _result = 'RESULT: FAIL\nError: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _lifecycle(
    MlsCiphersuite cs,
    String label,
    StringBuffer r,
  ) async {
    final cfg = MlsGroupConfig.defaultConfig(ciphersuite: cs);

    final aliceClient = await MlsEngine.create(
      dbPath: ':memory:',
      encryptionKey: _testKey(),
    );
    final aliceKp = MlsSignatureKeyPair.generate(ciphersuite: cs);
    final aliceSigner = serializeSigner(
      ciphersuite: cs,
      privateKey: aliceKp.privateKey(),
      publicKey: aliceKp.publicKey(),
    );

    final bobClient = await MlsEngine.create(
      dbPath: ':memory:',
      encryptionKey: _testKey(),
    );
    final bobKp = MlsSignatureKeyPair.generate(ciphersuite: cs);
    final bobSigner = serializeSigner(
      ciphersuite: cs,
      privateKey: bobKp.privateKey(),
      publicKey: bobKp.publicKey(),
    );

    final group = await aliceClient.createGroup(
      config: cfg,
      signerBytes: aliceSigner,
      credentialIdentity: utf8.encode('alice-$label'),
      signerPublicKey: aliceKp.publicKey(),
    );
    final gid = group.groupId;
    r.writeln('   Alice created group: ${hex(gid, max: 16)}');

    // Round-trip: the stored group reports the requested ciphersuite.
    final storedCs = await aliceClient.groupCiphersuite(groupIdBytes: gid);
    if (storedCs != cs) {
      throw StateError('$label: groupCiphersuite mismatch: $storedCs');
    }
    r.writeln('   Ciphersuite round-trip OK');

    final bobKeyPkg = await bobClient.createKeyPackage(
      ciphersuite: cs,
      signerBytes: bobSigner,
      credentialIdentity: utf8.encode('bob-$label'),
      signerPublicKey: bobKp.publicKey(),
    );
    r.writeln('   Bob key package: ${bobKeyPkg.keyPackageBytes.length} bytes');

    final add = await aliceClient.addMembers(
      groupIdBytes: gid,
      signerBytes: aliceSigner,
      keyPackagesBytes: [bobKeyPkg.keyPackageBytes],
    );
    r.writeln(
      '   Alice added Bob — commit: ${add.commit.length}, '
      'welcome: ${add.welcome.length} bytes',
    );

    final join = await bobClient.joinGroupFromWelcome(
      config: cfg,
      welcomeBytes: add.welcome,
      signerBytes: bobSigner,
    );
    if (hex(join.groupId) != hex(gid)) {
      throw StateError('$label: joined group ID mismatch');
    }
    r.writeln('   Bob joined via Welcome');

    final aliceMembers = await aliceClient.groupMembers(groupIdBytes: gid);
    final bobMembers = await bobClient.groupMembers(groupIdBytes: gid);
    if (aliceMembers.length != 2 || bobMembers.length != 2) {
      throw StateError('$label: member count mismatch');
    }
    r.writeln('   Both sides see 2 members');

    final msg = 'Hello, Bob! ($label)';
    final enc = await aliceClient.createMessage(
      groupIdBytes: gid,
      signerBytes: aliceSigner,
      message: utf8.encode(msg),
    );
    final dec = await bobClient.processMessage(
      groupIdBytes: gid,
      messageBytes: enc.ciphertext,
    );
    if (utf8.decode(dec.applicationMessage!) != msg) {
      throw StateError('$label: alice→bob message mismatch');
    }

    final reply = 'Hi Alice! ($label)';
    final replyEnc = await bobClient.createMessage(
      groupIdBytes: gid,
      signerBytes: bobSigner,
      message: utf8.encode(reply),
    );
    final replyDec = await aliceClient.processMessage(
      groupIdBytes: gid,
      messageBytes: replyEnc.ciphertext,
    );
    if (utf8.decode(replyDec.applicationMessage!) != reply) {
      throw StateError('$label: bob→alice message mismatch');
    }
    r.writeln('   Encrypted messages exchanged in both directions');
    r.writeln();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: DemoCard(
        title: 'Post-Quantum',
        description:
            'Full group lifecycle on three experimental post-quantum '
            'ciphersuites — X-Wing (libcrux), ML-KEM-768+X25519 with ML-DSA-44, '
            'and pure ML-KEM-768 — with a classical-suite regression check. '
            'None are IANA-registered — see README limitations.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
