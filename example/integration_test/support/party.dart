import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

/// The suite a capability runs on unless it names another: the one every MLS
/// implementation has to support (RFC 9420 §17.1).
const defaultSuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

/// [text] as the bytes the library takes.
Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

/// Bytes the library gave back, read as text.
String textOf(List<int> bytes) => utf8.decode(bytes);

/// A database key as the engine requires it: 32 random bytes.
Uint8List freshKey() {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
}

/// One participant: a signature key pair on [suite], a basic credential that
/// names it, and an engine of its own.
///
/// The engine is on `":memory:"`, which on the web is a new IndexedDB database
/// each time, so no two parties ever share storage. It is closed when the
/// capability that made it ends.
class Party {
  Party._(this.name, this.suite, this.keys, this.engine);

  static Future<Party> create(
    String name, {
    MlsCiphersuite suite = defaultSuite,
  }) async {
    final keys = MlsSignatureKeyPair.generate(ciphersuite: suite);
    final engine = await MlsEngine.create(
      dbPath: ':memory:',
      encryptionKey: freshKey(),
    );
    addTearDown(engine.close);
    return Party._(name, suite, keys, engine);
  }

  final String name;
  final MlsCiphersuite suite;
  final MlsSignatureKeyPair keys;
  final MlsEngine engine;

  /// What this party's credential says it is.
  Uint8List get identity => bytesOf(name);

  Uint8List get publicKey => keys.publicKey();

  /// The key pair as the engine takes it.
  Uint8List get signer => serializeSigner(
    ciphersuite: suite,
    privateKey: keys.privateKey(),
    publicKey: keys.publicKey(),
  );

  /// The credential as a group stores it: TLS-serialized.
  Uint8List get credential =>
      MlsCredential.basic(identity: identity).serialize();

  /// The default configuration on this party's suite.
  MlsGroupConfig get config => MlsGroupConfig.defaultConfig(ciphersuite: suite);

  /// A new key package, for someone to add this party with.
  Future<Uint8List> keyPackage() async => (await engine.createKeyPackage(
    ciphersuite: suite,
    signerBytes: signer,
    credentialIdentity: identity,
    signerPublicKey: publicKey,
  )).keyPackageBytes;

  /// A new group with only this party in it.
  Future<Uint8List> createGroup({MlsGroupConfig? config}) async =>
      (await engine.createGroup(
        config: config ?? this.config,
        signerBytes: signer,
        credentialIdentity: identity,
        signerPublicKey: publicKey,
      )).groupId;

  /// Joins from [welcome], and returns the group's ID.
  Future<Uint8List> join(
    List<int> welcome, {
    Uint8List? ratchetTree,
    MlsGroupConfig? config,
  }) async => (await engine.joinGroupFromWelcome(
    config: config ?? this.config,
    welcomeBytes: welcome,
    ratchetTreeBytes: ratchetTree,
    signerBytes: signer,
  )).groupId;

  Future<BigInt> epochOf(List<int> group) =>
      engine.groupEpoch(groupIdBytes: group);

  /// [text], encrypted to [group].
  Future<Uint8List> send(
    List<int> group,
    String text, {
    Uint8List? aad,
  }) async => (await engine.createMessage(
    groupIdBytes: group,
    signerBytes: signer,
    message: bytesOf(text),
    aad: aad,
  )).ciphertext;

  /// Processes [message]. A commit is merged by this, a proposal is stored.
  Future<ProcessedMessageResult> receive(List<int> group, List<int> message) =>
      engine.processMessage(groupIdBytes: group, messageBytes: message);
}

/// A new group of [owner]'s, with [members] added in one commit, merged, and
/// joined by each of them from the Welcome. Returns the group's ID.
Future<Uint8List> groupOf(
  Party owner,
  List<Party> members, {
  MlsGroupConfig? config,
}) async {
  final group = await owner.createGroup(config: config);
  if (members.isEmpty) return group;
  final added = await owner.engine.addMembers(
    groupIdBytes: group,
    signerBytes: owner.signer,
    keyPackagesBytes: [for (final member in members) await member.keyPackage()],
  );
  await owner.engine.mergePendingCommit(groupIdBytes: group);
  for (final member in members) {
    expect(await member.join(added.welcome, config: config), group);
  }
  return group;
}

/// [message], processed by each of [parties] in turn.
Future<void> deliver(
  List<int> group,
  List<int> message,
  List<Party> parties,
) async {
  for (final party in parties) {
    await party.receive(group, message);
  }
}
