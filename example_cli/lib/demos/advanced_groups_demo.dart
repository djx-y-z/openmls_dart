import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../utils.dart';

Uint8List _testKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}

/// Demonstrates advanced group operations: builder, external commit,
/// welcome options, member mutations, and self-remove.
Future<void> runAdvancedGroupsDemo() async {
  printHeader('Advanced Groups Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  // Shared identity helper
  Future<({MlsEngine client, Uint8List signer, Uint8List publicKey})>
  makeIdentity(String name) async {
    final kp = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
    return (
      client: await MlsEngine.create(
        dbPath: ':memory:',
        encryptionKey: _testKey(),
      ),
      signer: serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: kp.privateKey(),
        publicKey: kp.publicKey(),
      ),
      publicKey: kp.publicKey(),
    );
  }

  // 1. createGroupWithBuilder
  final alice = await makeIdentity('alice');
  final builderResult = await alice.client.createGroupWithBuilder(
    config: config,
    signerBytes: alice.signer,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: alice.publicKey,
  );
  printStep(1, 'createGroupWithBuilder', [
    'Group ID: ${bytesToHex(builderResult.groupId, maxLength: 32)}',
  ]);
  print('');

  // 2. inspectWelcome — inspect before joining
  // Use a temporary group because inspectWelcome consumes the key package
  final bob = await makeIdentity('bob');
  final inspectGroupId = (await alice.client.createGroup(
    config: config,
    signerBytes: alice.signer,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: alice.publicKey,
  )).groupId;
  final bobKpInspect = await bob.client.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: bob.signer,
    credentialIdentity: utf8.encode('bob'),
    signerPublicKey: bob.publicKey,
  );
  final addBobInspect = await alice.client.addMembers(
    groupIdBytes: inspectGroupId,
    signerBytes: alice.signer,
    keyPackagesBytes: [bobKpInspect.keyPackageBytes],
  );
  final welcomeInfo = await bob.client.inspectWelcome(
    config: config,
    welcomeBytes: addBobInspect.welcome,
  );
  printStep(2, 'inspectWelcome (before joining)', [
    'Group ID matches: ${bytesToHex(welcomeInfo.groupId) == bytesToHex(inspectGroupId)}',
    'Ciphersuite: ${welcomeInfo.ciphersuite}',
    'Epoch: ${welcomeInfo.epoch}',
  ]);
  print('');

  // 3. joinGroupFromWelcomeWithOptions (skip lifetime validation)
  final bobKp = await bob.client.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: bob.signer,
    credentialIdentity: utf8.encode('bob'),
    signerPublicKey: bob.publicKey,
  );
  final addBob = await alice.client.addMembers(
    groupIdBytes: builderResult.groupId,
    signerBytes: alice.signer,
    keyPackagesBytes: [bobKp.keyPackageBytes],
  );
  final joinResult = await bob.client.joinGroupFromWelcomeWithOptions(
    config: config,
    welcomeBytes: addBob.welcome,
    signerBytes: bob.signer,
    skipLifetimeValidation: true,
  );
  printStep(3, 'joinGroupFromWelcomeWithOptions', [
    'Skip lifetime validation: true',
    'Joined group: ${bytesToHex(joinResult.groupId, maxLength: 32)}',
  ]);
  print('');

  // 4. joinGroupExternalCommit (v1)
  final groupId2 = (await alice.client.createGroup(
    config: config,
    signerBytes: alice.signer,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: alice.publicKey,
  )).groupId;
  final groupInfo = await alice.client.exportGroupInfo(
    groupIdBytes: groupId2,
    signerBytes: alice.signer,
  );
  final ratchetTree = await alice.client.exportRatchetTree(
    groupIdBytes: groupId2,
  );
  final charlie = await makeIdentity('charlie');
  final extJoin = await charlie.client.joinGroupExternalCommit(
    config: config,
    groupInfoBytes: groupInfo,
    ratchetTreeBytes: ratchetTree,
    signerBytes: charlie.signer,
    credentialIdentity: utf8.encode('charlie'),
    signerPublicKey: charlie.publicKey,
  );
  await alice.client.processMessage(
    groupIdBytes: groupId2,
    messageBytes: extJoin.commit,
  );
  printStep(4, 'joinGroupExternalCommit (v1)', [
    'Charlie joined via external commit',
    'Commit size: ${extJoin.commit.length} bytes',
    'Members: ${(await alice.client.groupMembers(groupIdBytes: groupId2)).length}',
  ]);
  print('');

  // 5. joinGroupExternalCommitV2 (with AAD)
  final groupId3 = (await alice.client.createGroup(
    config: config,
    signerBytes: alice.signer,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: alice.publicKey,
  )).groupId;
  final gi3 = await alice.client.exportGroupInfo(
    groupIdBytes: groupId3,
    signerBytes: alice.signer,
  );
  final rt3 = await alice.client.exportRatchetTree(groupIdBytes: groupId3);
  final dave = await makeIdentity('dave');
  final extJoin2 = await dave.client.joinGroupExternalCommitV2(
    config: config,
    groupInfoBytes: gi3,
    ratchetTreeBytes: rt3,
    signerBytes: dave.signer,
    credentialIdentity: utf8.encode('dave'),
    signerPublicKey: dave.publicKey,
    aad: Uint8List.fromList(utf8.encode('external-aad')),
    skipLifetimeValidation: true,
  );
  await alice.client.processMessage(
    groupIdBytes: groupId3,
    messageBytes: extJoin2.commit,
  );
  printStep(5, 'joinGroupExternalCommitV2 (with AAD)', [
    'Dave joined with AAD: "external-aad"',
    'Members: ${(await alice.client.groupMembers(groupIdBytes: groupId3)).length}',
  ]);
  print('');

  // 6. selfUpdateWithNewSigner
  final aliceNew = await makeIdentity('alice-rotated');
  final updateResult = await alice.client.selfUpdateWithNewSigner(
    groupIdBytes: builderResult.groupId,
    oldSignerBytes: alice.signer,
    newSignerBytes: aliceNew.signer,
    newCredentialIdentity: utf8.encode('alice-rotated'),
    newSignerPublicKey: aliceNew.publicKey,
  );
  await bob.client.processMessage(
    groupIdBytes: builderResult.groupId,
    messageBytes: updateResult.commit,
  );
  final updatedCred = await alice.client.groupCredential(
    groupIdBytes: builderResult.groupId,
  );
  printStep(6, 'selfUpdateWithNewSigner', [
    'New identity: "${credentialName(updatedCred)}"',
    'Commit size: ${updateResult.commit.length} bytes',
  ]);
  print('');

  // 7. addMembersWithoutUpdate
  final groupId4 = (await alice.client.createGroup(
    config: config,
    signerBytes: aliceNew.signer,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: aliceNew.publicKey,
  )).groupId;
  final eve = await makeIdentity('eve');
  final eveKp = await eve.client.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: eve.signer,
    credentialIdentity: utf8.encode('eve'),
    signerPublicKey: eve.publicKey,
  );
  final addNoUpdate = await alice.client.addMembersWithoutUpdate(
    groupIdBytes: groupId4,
    signerBytes: aliceNew.signer,
    keyPackagesBytes: [eveKp.keyPackageBytes],
  );
  await alice.client.mergePendingCommit(groupIdBytes: groupId4);
  printStep(7, 'addMembersWithoutUpdate', [
    'Added Eve without self-update',
    'Commit size: ${addNoUpdate.commit.length} bytes',
    'Welcome size: ${addNoUpdate.welcome.length} bytes',
  ]);
  print('');

  // 8. removeMembers
  final frank = await makeIdentity('frank');
  final frankKp = await frank.client.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: frank.signer,
    credentialIdentity: utf8.encode('frank'),
    signerPublicKey: frank.publicKey,
  );
  await alice.client.addMembers(
    groupIdBytes: groupId4,
    signerBytes: aliceNew.signer,
    keyPackagesBytes: [frankKp.keyPackageBytes],
  );
  // addMembers auto-merges the pending commit
  final frankCred = MlsCredential.basic(identity: utf8.encode('frank'));
  final frankIdx = await alice.client.groupMemberLeafIndex(
    groupIdBytes: groupId4,
    credentialBytes: frankCred.serialize(),
  );
  final removeResult = await alice.client.removeMembers(
    groupIdBytes: groupId4,
    signerBytes: aliceNew.signer,
    memberIndices: [frankIdx!],
  );
  // removeMembers auto-merges the pending commit
  printStep(8, 'removeMembers', [
    'Removed Frank (index $frankIdx)',
    'Commit size: ${removeResult.commit.length} bytes',
    'Members after: ${(await alice.client.groupMembers(groupIdBytes: groupId4)).length}',
  ]);
  print('');

  // 9. swapMembers (replace Eve with Grace)
  final eveCred = MlsCredential.basic(identity: utf8.encode('eve'));
  final eveIdx = await alice.client.groupMemberLeafIndex(
    groupIdBytes: groupId4,
    credentialBytes: eveCred.serialize(),
  );
  final grace = await makeIdentity('grace');
  final graceKp = await grace.client.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: grace.signer,
    credentialIdentity: utf8.encode('grace'),
    signerPublicKey: grace.publicKey,
  );
  final swapResult = await alice.client.swapMembers(
    groupIdBytes: groupId4,
    signerBytes: aliceNew.signer,
    removeIndices: [eveIdx!],
    addKeyPackagesBytes: [graceKp.keyPackageBytes],
  );
  await alice.client.mergePendingCommit(groupIdBytes: groupId4);
  final swapMembers = await alice.client.groupMembers(groupIdBytes: groupId4);
  final swapNames = swapMembers
      .map((m) => credentialName(m.credential))
      .toList();
  printStep(9, 'swapMembers (Eve -> Grace)', [
    'Commit size: ${swapResult.commit.length} bytes',
    'Welcome size: ${swapResult.welcome.length} bytes',
    'Members: ${swapNames.join(", ")}',
  ]);
  print('');

  // 10. leaveGroupViaSelfRemove (requires plaintext wire format)
  final ptConfig = MlsGroupConfig(
    ciphersuite: ciphersuite,
    wireFormatPolicy: MlsWireFormatPolicy.plaintext,
    useRatchetTreeExtension: true,
    maxPastEpochs: 0,
    paddingSize: 0,
    senderRatchetMaxOutOfOrder: 10,
    senderRatchetMaxForwardDistance: 1000,
    numberOfResumptionPsks: 0,
  );
  final ptAlice = await makeIdentity('pt-alice');
  final ptBob = await makeIdentity('pt-bob');
  final ptGroup = await ptAlice.client.createGroup(
    config: ptConfig,
    signerBytes: ptAlice.signer,
    credentialIdentity: utf8.encode('pt-alice'),
    signerPublicKey: ptAlice.publicKey,
  );
  final ptBobKp = await ptBob.client.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: ptBob.signer,
    credentialIdentity: utf8.encode('pt-bob'),
    signerPublicKey: ptBob.publicKey,
  );
  final ptAdd = await ptAlice.client.addMembers(
    groupIdBytes: ptGroup.groupId,
    signerBytes: ptAlice.signer,
    keyPackagesBytes: [ptBobKp.keyPackageBytes],
  );
  await ptAlice.client.mergePendingCommit(groupIdBytes: ptGroup.groupId);
  await ptBob.client.joinGroupFromWelcome(
    config: ptConfig,
    welcomeBytes: ptAdd.welcome,
    signerBytes: ptBob.signer,
  );
  final selfRemove = await ptBob.client.leaveGroupViaSelfRemove(
    groupIdBytes: ptGroup.groupId,
    signerBytes: ptBob.signer,
  );
  printStep(10, 'leaveGroupViaSelfRemove', [
    'Bob self-removed from plaintext group',
    'Message size: ${selfRemove.message.length} bytes',
  ]);

  // No dispose() needed - FRB handles memory automatically
}
