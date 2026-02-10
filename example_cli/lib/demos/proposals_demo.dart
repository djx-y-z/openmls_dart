import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../utils.dart';

Uint8List _testKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}

/// Demonstrates proposals, commits, self-update, and member removal.
Future<void> runProposalsDemo() async {
  printHeader('Proposals Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  // Setup: Alice + Bob + Charlie
  final aliceClient = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: _testKey(),
  );
  final aliceKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final aliceSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: aliceKeyPair.privateKey(),
    publicKey: aliceKeyPair.publicKey(),
  );

  final bobClient = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: _testKey(),
  );
  final bobKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final bobSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: bobKeyPair.privateKey(),
    publicKey: bobKeyPair.publicKey(),
  );

  final charlieClient = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: _testKey(),
  );
  final charlieKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final charlieSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: charlieKeyPair.privateKey(),
    publicKey: charlieKeyPair.publicKey(),
  );

  // Alice creates group
  final group = await aliceClient.createGroup(
    config: config,
    signerBytes: aliceSigner,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: aliceKeyPair.publicKey(),
  );
  final groupId = group.groupId;

  // Add Bob
  final bobKp = await bobClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: bobSigner,
    credentialIdentity: utf8.encode('bob'),
    signerPublicKey: bobKeyPair.publicKey(),
  );
  final addBob = await aliceClient.addMembers(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    keyPackagesBytes: [bobKp.keyPackageBytes],
  );
  await bobClient.joinGroupFromWelcome(
    config: config,
    welcomeBytes: addBob.welcome,
    signerBytes: bobSigner,
  );

  // Add Charlie
  final charlieKp = await charlieClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: charlieSigner,
    credentialIdentity: utf8.encode('charlie'),
    signerPublicKey: charlieKeyPair.publicKey(),
  );
  final addCharlie = await aliceClient.addMembers(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    keyPackagesBytes: [charlieKp.keyPackageBytes],
  );
  // Bob processes Alice's add-Charlie commit
  await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: addCharlie.commit,
  );
  await charlieClient.joinGroupFromWelcome(
    config: config,
    welcomeBytes: addCharlie.welcome,
    signerBytes: charlieSigner,
  );

  printStep(0, 'Setup complete: Alice + Bob + Charlie in group');
  print('');

  // 1. Self-update (Alice rotates her keys)
  final epochBefore = await aliceClient.groupEpoch(groupIdBytes: groupId);
  final updateResult = await aliceClient.selfUpdate(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
  );
  final epochAfter = await aliceClient.groupEpoch(groupIdBytes: groupId);
  printStep(1, 'Alice self-updated', [
    'Epoch: $epochBefore -> $epochAfter',
    'Commit size: ${updateResult.commit.length} bytes',
  ]);
  // Bob and Charlie process the self-update commit
  await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: updateResult.commit,
  );
  await charlieClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: updateResult.commit,
  );
  print('');

  // 2. Propose + commit flow
  // Bob proposes to remove Charlie
  final charlieCred = MlsCredential.basic(identity: utf8.encode('charlie'));
  final charlieIndex = await aliceClient.groupMemberLeafIndex(
    groupIdBytes: groupId,
    credentialBytes: charlieCred.serialize(),
  );
  final removeProposal = await bobClient.proposeRemove(
    groupIdBytes: groupId,
    signerBytes: bobSigner,
    memberIndex: charlieIndex!,
  );
  printStep(2, 'Bob proposed removing Charlie', [
    'Proposal size: ${removeProposal.proposalMessage.length} bytes',
  ]);
  // Alice and Charlie process the proposal
  await aliceClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: removeProposal.proposalMessage,
  );
  await charlieClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: removeProposal.proposalMessage,
  );
  print('');

  // 3. Check pending proposals
  final pending = await aliceClient.groupPendingProposals(
    groupIdBytes: groupId,
  );
  final hasPending = await aliceClient.groupHasPendingProposals(
    groupIdBytes: groupId,
  );
  printStep(3, 'Pending proposals on Alice', [
    'Has pending: $hasPending',
    'Count: ${pending.length}',
    for (final p in pending) '- ${p.proposalType} (sender: ${p.senderIndex})',
  ]);
  print('');

  // 4. Alice commits the pending proposal
  final commitResult = await aliceClient.commitToPendingProposals(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
  );
  printStep(4, 'Alice committed pending proposals', [
    'Commit size: ${commitResult.commit.length} bytes',
  ]);
  // Bob processes the commit
  await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: commitResult.commit,
  );
  print('');

  // 5. Verify Charlie removed
  final membersAfter = await aliceClient.groupMembers(groupIdBytes: groupId);
  printStep(5, 'Members after removal (${membersAfter.length})', [
    for (final m in membersAfter)
      'Index ${m.index}: "${credentialName(m.credential)}"',
  ]);
  print('');

  // 6. Message utility functions
  final msg = await aliceClient.createMessage(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    message: utf8.encode('test'),
  );
  final extractedGroupId = mlsMessageExtractGroupId(
    messageBytes: msg.ciphertext,
  );
  final extractedEpoch = mlsMessageExtractEpoch(messageBytes: msg.ciphertext);
  final contentType = mlsMessageContentType(messageBytes: msg.ciphertext);
  printStep(6, 'Message utility functions', [
    'Extracted group ID matches: ${bytesToHex(extractedGroupId) == bytesToHex(groupId)}',
    'Extracted epoch: $extractedEpoch',
    'Content type: $contentType',
  ]);
  print('');

  // 7. Alice leaves the group
  final leaveResult = await aliceClient.leaveGroup(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
  );
  printStep(7, 'Alice left the group', [
    'Leave message size: ${leaveResult.message.length} bytes',
  ]);
  // Bob processes the leave
  await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: leaveResult.message,
  );
  final finalMembers = await bobClient.groupMembers(groupIdBytes: groupId);
  printStep(7, 'Final members (${finalMembers.length})', [
    for (final m in finalMembers)
      'Index ${m.index}: "${credentialName(m.credential)}"',
  ]);

  // No dispose() needed - FRB handles memory automatically
}
