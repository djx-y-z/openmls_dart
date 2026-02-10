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

class GroupsDemoTab extends StatefulWidget {
  const GroupsDemoTab({super.key});

  @override
  State<GroupsDemoTab> createState() => _GroupsDemoTabState();
}

class _GroupsDemoTabState extends State<GroupsDemoTab> {
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
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: aliceKp.publicKey(),
      );
      final gid = group.groupId;
      r.writeln('1. Alice created group');
      r.writeln('   ID: ${hex(gid, max: 32)}');
      r.writeln();

      final bobKeyPkg = await bobClient.createKeyPackage(
        ciphersuite: cs,
        signerBytes: bobSigner,
        credentialIdentity: utf8.encode('bob'),
        signerPublicKey: bobKp.publicKey(),
      );
      r.writeln(
        '2. Bob key package: ${bobKeyPkg.keyPackageBytes.length} bytes',
      );
      r.writeln();

      final add = await aliceClient.addMembers(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        keyPackagesBytes: [bobKeyPkg.keyPackageBytes],
      );
      r.writeln('3. Alice added Bob');
      r.writeln(
        '   Commit: ${add.commit.length}, Welcome: ${add.welcome.length} bytes',
      );
      r.writeln();

      final join = await bobClient.joinGroupFromWelcome(
        config: cfg,
        welcomeBytes: add.welcome,
        signerBytes: bobSigner,
      );
      r.writeln('4. Bob joined');
      r.writeln('   Match: ${hex(gid) == hex(join.groupId)}');
      r.writeln();

      const msg = 'Hello, Bob!';
      final enc = await aliceClient.createMessage(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        message: utf8.encode(msg),
      );
      final dec = await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: enc.ciphertext,
      );
      r.writeln('5. Message: "$msg"');
      r.writeln('   Decrypted: "${utf8.decode(dec.applicationMessage!)}"');
      r.writeln();

      const reply = 'Hi Alice!';
      final replyEnc = await bobClient.createMessage(
        groupIdBytes: gid,
        signerBytes: bobSigner,
        message: utf8.encode(reply),
      );
      final replyDec = await aliceClient.processMessage(
        groupIdBytes: gid,
        messageBytes: replyEnc.ciphertext,
      );
      r.writeln('6. Reply: "${utf8.decode(replyDec.applicationMessage!)}"');
      r.writeln();

      final aadMsg = await aliceClient.createMessage(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        message: utf8.encode('Secret with AAD'),
        aad: Uint8List.fromList(utf8.encode('msg-id:123')),
      );
      final aadDec = await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: aadMsg.ciphertext,
      );
      r.writeln('7. Message with AAD');
      r.writeln('   Decrypted: "${utf8.decode(aadDec.applicationMessage!)}"');
      r.writeln();

      final upd = await aliceClient.selfUpdate(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
      );
      final insp = await bobClient.processMessageWithInspect(
        groupIdBytes: gid,
        messageBytes: upd.commit,
      );
      r.writeln('8. processMessageWithInspect');
      r.writeln('   Type: ${insp.messageType}');
      r.writeln('   Staged commit: ${insp.stagedCommitInfo != null}');

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
        title: 'Group Messaging',
        description:
            'Create group, add member, exchange encrypted messages with '
            'AAD, and inspect processed messages.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
