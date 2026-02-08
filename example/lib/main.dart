import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openmls/openmls.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isInitialized = false;

  String? _keysResult;
  String? _groupsResult;
  String? _stateResult;
  String? _proposalsResult;

  bool _keysLoading = false;
  bool _groupsLoading = false;
  bool _stateLoading = false;
  bool _proposalsLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initOpenmls();
  }

  Future<void> _initOpenmls() async {
    await Openmls.init();
    setState(() => _isInitialized = true);
  }

  @override
  void dispose() {
    _tabController.dispose();
    Openmls.cleanup();
    super.dispose();
  }

  String _bytesToHex(Uint8List bytes, {int? maxLength}) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (maxLength != null && hex.length > maxLength) {
      return '${hex.substring(0, maxLength)}...';
    }
    return hex;
  }

  // ============================================
  // Keys Demo
  // ============================================
  Future<void> _runKeysDemo() async {
    setState(() {
      _keysLoading = true;
      _keysResult = null;
    });

    try {
      final result = StringBuffer();
      final ciphersuite =
          MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

      // 1. Generate key pair
      final signer = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final publicKey = signer.publicKey();
      result.writeln('1. MlsSignatureKeyPair generated');
      result.writeln('   Ciphersuite: $ciphersuite');
      result.writeln('   Public key size: ${publicKey.length} bytes');
      result.writeln('   Public key: ${_bytesToHex(publicKey, maxLength: 32)}');
      result.writeln('   Scheme: ${signer.signatureScheme()}');
      result.writeln();

      // 2. Serialize round-trip
      final serialized = signer.serialize();
      final restored = MlsSignatureKeyPair.deserializePublic(bytes: serialized);
      result.writeln('2. Serialize / deserialize');
      result.writeln('   Serialized size: ${serialized.length} bytes');
      result.writeln(
        '   Keys match: ${_bytesToHex(publicKey) == _bytesToHex(restored.publicKey())}',
      );
      result.writeln();

      // 3. BasicCredential
      final cred = MlsCredential.basic(identity: utf8.encode('alice'));
      result.writeln('3. BasicCredential');
      result.writeln('   Identity: "${utf8.decode(cred.identity())}"');
      result.writeln('   Type: ${cred.credentialType()} (1 = Basic)');
      result.writeln();

      // 4. Credential round-trip
      final credBytes = cred.serialize();
      final credRestored = MlsCredential.deserialize(bytes: credBytes);
      result.writeln('4. Credential round-trip');
      result.writeln('   Serialized size: ${credBytes.length} bytes');
      result.writeln('   Restored: "${utf8.decode(credRestored.identity())}"');
      result.writeln();

      // 5. Supported ciphersuites
      final suites = supportedCiphersuites();
      result.writeln('5. Supported ciphersuites');
      for (final s in suites) {
        result.writeln('   - $s');
      }

      setState(() => _keysResult = result.toString());
    } catch (e) {
      setState(() => _keysResult = 'Error: $e');
    } finally {
      setState(() => _keysLoading = false);
    }
  }

  // ============================================
  // Groups Demo
  // ============================================
  Future<void> _runGroupsDemo() async {
    setState(() {
      _groupsLoading = true;
      _groupsResult = null;
    });

    try {
      final result = StringBuffer();
      final ciphersuite =
          MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
      final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

      final aliceClient = MlsClient(InMemoryMlsStorage());
      final aliceKeyPair = MlsSignatureKeyPair.generate(
        ciphersuite: ciphersuite,
      );
      final aliceSigner = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: aliceKeyPair.privateKey(),
        publicKey: aliceKeyPair.publicKey(),
      );

      final bobClient = MlsClient(InMemoryMlsStorage());
      final bobKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final bobSigner = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: bobKeyPair.privateKey(),
        publicKey: bobKeyPair.publicKey(),
      );

      // 1. Create group
      final group = await aliceClient.createGroup(
        config: config,
        signerBytes: aliceSigner,
        credentialIdentity: utf8.encode('alice'),
        signerPublicKey: aliceKeyPair.publicKey(),
      );
      final groupId = group.groupId;
      result.writeln('1. Alice created group');
      result.writeln('   Group ID: ${_bytesToHex(groupId, maxLength: 32)}');
      result.writeln();

      // 2. Bob's key package
      final bobKp = await bobClient.createKeyPackage(
        ciphersuite: ciphersuite,
        signerBytes: bobSigner,
        credentialIdentity: utf8.encode('bob'),
        signerPublicKey: bobKeyPair.publicKey(),
      );
      result.writeln('2. Bob created key package');
      result.writeln('   Size: ${bobKp.keyPackageBytes.length} bytes');
      result.writeln();

      // 3. Add Bob
      final addResult = await aliceClient.addMembers(
        groupIdBytes: groupId,
        signerBytes: aliceSigner,
        keyPackagesBytes: [bobKp.keyPackageBytes],
      );
      result.writeln('3. Alice added Bob');
      result.writeln('   Commit: ${addResult.commit.length} bytes');
      result.writeln('   Welcome: ${addResult.welcome.length} bytes');
      result.writeln();

      // 4. Bob joins
      final joinResult = await bobClient.joinGroupFromWelcome(
        config: config,
        welcomeBytes: addResult.welcome,
        signerBytes: bobSigner,
      );
      result.writeln('4. Bob joined via Welcome');
      result.writeln(
        '   Match: ${_bytesToHex(groupId) == _bytesToHex(joinResult.groupId)}',
      );
      result.writeln();

      // 5. Encrypt / decrypt
      const messageText = 'Hello, Bob!';
      final encrypted = await aliceClient.createMessage(
        groupIdBytes: groupId,
        signerBytes: aliceSigner,
        message: utf8.encode(messageText),
      );
      final processed = await bobClient.processMessage(
        groupIdBytes: groupId,
        messageBytes: encrypted.ciphertext,
      );
      final decrypted = utf8.decode(processed.applicationMessage!);
      result.writeln('5. Message exchange');
      result.writeln('   Sent: "$messageText"');
      result.writeln('   Received: "$decrypted"');
      result.writeln('   Match: ${decrypted == messageText}');
      result.writeln();

      // 6. Bob replies
      const replyText = 'Hi Alice!';
      final reply = await bobClient.createMessage(
        groupIdBytes: groupId,
        signerBytes: bobSigner,
        message: utf8.encode(replyText),
      );
      final aliceProcessed = await aliceClient.processMessage(
        groupIdBytes: groupId,
        messageBytes: reply.ciphertext,
      );
      result.writeln('6. Bob replied');
      result.writeln(
        '   Reply: "${utf8.decode(aliceProcessed.applicationMessage!)}"',
      );

      setState(() => _groupsResult = result.toString());
    } catch (e) {
      setState(() => _groupsResult = 'Error: $e');
    } finally {
      setState(() => _groupsLoading = false);
    }
  }

  // ============================================
  // State Queries Demo
  // ============================================
  Future<void> _runStateDemo() async {
    setState(() {
      _stateLoading = true;
      _stateResult = null;
    });

    try {
      final result = StringBuffer();
      final ciphersuite =
          MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
      final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

      final aliceClient = MlsClient(InMemoryMlsStorage());
      final aliceKeyPair = MlsSignatureKeyPair.generate(
        ciphersuite: ciphersuite,
      );
      final aliceSigner = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: aliceKeyPair.privateKey(),
        publicKey: aliceKeyPair.publicKey(),
      );

      final bobClient = MlsClient(InMemoryMlsStorage());
      final bobKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final bobSigner = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: bobKeyPair.privateKey(),
        publicKey: bobKeyPair.publicKey(),
      );

      // Setup
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
      result.writeln('Setup: Alice + Bob in group');
      result.writeln();

      // 1. Epoch
      final epoch = await aliceClient.groupEpoch(groupIdBytes: groupId);
      result.writeln('1. Epoch: $epoch');
      result.writeln();

      // 2. Members
      final members = await aliceClient.groupMembers(groupIdBytes: groupId);
      result.writeln('2. Members (${members.length}):');
      for (final m in members) {
        result.writeln(
          '   [${m.index}] "${utf8.decode(MlsCredential.deserialize(bytes: Uint8List.fromList(m.credential)).identity())}"',
        );
      }
      result.writeln();

      // 3. Own identity
      final ownIdx = await aliceClient.groupOwnIndex(groupIdBytes: groupId);
      final ownIdentity = await aliceClient.groupCredential(
        groupIdBytes: groupId,
      );
      result.writeln('3. Own identity');
      result.writeln('   Index: $ownIdx');
      result.writeln('   Identity: "${utf8.decode(ownIdentity)}"');
      result.writeln();

      // 4. Active + ciphersuite
      final active = await aliceClient.groupIsActive(groupIdBytes: groupId);
      final suite = await aliceClient.groupCiphersuite(groupIdBytes: groupId);
      result.writeln('4. Active: $active');
      result.writeln('   Ciphersuite: $suite');
      result.writeln();

      // 5. Group context
      final ctx = await aliceClient.exportGroupContext(groupIdBytes: groupId);
      result.writeln('5. Group context');
      result.writeln('   Epoch: ${ctx.epoch}');
      result.writeln(
        '   Tree hash: ${_bytesToHex(ctx.treeHash, maxLength: 24)}',
      );
      result.writeln();

      // 6. Exported secret
      final secret = await aliceClient.exportSecret(
        groupIdBytes: groupId,
        label: 'demo',
        context: utf8.encode('example'),
        keyLength: 32,
      );
      result.writeln('6. Exported secret');
      result.writeln('   Size: ${secret.length} bytes');
      result.writeln('   Hex: ${_bytesToHex(secret, maxLength: 32)}');

      setState(() => _stateResult = result.toString());
    } catch (e) {
      setState(() => _stateResult = 'Error: $e');
    } finally {
      setState(() => _stateLoading = false);
    }
  }

  // ============================================
  // Proposals Demo
  // ============================================
  Future<void> _runProposalsDemo() async {
    setState(() {
      _proposalsLoading = true;
      _proposalsResult = null;
    });

    try {
      final result = StringBuffer();
      final ciphersuite =
          MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
      final config = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

      final aliceClient = MlsClient(InMemoryMlsStorage());
      final aliceKeyPair = MlsSignatureKeyPair.generate(
        ciphersuite: ciphersuite,
      );
      final aliceSigner = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: aliceKeyPair.privateKey(),
        publicKey: aliceKeyPair.publicKey(),
      );

      final bobClient = MlsClient(InMemoryMlsStorage());
      final bobKeyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      final bobSigner = serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: bobKeyPair.privateKey(),
        publicKey: bobKeyPair.publicKey(),
      );

      // Setup
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
      result.writeln('Setup: Alice + Bob in group');
      result.writeln();

      // 1. Self-update
      final epochBefore = await aliceClient.groupEpoch(groupIdBytes: groupId);
      final updateCommit = await aliceClient.selfUpdate(
        groupIdBytes: groupId,
        signerBytes: aliceSigner,
      );
      final epochAfter = await aliceClient.groupEpoch(groupIdBytes: groupId);
      result.writeln('1. Alice self-updated');
      result.writeln('   Epoch: $epochBefore -> $epochAfter');
      await bobClient.processMessage(
        groupIdBytes: groupId,
        messageBytes: updateCommit.commit,
      );
      result.writeln();

      // 2. Propose self-update
      final proposal = await bobClient.proposeSelfUpdate(
        groupIdBytes: groupId,
        signerBytes: bobSigner,
      );
      result.writeln('2. Bob proposed self-update');
      result.writeln(
        '   Proposal size: ${proposal.proposalMessage.length} bytes',
      );
      await aliceClient.processMessage(
        groupIdBytes: groupId,
        messageBytes: proposal.proposalMessage,
      );
      result.writeln();

      // 3. Pending proposals
      final pending = await aliceClient.groupPendingProposals(
        groupIdBytes: groupId,
      );
      result.writeln('3. Pending proposals: ${pending.length}');
      for (final p in pending) {
        result.writeln('   - ${p.proposalType}');
      }
      result.writeln();

      // 4. Commit pending
      final commitResult = await aliceClient.commitToPendingProposals(
        groupIdBytes: groupId,
        signerBytes: aliceSigner,
      );
      result.writeln('4. Alice committed pending proposals');
      result.writeln('   Commit: ${commitResult.commit.length} bytes');
      await bobClient.processMessage(
        groupIdBytes: groupId,
        messageBytes: commitResult.commit,
      );
      result.writeln();

      // 5. Message utilities
      final msg = await aliceClient.createMessage(
        groupIdBytes: groupId,
        signerBytes: aliceSigner,
        message: utf8.encode('test'),
      );
      final contentType = mlsMessageContentType(messageBytes: msg.ciphertext);
      final extractedEpoch = mlsMessageExtractEpoch(
        messageBytes: msg.ciphertext,
      );
      result.writeln('5. Message utilities');
      result.writeln('   Content type: $contentType');
      result.writeln('   Epoch: $extractedEpoch');

      setState(() => _proposalsResult = result.toString());
    } catch (e) {
      setState(() => _proposalsResult = 'Error: $e');
    } finally {
      setState(() => _proposalsLoading = false);
    }
  }

  // ============================================
  // UI
  // ============================================

  Widget _buildDemoCard({
    required String title,
    required String description,
    required VoidCallback onRun,
    required bool isLoading,
    String? result,
  }) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              description,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: isLoading ? null : onRun,
              icon: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(isLoading ? 'Running...' : 'Run Demo'),
            ),
            if (result != null) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Result:',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy to clipboard',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: result));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: SelectableText(
                  result,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openmls Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('openmls Example'),
          centerTitle: true,
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: const [
              Tab(icon: Icon(Icons.key), text: 'Keys'),
              Tab(icon: Icon(Icons.group), text: 'Groups'),
              Tab(icon: Icon(Icons.info_outline), text: 'State'),
              Tab(icon: Icon(Icons.send), text: 'Proposals'),
            ],
          ),
        ),
        body: _isInitialized
            ? TabBarView(
                controller: _tabController,
                children: [
                  SingleChildScrollView(
                    child: _buildDemoCard(
                      title: 'Key Generation & Credentials',
                      description:
                          'Generate MLS signature key pairs, serialize/deserialize them, '
                          'and create Basic credentials. Shows the foundation types used '
                          'in all MLS operations.',
                      onRun: _runKeysDemo,
                      isLoading: _keysLoading,
                      result: _keysResult,
                    ),
                  ),
                  SingleChildScrollView(
                    child: _buildDemoCard(
                      title: 'Group Messaging',
                      description:
                          'Complete group lifecycle: Alice creates a group, adds Bob via '
                          'Welcome message, then they exchange encrypted messages. '
                          'Demonstrates the core MLS group key agreement protocol.',
                      onRun: _runGroupsDemo,
                      isLoading: _groupsLoading,
                      result: _groupsResult,
                    ),
                  ),
                  SingleChildScrollView(
                    child: _buildDemoCard(
                      title: 'Group State Queries',
                      description:
                          'Query group state: members, epoch, ciphersuite, own identity, '
                          'group context, exported secrets. Shows the read-only inspection '
                          'APIs available on MlsClient.',
                      onRun: _runStateDemo,
                      isLoading: _stateLoading,
                      result: _stateResult,
                    ),
                  ),
                  SingleChildScrollView(
                    child: _buildDemoCard(
                      title: 'Proposals & Commits',
                      description:
                          'Demonstrate the proposal/commit flow: self-update, propose '
                          'changes, inspect pending proposals, then commit. Also shows '
                          'message utility functions for inspecting MLS messages.',
                      onRun: _runProposalsDemo,
                      isLoading: _proposalsLoading,
                      result: _proposalsResult,
                    ),
                  ),
                ],
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
