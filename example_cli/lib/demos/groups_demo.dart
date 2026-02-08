import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../utils.dart';

/// Demonstrates MLS group lifecycle: create, add member, send/receive messages.
Future<void> runGroupsDemo() async {
  printHeader('Groups Demo');

  final ciphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
  final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  // Each participant has their own storage and signer
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

  // 1. Alice creates a group
  final group = await aliceClient.createGroup(
    config: config,
    signerBytes: aliceSigner,
    credentialIdentity: utf8.encode('alice'),
    signerPublicKey: aliceKeyPair.publicKey(),
  );
  final groupId = group.groupId;
  printStep(1, 'Alice created group', [
    'Group ID size: ${groupId.length} bytes',
    'Group ID: ${bytesToHex(groupId, maxLength: 32)}',
  ]);
  print('');

  // 2. Bob creates a key package
  final bobKp = await bobClient.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: bobSigner,
    credentialIdentity: utf8.encode('bob'),
    signerPublicKey: bobKeyPair.publicKey(),
  );
  printStep(2, 'Bob created key package', [
    'Key package size: ${bobKp.keyPackageBytes.length} bytes',
  ]);
  print('');

  // 3. Alice adds Bob to the group
  final addResult = await aliceClient.addMembers(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    keyPackagesBytes: [bobKp.keyPackageBytes],
  );
  printStep(3, 'Alice added Bob', [
    'Commit size: ${addResult.commit.length} bytes',
    'Welcome size: ${addResult.welcome.length} bytes',
  ]);
  print('');

  // 4. Bob joins via Welcome
  final joinResult = await bobClient.joinGroupFromWelcome(
    config: config,
    welcomeBytes: addResult.welcome,
    signerBytes: bobSigner,
  );
  printStep(4, 'Bob joined via Welcome', [
    'Joined group: ${bytesToHex(joinResult.groupId, maxLength: 32)}',
    'Group IDs match: ${bytesToHex(groupId) == bytesToHex(joinResult.groupId)}',
  ]);
  print('');

  // 5. Alice sends a message
  const messageText = 'Hello, Bob! Welcome to the group.';
  final encrypted = await aliceClient.createMessage(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    message: utf8.encode(messageText),
  );
  printStep(5, 'Alice encrypted message', [
    'Plaintext: "$messageText"',
    'Ciphertext size: ${encrypted.ciphertext.length} bytes',
  ]);
  print('');

  // 6. Bob decrypts the message
  final processed = await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: encrypted.ciphertext,
  );
  final decrypted = utf8.decode(processed.applicationMessage!);
  printStep(6, 'Bob decrypted message', [
    'Type: ${processed.messageType}',
    'Decrypted: "$decrypted"',
    'Match: ${decrypted == messageText}',
  ]);
  print('');

  // 7. Bob replies
  const replyText = 'Thanks, Alice!';
  final reply = await bobClient.createMessage(
    groupIdBytes: groupId,
    signerBytes: bobSigner,
    message: utf8.encode(replyText),
  );
  final aliceProcessed = await aliceClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: reply.ciphertext,
  );
  final aliceDecrypted = utf8.decode(aliceProcessed.applicationMessage!);
  printStep(7, 'Bob replied, Alice decrypted', [
    'Reply: "$aliceDecrypted"',
    'Match: ${aliceDecrypted == replyText}',
  ]);
  print('');

  // 8. Message with Additional Authenticated Data (AAD)
  const aadText = 'message-id:123';
  final aadMessage = await aliceClient.createMessage(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
    message: utf8.encode('Secret with AAD'),
    aad: Uint8List.fromList(utf8.encode(aadText)),
  );
  final aadProcessed = await bobClient.processMessage(
    groupIdBytes: groupId,
    messageBytes: aadMessage.ciphertext,
  );
  printStep(8, 'Message with AAD', [
    'AAD: "$aadText"',
    'Decrypted: "${utf8.decode(aadProcessed.applicationMessage!)}"',
  ]);
  print('');

  // 9. processMessageWithInspect — inspect staged commit details
  final updateResult = await aliceClient.selfUpdate(
    groupIdBytes: groupId,
    signerBytes: aliceSigner,
  );
  final inspected = await bobClient.processMessageWithInspect(
    groupIdBytes: groupId,
    messageBytes: updateResult.commit,
  );
  printStep(9, 'processMessageWithInspect', [
    'Type: ${inspected.messageType}',
    'Has staged commit info: ${inspected.stagedCommitInfo != null}',
    'Self removed: ${inspected.stagedCommitInfo?.selfRemoved}',
  ]);

  // No dispose() needed - FRB handles memory automatically
}
