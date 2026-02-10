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

class AdvancedProposalsDemoTab extends StatefulWidget {
  const AdvancedProposalsDemoTab({super.key});

  @override
  State<AdvancedProposalsDemoTab> createState() =>
      _AdvancedProposalsDemoTabState();
}

class _AdvancedProposalsDemoTabState extends State<AdvancedProposalsDemoTab> {
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

      final aliceKp = MlsSignatureKeyPair.generate(ciphersuite: cs);
      final aliceClient = await MlsEngine.create(
        dbPath: ':memory:',
        encryptionKey: _testKey(),
      );
      final aliceSigner = serializeSigner(
        ciphersuite: cs,
        privateKey: aliceKp.privateKey(),
        publicKey: aliceKp.publicKey(),
      );

      final bobKpSig = MlsSignatureKeyPair.generate(ciphersuite: cs);
      final bobClient = await MlsEngine.create(
        dbPath: ':memory:',
        encryptionKey: _testKey(),
      );
      final bobSigner = serializeSigner(
        ciphersuite: cs,
        privateKey: bobKpSig.privateKey(),
        publicKey: bobKpSig.publicKey(),
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
        signerPublicKey: bobKpSig.publicKey(),
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
      r.writeln('Setup: Alice + Bob');
      r.writeln();

      // 1. proposeAdd
      final charlieKpSig = MlsSignatureKeyPair.generate(ciphersuite: cs);
      final charlieClient = await MlsEngine.create(
        dbPath: ':memory:',
        encryptionKey: _testKey(),
      );
      final charlieSigner = serializeSigner(
        ciphersuite: cs,
        privateKey: charlieKpSig.privateKey(),
        publicKey: charlieKpSig.publicKey(),
      );
      final charlieKeyPkg = await charlieClient.createKeyPackage(
        ciphersuite: cs,
        signerBytes: charlieSigner,
        credentialIdentity: utf8.encode('charlie'),
        signerPublicKey: charlieKpSig.publicKey(),
      );
      final addProp = await aliceClient.proposeAdd(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        keyPackageBytes: charlieKeyPkg.keyPackageBytes,
      );
      r.writeln('1. proposeAdd: ${addProp.proposalMessage.length} bytes');
      r.writeln();

      // 2. clearPendingProposals
      await aliceClient.clearPendingProposals(groupIdBytes: gid);
      final hasP = await aliceClient.groupHasPendingProposals(
        groupIdBytes: gid,
      );
      r.writeln('2. clearPendingProposals: pending=$hasP');
      r.writeln();

      // 3. proposeExternalPsk
      final pskP = await aliceClient.proposeExternalPsk(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        pskId: utf8.encode('shared-psk-id'),
        pskNonce: utf8.encode('psk-nonce-value'),
      );
      r.writeln('3. proposeExternalPsk: ${pskP.proposalMessage.length} bytes');
      await aliceClient.clearPendingProposals(groupIdBytes: gid);
      r.writeln();

      // 4. proposeGroupContextExtensions
      final ext = MlsExtension(
        extensionType: 0xFF01,
        data: Uint8List.fromList(utf8.encode('custom-ext')),
      );
      final extP = await aliceClient.proposeGroupContextExtensions(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        extensions: [ext],
      );
      r.writeln(
        '4. proposeGroupContextExtensions: ${extP.proposalMessage.length} bytes',
      );
      await aliceClient.clearPendingProposals(groupIdBytes: gid);
      r.writeln();

      // 5. proposeCustomProposal
      final cusP = await aliceClient.proposeCustomProposal(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        proposalType: 0xF001,
        payload: utf8.encode('custom-payload'),
      );
      r.writeln(
        '5. proposeCustomProposal: ${cusP.proposalMessage.length} bytes',
      );
      await aliceClient.clearPendingProposals(groupIdBytes: gid);
      r.writeln();

      // 6. proposeRemoveMemberByCredential
      final bobCred = MlsCredential.basic(identity: utf8.encode('bob'));
      final rmCP = await aliceClient.proposeRemoveMemberByCredential(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        credentialBytes: bobCred.serialize(),
      );
      r.writeln(
        '6. proposeRemoveMemberByCredential: ${rmCP.proposalMessage.length} bytes',
      );
      await aliceClient.clearPendingProposals(groupIdBytes: gid);
      r.writeln();

      // 7. setConfiguration
      final newCfg = MlsGroupConfig.defaultConfig(ciphersuite: cs);
      await aliceClient.setConfiguration(groupIdBytes: gid, config: newCfg);
      r.writeln(
        '7. setConfiguration: active=${await aliceClient.groupIsActive(groupIdBytes: gid)}',
      );
      r.writeln();

      // 8. updateGroupContextExtensions
      final ueR = await aliceClient.updateGroupContextExtensions(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        extensions: [],
      );
      await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: ueR.commit,
      );
      r.writeln('8. updateGroupContextExtensions: ${ueR.commit.length} bytes');
      r.writeln();

      // 9. clearPendingCommit
      await aliceClient.clearPendingCommit(groupIdBytes: gid);
      r.writeln('9. clearPendingCommit: no error');
      r.writeln();

      // 10. flexibleCommit (add Charlie)
      final charlieKeyPkg2 = await charlieClient.createKeyPackage(
        ciphersuite: cs,
        signerBytes: charlieSigner,
        credentialIdentity: utf8.encode('charlie'),
        signerPublicKey: charlieKpSig.publicKey(),
      );
      final flexR = await aliceClient.flexibleCommit(
        groupIdBytes: gid,
        signerBytes: aliceSigner,
        options: FlexibleCommitOptions(
          addKeyPackages: [charlieKeyPkg2.keyPackageBytes],
          removeIndices: Uint32List(0),
          forceSelfUpdate: false,
          consumePendingProposals: true,
          createGroupInfo: true,
          useRatchetTreeExtension: true,
        ),
      );
      await aliceClient.mergePendingCommit(groupIdBytes: gid);
      await bobClient.processMessage(
        groupIdBytes: gid,
        messageBytes: flexR.commit,
      );
      final flexM = await aliceClient.groupMembers(groupIdBytes: gid);
      r.writeln('10. flexibleCommit (add Charlie)');
      r.writeln(
        '   Members: ${flexM.map((m) => credName(m.credential)).join(", ")}',
      );
      r.writeln();

      // 11. mergePendingCommit
      r.writeln('11. mergePendingCommit: demonstrated in 8, 10');

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
        title: 'Advanced Proposals',
        description:
            'Propose add/PSK/extensions/custom/remove-by-credential, '
            'configuration, flexible commit, merge/clear.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
