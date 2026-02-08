import 'dart:convert';

import 'package:openmls/openmls.dart';

import '../utils.dart';

/// Demonstrates group state queries: members, epoch, extensions, exports.
Future<void> runStateDemo() async {
  printHeader('State Queries Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  // Setup: Alice creates group, adds Bob
  final aliceStorage = InMemoryMlsStorage();
  final aliceClient = MlsClient(aliceStorage);
  final aliceKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
  final aliceSigner = serializeSigner(
    ciphersuite: ciphersuite,
    privateKey: aliceKeyPair.privateKey(),
    publicKey: aliceKeyPair.publicKey(),
  );

  final bobStorage = InMemoryMlsStorage();
  final bobClient = MlsClient(bobStorage);
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

  // No dispose() needed - FRB handles memory automatically
}
