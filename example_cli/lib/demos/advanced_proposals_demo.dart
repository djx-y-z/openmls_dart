import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../utils.dart';

Uint8List _testKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}

/// Demonstrates advanced proposal types, commit variants, and group
/// configuration: proposeAdd, proposeExternalPsk, proposeGroupContextExtensions,
/// proposeCustomProposal, proposeRemoveMemberByCredential, flexibleCommit,
/// mergePendingCommit, clearPendingCommit/Proposals, setConfiguration,
/// updateGroupContextExtensions.
Future<void> runAdvancedProposalsDemo() async {
  printHeader('Advanced Proposals Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  // Setup: Alice + Bob
  final aliceKp = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final aliceClient = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: _testKey(),
  );
  final aliceSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: aliceKp.privateKey(),
    publicKey: aliceKp.publicKey(),
  );

  final bobKp = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final bobClient = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: _testKey(),
  );
  final bobSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: bobKp.privateKey(),
    publicKey: bobKp.publicKey(),
  );

  final group = await aliceClient.createGroup(
    config: config,
    signerBytes: aliceSigner,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: aliceKp.publicKey(),
  );
  final groupId = group.groupId;

  final bobKeyPkg = await bobClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: bobSigner,
    credentialIdentity: utf8.encode('bob'),
    signerPublicKey: bobKp.publicKey(),
  );
  final addBob = await aliceClient.addMembers(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    keyPackagesBytes: [bobKeyPkg.keyPackageBytes],
  );
  await bobClient.joinGroupFromWelcome(
    config: config,
    welcomeBytes: addBob.welcome,
    signerBytes: bobSigner,
  );

  printStep(0, 'Setup complete: Alice + Bob in group');
  print('');

  // 1. proposeAdd — propose adding Charlie
  final charlieKp = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final charlieClient = await MlsEngine.create(
    dbPath: ':memory:',
    encryptionKey: _testKey(),
  );
  final charlieSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: charlieKp.privateKey(),
    publicKey: charlieKp.publicKey(),
  );
  final charlieKeyPkg = await charlieClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: charlieSigner,
    credentialIdentity: utf8.encode('charlie'),
    signerPublicKey: charlieKp.publicKey(),
  );
  final addProposal = await aliceClient.proposeAdd(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    keyPackageBytes: charlieKeyPkg.keyPackageBytes,
  );
  printStep(1, 'proposeAdd (propose adding Charlie)', [
    'Proposal size: ${addProposal.proposalMessage.length} bytes',
  ]);
  print('');

  // 2. clearPendingProposals
  await aliceClient.clearPendingProposals(groupIdBytes: groupId);
  final hasPending = await aliceClient.groupHasPendingProposals(
    groupIdBytes: groupId,
  );
  printStep(2, 'clearPendingProposals', [
    'Pending proposals after clear: $hasPending',
  ]);
  print('');

  // 3. proposeExternalPsk
  final pskProposal = await aliceClient.proposeExternalPsk(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    pskId: utf8.encode('shared-psk-id'),
    pskNonce: utf8.encode('psk-nonce-value'),
  );
  printStep(3, 'proposeExternalPsk', [
    'PSK ID: "shared-psk-id"',
    'Proposal size: ${pskProposal.proposalMessage.length} bytes',
  ]);
  await aliceClient.clearPendingProposals(groupIdBytes: groupId);
  print('');

  // 4. proposeGroupContextExtensions
  final ext = MlsExtension(
    extensionType: 0xFF01, // private-use range
    data: Uint8List.fromList(utf8.encode('custom-ext-data')),
  );
  final extProposal = await aliceClient.proposeGroupContextExtensions(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    extensions: [ext],
  );
  printStep(4, 'proposeGroupContextExtensions', [
    'Extension type: 0xFF01',
    'Proposal size: ${extProposal.proposalMessage.length} bytes',
  ]);
  await aliceClient.clearPendingProposals(groupIdBytes: groupId);
  print('');

  // 5. proposeCustomProposal
  final customProposal = await aliceClient.proposeCustomProposal(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    proposalType: 0xF001, // private-use range
    payload: utf8.encode('custom-payload'),
  );
  printStep(5, 'proposeCustomProposal', [
    'Type: 0xF001 (private-use)',
    'Proposal size: ${customProposal.proposalMessage.length} bytes',
  ]);
  await aliceClient.clearPendingProposals(groupIdBytes: groupId);
  print('');

  // 6. proposeRemoveMemberByCredential
  final bobCred = MlsCredential.basic(identity: utf8.encode('bob'));
  final removeByCredProposal = await aliceClient
      .proposeRemoveMemberByCredential(
        groupIdBytes: groupId,
        signerBytes: aliceSigner,
        credentialBytes: bobCred.serialize(),
      );
  printStep(6, 'proposeRemoveMemberByCredential', [
    'Target: "bob"',
    'Proposal size: ${removeByCredProposal.proposalMessage.length} bytes',
  ]);
  await aliceClient.clearPendingProposals(groupIdBytes: groupId);
  print('');

  // 7. setConfiguration
  final newConfig = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);
  await aliceClient.setConfiguration(groupIdBytes: groupId, config: newConfig);
  final stillActive = await aliceClient.groupIsActive(groupIdBytes: groupId);
  printStep(7, 'setConfiguration', [
    'Applied new config',
    'Group still active: $stillActive',
  ]);
  print('');

  // 8. updateGroupContextExtensions (creates a commit)
  final updateExtResult = await aliceClient.updateGroupContextExtensions(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    extensions: [], // clear extensions
  );
  await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: updateExtResult.commit,
  );
  printStep(8, 'updateGroupContextExtensions', [
    'Cleared all group context extensions',
    'Commit size: ${updateExtResult.commit.length} bytes',
  ]);
  print('');

  // 9. clearPendingCommit (should not error even when nothing pending)
  await aliceClient.clearPendingCommit(groupIdBytes: groupId);
  printStep(9, 'clearPendingCommit', ['No error (no pending commit to clear)']);
  print('');

  // 10. flexibleCommit — add Charlie via flexible commit
  final charlieKeyPkg2 = await charlieClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: charlieSigner,
    credentialIdentity: utf8.encode('charlie'),
    signerPublicKey: charlieKp.publicKey(),
  );
  final flexOptions = FlexibleCommitOptions(
    addKeyPackages: [charlieKeyPkg2.keyPackageBytes],
    removeIndices: Uint32List(0),
    forceSelfUpdate: false,
    consumePendingProposals: true,
    createGroupInfo: true,
    useRatchetTreeExtension: true,
  );
  final flexResult = await aliceClient.flexibleCommit(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    options: flexOptions,
  );
  await aliceClient.mergePendingCommit(groupIdBytes: groupId);
  await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: flexResult.commit,
  );
  final membersAfterFlex = await aliceClient.groupMembers(
    groupIdBytes: groupId,
  );
  printStep(10, 'flexibleCommit (add Charlie)', [
    'Commit size: ${flexResult.commit.length} bytes',
    'Welcome: ${flexResult.welcome?.length ?? 0} bytes',
    'Group info: ${flexResult.groupInfo?.length ?? 0} bytes',
    'Members: ${membersAfterFlex.map((m) => credentialName(m.credential)).join(", ")}',
  ]);
  print('');

  // 11. mergePendingCommit — demonstrated above (steps 8, 10)
  printStep(11, 'mergePendingCommit', [
    'Already demonstrated in steps 8 and 10',
  ]);

  // No dispose() needed - FRB handles memory automatically
}
