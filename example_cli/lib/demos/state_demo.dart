import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../utils.dart';

Uint8List _testKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}

/// Demonstrates group state queries: members, epoch, extensions, exports.
Future<void> runStateDemo() async {
  printHeader('State Queries Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  // Setup: Alice creates group, adds Bob
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

  final group = await aliceClient.createGroup(
    config: config,
    signerBytes: aliceSigner,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: aliceKeyPair.publicKey(),
  );
  final groupId = group.groupId;

  final bobKp = await bobClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: bobSigner,
    credentialIdentity: utf8.encode('bob'),
    signerPublicKey: bobKeyPair.publicKey(),
  );
  final addResult = await aliceClient.addMembers(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    keyPackagesBytes: [bobKp.keyPackageBytes],
  );
  await bobClient.joinGroupFromWelcome(
    config: config,
    welcomeBytes: addResult.welcome,
    signerBytes: bobSigner,
  );

  printStep(0, 'Setup complete: Alice + Bob in group');
  print('');

  // 1. Group epoch
  final epoch = await aliceClient.groupEpoch(groupIdBytes: groupId);
  printStep(1, 'Group epoch', ['Epoch: $epoch']);
  print('');

  // 2. Group members
  final members = await aliceClient.groupMembers(groupIdBytes: groupId);
  printStep(2, 'Group members (${members.length})', [
    for (final m in members)
      'Index ${m.index}: "${credentialName(m.credential)}" '
          '(key: ${bytesToHex(m.signatureKey, maxLength: 16)})',
  ]);
  print('');

  // 3. Own index and credential
  final ownIndex = await aliceClient.groupOwnIndex(groupIdBytes: groupId);
  final ownCred = await aliceClient.groupCredential(groupIdBytes: groupId);
  printStep(3, 'Own identity', [
    'Leaf index: $ownIndex',
    'Credential identity: "${credentialName(ownCred)}"',
  ]);
  print('');

  // 4. Group is active
  final isActive = await aliceClient.groupIsActive(groupIdBytes: groupId);
  printStep(4, 'Group active', ['Active: $isActive']);
  print('');

  // 5. Ciphersuite
  final suite = await aliceClient.groupCiphersuite(groupIdBytes: groupId);
  printStep(5, 'Group ciphersuite', ['Suite: $suite']);
  print('');

  // 6. Own leaf node
  final leafNode = await aliceClient.groupOwnLeafNode(groupIdBytes: groupId);
  printStep(6, 'Own leaf node', [
    'Identity: "${credentialName(leafNode.credential)}"',
    'Signature key: ${bytesToHex(leafNode.signatureKey, maxLength: 16)}',
    'Encryption key: ${bytesToHex(leafNode.encryptionKey, maxLength: 16)}',
  ]);
  print('');

  // 7. Export group context
  final ctx = await aliceClient.exportGroupContext(groupIdBytes: groupId);
  printStep(7, 'Group context', [
    'Epoch: ${ctx.epoch}',
    'Ciphersuite: ${ctx.ciphersuite}',
    'Tree hash: ${bytesToHex(ctx.treeHash, maxLength: 24)}',
  ]);
  print('');

  // 8. Export secret
  final secret = await aliceClient.exportSecret(
    groupIdBytes: groupId,
    label: 'example-exporter',
    context: utf8.encode('demo'),
    keyLength: 32,
  );
  printStep(8, 'Exported secret', [
    'Label: "example-exporter"',
    'Size: ${secret.length} bytes',
    'Secret: ${bytesToHex(secret, maxLength: 32)}',
  ]);
  print('');

  // 9. Confirmation tag
  final tag = await aliceClient.groupConfirmationTag(groupIdBytes: groupId);
  printStep(9, 'Confirmation tag', [
    'Size: ${tag.length} bytes',
    'Tag: ${bytesToHex(tag, maxLength: 32)}',
  ]);
  print('');

  // 10. Member lookup by credential identity
  final bobCred = MlsCredential.basic(identity: utf8.encode('bob'));
  final bobIndex = await aliceClient.groupMemberLeafIndex(
    groupIdBytes: groupId,
    credentialBytes: bobCred.serialize(),
  );
  final bobMember = await aliceClient.groupMemberAt(
    groupIdBytes: groupId,
    leafIndex: bobIndex!,
  );
  printStep(10, 'Look up Bob by identity', [
    'Leaf index: $bobIndex',
    'Identity: "${credentialName(bobMember!.credential)}"',
  ]);
  print('');

  // 11. groupId function
  final queriedGroupId = await aliceClient.groupId(groupIdBytes: groupId);
  printStep(11, 'groupId()', [
    'Matches: ${bytesToHex(queriedGroupId) == bytesToHex(groupId)}',
  ]);
  print('');

  // 12. Group extensions
  final extensions = await aliceClient.groupExtensions(groupIdBytes: groupId);
  printStep(12, 'Group extensions', [
    'Extensions bytes size: ${extensions.length}',
  ]);
  print('');

  // 13. Export ratchet tree
  final ratchetTree = await aliceClient.exportRatchetTree(
    groupIdBytes: groupId,
  );
  printStep(13, 'Export ratchet tree', [
    'Ratchet tree size: ${ratchetTree.length} bytes',
  ]);
  print('');

  // 14. Export group info
  final groupInfo = await aliceClient.exportGroupInfo(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
  );
  printStep(14, 'Export group info', [
    'Group info size: ${groupInfo.length} bytes',
  ]);
  print('');

  // 15. Past resumption PSK
  final psk = await aliceClient.getPastResumptionPsk(
    groupIdBytes: groupId,
    epoch: BigInt.zero,
  );
  printStep(15, 'Past resumption PSK (epoch 0)', [
    'PSK size: ${psk!.length} bytes',
    'PSK: ${bytesToHex(psk, maxLength: 32)}',
  ]);

  // No dispose() needed - FRB handles memory automatically
}
