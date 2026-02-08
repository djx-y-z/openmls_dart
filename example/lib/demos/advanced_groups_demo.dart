import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import '../utils.dart';
import '../widgets/demo_card.dart';

class AdvancedGroupsDemoTab extends StatefulWidget {
  const AdvancedGroupsDemoTab({super.key});

  @override
  State<AdvancedGroupsDemoTab> createState() => _AdvancedGroupsDemoTabState();
}

class _AdvancedGroupsDemoTabState extends State<AdvancedGroupsDemoTab> {
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

      ({MlsClient client, Uint8List signer, Uint8List publicKey}) makeId() {
        final kp = MlsSignatureKeyPair.generate(ciphersuite: cs);
        return (
          client: MlsClient(InMemoryMlsStorage()),
          signer: serializeSigner(
            ciphersuite: cs,
            privateKey: kp.privateKey(),
            publicKey: kp.publicKey(),
          ),
          publicKey: kp.publicKey(),
        );
      }

      // 1. createGroupWithBuilder
      final alice = makeId();
      final builder = await alice.client.createGroupWithBuilder(
        config: cfg,
        signerBytes: alice.signer,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: alice.publicKey,
      );
      r.writeln('1. createGroupWithBuilder');
      r.writeln('   ID: ${hex(builder.groupId, max: 32)}');
      r.writeln();

      // 2. inspectWelcome (temporary group)
      final bob = makeId();
      final inspGid = (await alice.client.createGroup(
        config: cfg,
        signerBytes: alice.signer,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: alice.publicKey,
      )).groupId;
      final bobKpI = await bob.client.createKeyPackage(
        ciphersuite: cs,
        signerBytes: bob.signer,
        credentialIdentity: utf8.encode('bob'),
        signerPublicKey: bob.publicKey,
      );
      final addI = await alice.client.addMembers(
        groupIdBytes: inspGid,
        signerBytes: alice.signer,
        keyPackagesBytes: [bobKpI.keyPackageBytes],
      );
      final wi = await bob.client.inspectWelcome(
        config: cfg,
        welcomeBytes: addI.welcome,
      );
      r.writeln('2. inspectWelcome');
      r.writeln('   ID match: ${hex(wi.groupId) == hex(inspGid)}');
      r.writeln('   Epoch: ${wi.epoch}');
      r.writeln();

      // 3. joinGroupFromWelcomeWithOptions
      final bobKp = await bob.client.createKeyPackage(
        ciphersuite: cs,
        signerBytes: bob.signer,
        credentialIdentity: utf8.encode('bob'),
        signerPublicKey: bob.publicKey,
      );
      final addBob = await alice.client.addMembers(
        groupIdBytes: builder.groupId,
        signerBytes: alice.signer,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      final joinR = await bob.client.joinGroupFromWelcomeWithOptions(
        config: cfg,
        welcomeBytes: addBob.welcome,
        signerBytes: bob.signer,
        skipLifetimeValidation: true,
      );
      r.writeln('3. joinGroupFromWelcomeWithOptions');
      r.writeln('   Skip lifetime: true');
      r.writeln('   Joined: ${hex(joinR.groupId, max: 32)}');
      r.writeln();

      // 4. joinGroupExternalCommit (v1)
      final gid2 = (await alice.client.createGroup(
        config: cfg,
        signerBytes: alice.signer,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: alice.publicKey,
      )).groupId;
      final gi2 = await alice.client.exportGroupInfo(
        groupIdBytes: gid2,
        signerBytes: alice.signer,
      );
      final rt2 = await alice.client.exportRatchetTree(groupIdBytes: gid2);
      final charlie = makeId();
      final ej1 = await charlie.client.joinGroupExternalCommit(
        config: cfg,
        groupInfoBytes: gi2,
        ratchetTreeBytes: rt2,
        signerBytes: charlie.signer,
        credentialIdentity: utf8.encode('charlie'),
        signerPublicKey: charlie.publicKey,
      );
      await alice.client.processMessage(
        groupIdBytes: gid2,
        messageBytes: ej1.commit,
      );
      r.writeln('4. joinGroupExternalCommit');
      r.writeln(
        '   Members: ${(await alice.client.groupMembers(groupIdBytes: gid2)).length}',
      );
      r.writeln();

      // 5. joinGroupExternalCommitV2 (with AAD)
      final gid3 = (await alice.client.createGroup(
        config: cfg,
        signerBytes: alice.signer,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: alice.publicKey,
      )).groupId;
      final gi3 = await alice.client.exportGroupInfo(
        groupIdBytes: gid3,
        signerBytes: alice.signer,
      );
      final rt3 = await alice.client.exportRatchetTree(groupIdBytes: gid3);
      final dave = makeId();
      final ej2 = await dave.client.joinGroupExternalCommitV2(
        config: cfg,
        groupInfoBytes: gi3,
        ratchetTreeBytes: rt3,
        signerBytes: dave.signer,
        credentialIdentity: utf8.encode('dave'),
        signerPublicKey: dave.publicKey,
        aad: Uint8List.fromList(utf8.encode('ext-aad')),
        skipLifetimeValidation: true,
      );
      await alice.client.processMessage(
        groupIdBytes: gid3,
        messageBytes: ej2.commit,
      );
      r.writeln('5. joinGroupExternalCommitV2');
      r.writeln('   Dave joined with AAD');
      r.writeln(
        '   Members: ${(await alice.client.groupMembers(groupIdBytes: gid3)).length}',
      );
      r.writeln();

      // 6. selfUpdateWithNewSigner
      final aliceNew = makeId();
      final updR = await alice.client.selfUpdateWithNewSigner(
        groupIdBytes: builder.groupId,
        oldSignerBytes: alice.signer,
        newSignerBytes: aliceNew.signer,
        newCredentialIdentity: utf8.encode('alice-rotated'),
        newSignerPublicKey: aliceNew.publicKey,
      );
      await bob.client.processMessage(
        groupIdBytes: builder.groupId,
        messageBytes: updR.commit,
      );
      final updCred = await alice.client.groupCredential(
        groupIdBytes: builder.groupId,
      );
      r.writeln('6. selfUpdateWithNewSigner');
      r.writeln('   New identity: "${credName(updCred)}"');
      r.writeln();

      // 7. addMembersWithoutUpdate
      final gid4 = (await alice.client.createGroup(
        config: cfg,
        signerBytes: aliceNew.signer,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: aliceNew.publicKey,
      )).groupId;
      final eve = makeId();
      final eveKp = await eve.client.createKeyPackage(
        ciphersuite: cs,
        signerBytes: eve.signer,
        credentialIdentity: utf8.encode('eve'),
        signerPublicKey: eve.publicKey,
      );
      final addNU = await alice.client.addMembersWithoutUpdate(
        groupIdBytes: gid4,
        signerBytes: aliceNew.signer,
        keyPackagesBytes: [eveKp.keyPackageBytes],
      );
      await alice.client.mergePendingCommit(groupIdBytes: gid4);
      r.writeln('7. addMembersWithoutUpdate');
      r.writeln(
        '   Commit: ${addNU.commit.length}, Welcome: ${addNU.welcome.length} bytes',
      );
      r.writeln();

      // 8. removeMembers
      final frank = makeId();
      final frankKp = await frank.client.createKeyPackage(
        ciphersuite: cs,
        signerBytes: frank.signer,
        credentialIdentity: utf8.encode('frank'),
        signerPublicKey: frank.publicKey,
      );
      await alice.client.addMembers(
        groupIdBytes: gid4,
        signerBytes: aliceNew.signer,
        keyPackagesBytes: [frankKp.keyPackageBytes],
      );
      final fCred = MlsCredential.basic(identity: utf8.encode('frank'));
      final fIdx = await alice.client.groupMemberLeafIndex(
        groupIdBytes: gid4,
        credentialBytes: fCred.serialize(),
      );
      await alice.client.removeMembers(
        groupIdBytes: gid4,
        signerBytes: aliceNew.signer,
        memberIndices: [fIdx!],
      );
      r.writeln('8. removeMembers');
      r.writeln(
        '   Members: ${(await alice.client.groupMembers(groupIdBytes: gid4)).length}',
      );
      r.writeln();

      // 9. swapMembers (Eve -> Grace)
      final eCred = MlsCredential.basic(identity: utf8.encode('eve'));
      final eIdx = await alice.client.groupMemberLeafIndex(
        groupIdBytes: gid4,
        credentialBytes: eCred.serialize(),
      );
      final grace = makeId();
      final graceKp = await grace.client.createKeyPackage(
        ciphersuite: cs,
        signerBytes: grace.signer,
        credentialIdentity: utf8.encode('grace'),
        signerPublicKey: grace.publicKey,
      );
      await alice.client.swapMembers(
        groupIdBytes: gid4,
        signerBytes: aliceNew.signer,
        removeIndices: [eIdx!],
        addKeyPackagesBytes: [graceKp.keyPackageBytes],
      );
      await alice.client.mergePendingCommit(groupIdBytes: gid4);
      final swapM = await alice.client.groupMembers(groupIdBytes: gid4);
      r.writeln('9. swapMembers (Eve -> Grace)');
      r.writeln(
        '   Members: ${swapM.map((m) => credName(m.credential)).join(", ")}',
      );
      r.writeln();

      // 10. leaveGroupViaSelfRemove (plaintext)
      final ptCfg = MlsGroupConfig(
        ciphersuite: cs,
        wireFormatPolicy: MlsWireFormatPolicy.plaintext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      final ptA = makeId();
      final ptB = makeId();
      final ptG = await ptA.client.createGroup(
        config: ptCfg,
        signerBytes: ptA.signer,
        credentialIdentity: utf8.encode('pt-alice'),
        signerPublicKey: ptA.publicKey,
      );
      final ptBKp = await ptB.client.createKeyPackage(
        ciphersuite: cs,
        signerBytes: ptB.signer,
        credentialIdentity: utf8.encode('pt-bob'),
        signerPublicKey: ptB.publicKey,
      );
      final ptAdd = await ptA.client.addMembers(
        groupIdBytes: ptG.groupId,
        signerBytes: ptA.signer,
        keyPackagesBytes: [ptBKp.keyPackageBytes],
      );
      await ptB.client.joinGroupFromWelcome(
        config: ptCfg,
        welcomeBytes: ptAdd.welcome,
        signerBytes: ptB.signer,
      );
      final sr = await ptB.client.leaveGroupViaSelfRemove(
        groupIdBytes: ptG.groupId,
        signerBytes: ptB.signer,
      );
      r.writeln('10. leaveGroupViaSelfRemove');
      r.writeln('   Message: ${sr.message.length} bytes');

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
        title: 'Advanced Groups',
        description:
            'Builder, inspect welcome, welcome options, external commit '
            '(v1/v2), signer rotation, member swap, self-remove.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
