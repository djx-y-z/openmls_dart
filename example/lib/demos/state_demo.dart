import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import '../utils.dart';
import '../widgets/demo_card.dart';

class StateDemoTab extends StatefulWidget {
  const StateDemoTab({super.key});

  @override
  State<StateDemoTab> createState() => _StateDemoTabState();
}

class _StateDemoTabState extends State<StateDemoTab> {
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

      final aliceClient = MlsClient(InMemoryMlsStorage());
      final aliceKp = MlsSignatureKeyPair.generate(ciphersuite: cs);
      final aliceSigner = serializeSigner(
        ciphersuite: cs,
        privateKey: aliceKp.privateKey(),
        publicKey: aliceKp.publicKey(),
      );

      final bobClient = MlsClient(InMemoryMlsStorage());
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
      final bobKeyPkg = await bobClient.createKeyPackage(
        ciphersuite: cs,
        signerBytes: bobSigner,
        credentialIdentity: utf8.encode('bob'),
        signerPublicKey: bobKp.publicKey(),
      );
      final addR = await aliceClient.addMembers(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        keyPackagesBytes: [bobKeyPkg.keyPackageBytes],
      );
      await bobClient.joinGroupFromWelcome(
        config: cfg,
        welcomeBytes: addR.welcome,
        signerBytes: bobSigner,
      );
      r.writeln('Setup: Alice + Bob');
      r.writeln();

      r.writeln('1. Epoch: ${await aliceClient.groupEpoch(groupIdBytes: gid)}');
      r.writeln();

      final members = await aliceClient.groupMembers(groupIdBytes: gid);
      r.writeln('2. Members (${members.length}):');
      for (final m in members) {
        r.writeln('   [${m.index}] "${credName(m.credential)}"');
      }
      r.writeln();

      final ownIdx = await aliceClient.groupOwnIndex(groupIdBytes: gid);
      final ownCred = await aliceClient.groupCredential(groupIdBytes: gid);
      r.writeln('3. Own: index=$ownIdx, "${credName(ownCred)}"');
      r.writeln();

      final active = await aliceClient.groupIsActive(groupIdBytes: gid);
      final suite = await aliceClient.groupCiphersuite(groupIdBytes: gid);
      r.writeln('4. Active: $active, Suite: $suite');
      r.writeln();

      final leaf = await aliceClient.groupOwnLeafNode(groupIdBytes: gid);
      r.writeln('5. Own leaf node');
      r.writeln('   Identity: "${credName(leaf.credential)}"');
      r.writeln('   Sig key: ${hex(leaf.signatureKey, max: 16)}');
      r.writeln();

      final ctx = await aliceClient.exportGroupContext(groupIdBytes: gid);
      r.writeln('6. Group context');
      r.writeln('   Epoch: ${ctx.epoch}, Suite: ${ctx.ciphersuite}');
      r.writeln('   Tree hash: ${hex(ctx.treeHash, max: 24)}');
      r.writeln();

      final secret = await aliceClient.exportSecret(
        groupIdBytes: gid,
        label: 'demo',
        context: utf8.encode('example'),
        keyLength: 32,
      );
      r.writeln('7. Exported secret: ${secret.length} bytes');
      r.writeln();

      final tag = await aliceClient.groupConfirmationTag(groupIdBytes: gid);
      r.writeln('8. Confirmation tag: ${tag.length} bytes');
      r.writeln();

      final bobCred = MlsCredential.basic(identity: utf8.encode('bob'));
      final bobIdx = await aliceClient.groupMemberLeafIndex(
        groupIdBytes: gid,
        credentialBytes: bobCred.serialize(),
      );
      final bobMem = await aliceClient.groupMemberAt(
        groupIdBytes: gid,
        leafIndex: bobIdx!,
      );
      r.writeln(
        '9. Bob lookup: index=$bobIdx, "${credName(bobMem!.credential)}"',
      );
      r.writeln();

      final qid = await aliceClient.groupId(groupIdBytes: gid);
      r.writeln('10. groupId() match: ${hex(qid) == hex(gid)}');
      r.writeln();

      final ext = await aliceClient.groupExtensions(groupIdBytes: gid);
      r.writeln('11. Extensions: ${ext.length} bytes');
      r.writeln();

      final rt = await aliceClient.exportRatchetTree(groupIdBytes: gid);
      r.writeln('12. Ratchet tree: ${rt.length} bytes');
      r.writeln();

      final gi = await aliceClient.exportGroupInfo(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
      );
      r.writeln('13. Group info: ${gi.length} bytes');
      r.writeln();

      final psk = await aliceClient.getPastResumptionPsk(
        groupIdBytes: gid,
        epoch: BigInt.zero,
      );
      r.writeln('14. PSK (epoch 0): ${psk!.length} bytes');

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
        title: 'Group State Queries',
        description:
            'Members, epoch, leaf node, group context, exports, '
            'confirmation tag, member lookup, PSK.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
