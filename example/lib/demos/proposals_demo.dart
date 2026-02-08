import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import '../utils.dart';
import '../widgets/demo_card.dart';

class ProposalsDemoTab extends StatefulWidget {
  const ProposalsDemoTab({super.key});

  @override
  State<ProposalsDemoTab> createState() => _ProposalsDemoTabState();
}

class _ProposalsDemoTabState extends State<ProposalsDemoTab> {
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

      final charlieClient = MlsClient(InMemoryMlsStorage());
      final charlieKp = MlsSignatureKeyPair.generate(ciphersuite: cs);
      final charlieSigner = serializeSigner(
        ciphersuite: cs,
        privateKey: charlieKp.privateKey(),
        publicKey: charlieKp.publicKey(),
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
      final addBob = await aliceClient.addMembers(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        keyPackagesBytes: [bobKeyPkg.keyPackageBytes],
      );
      await bobClient.joinGroupFromWelcome(
        config: cfg,
        welcomeBytes: addBob.welcome,
        signerBytes: bobSigner,
      );

      final charlieKeyPkg = await charlieClient.createKeyPackage(
        ciphersuite: cs,
        signerBytes: charlieSigner,
        credentialIdentity: utf8.encode('charlie'),
        signerPublicKey: charlieKp.publicKey(),
      );
      final addCharlie = await aliceClient.addMembers(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        keyPackagesBytes: [charlieKeyPkg.keyPackageBytes],
      );
      await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: addCharlie.commit,
      );
      await charlieClient.joinGroupFromWelcome(
        config: cfg,
        welcomeBytes: addCharlie.welcome,
        signerBytes: charlieSigner,
      );
      r.writeln('Setup: Alice + Bob + Charlie');
      r.writeln();

      final eBefore = await aliceClient.groupEpoch(groupIdBytes: gid);
      final upd = await aliceClient.selfUpdate(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
      );
      final eAfter = await aliceClient.groupEpoch(groupIdBytes: gid);
      r.writeln('1. Self-update: epoch $eBefore -> $eAfter');
      await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: upd.commit,
      );
      await charlieClient.processMessage(
        groupIdBytes: gid,
        messageBytes: upd.commit,
      );
      r.writeln();

      final cCred = MlsCredential.basic(identity: utf8.encode('charlie'));
      final cIdx = await aliceClient.groupMemberLeafIndex(
        groupIdBytes: gid,
        credentialBytes: cCred.serialize(),
      );
      final rmProp = await bobClient.proposeRemove(
        groupIdBytes: gid,
        signerBytes: bobSigner,
        memberIndex: cIdx!,
      );
      r.writeln('2. Bob proposed removing Charlie');
      await aliceClient.processMessage(
        groupIdBytes: gid,
        messageBytes: rmProp.proposalMessage,
      );
      await charlieClient.processMessage(
        groupIdBytes: gid,
        messageBytes: rmProp.proposalMessage,
      );
      r.writeln();

      final pending = await aliceClient.groupPendingProposals(
        groupIdBytes: gid,
      );
      final hasP = await aliceClient.groupHasPendingProposals(
        groupIdBytes: gid,
      );
      r.writeln('3. Pending: $hasP, count: ${pending.length}');
      for (final p in pending) {
        r.writeln('   - ${p.proposalType} (sender: ${p.senderIndex})');
      }
      r.writeln();

      final commit = await aliceClient.commitToPendingProposals(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
      );
      r.writeln('4. Alice committed: ${commit.commit.length} bytes');
      await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: commit.commit,
      );
      r.writeln();

      final mAfter = await aliceClient.groupMembers(groupIdBytes: gid);
      r.writeln('5. Members (${mAfter.length}):');
      for (final m in mAfter) {
        r.writeln('   [${m.index}] "${credName(m.credential)}"');
      }
      r.writeln();

      final testMsg = await aliceClient.createMessage(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        message: utf8.encode('test'),
      );
      r.writeln('6. Message utilities');
      r.writeln(
        '   Group ID match: ${hex(mlsMessageExtractGroupId(messageBytes: testMsg.ciphertext)) == hex(gid)}',
      );
      r.writeln(
        '   Epoch: ${mlsMessageExtractEpoch(messageBytes: testMsg.ciphertext)}',
      );
      r.writeln(
        '   Content: ${mlsMessageContentType(messageBytes: testMsg.ciphertext)}',
      );
      r.writeln();

      final leave = await aliceClient.leaveGroup(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
      );
      await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: leave.message,
      );
      final fin = await bobClient.groupMembers(groupIdBytes: gid);
      r.writeln('7. Alice left, final members: ${fin.length}');

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
        title: 'Proposals & Commits',
        description:
            'Self-update, propose/commit removal, pending proposals, '
            'message utilities, leave group.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
