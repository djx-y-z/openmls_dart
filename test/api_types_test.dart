import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:openmls/src/rust/api/init.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(Openmls.init);

  // Shared byte arrays — Uint8List uses identity equality,
  // so we must share the same instance for "equal" tests.
  final b1 = Uint8List.fromList([1, 2, 3]);
  final b2 = Uint8List.fromList([4, 5, 6]);
  final b3 = Uint8List.fromList([7, 8, 9]);
  final b4 = Uint8List.fromList([10, 11, 12]);
  final bOther = Uint8List.fromList([99]);
  final u32 = Uint32List.fromList([0, 1]);
  final u16a = Uint16List.fromList([1]);
  final u16b = Uint16List.fromList([1]);
  final u16c = Uint16List(0);
  final u16d = Uint16List(0);
  final u16e = Uint16List.fromList([1]);

  group('api/init', () {
    test('initOpenmls accepts any library path', () {
      expect(() => initOpenmls(libraryPath: '/some/path'), returnsNormally);
    });

    test('initOpenmls accepts empty library path', () {
      expect(() => initOpenmls(libraryPath: ''), returnsNormally);
    });

    test('isOpenmlsInitialized returns true after init', () {
      expect(isOpenmlsInitialized(), isTrue);
    });
  });

  group('api/types', () {
    test('supportedCiphersuites returns non-empty list', () {
      final suites = supportedCiphersuites();
      expect(suites, isNotEmpty);
      expect(
        suites,
        contains(MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519),
      );
    });
  });

  group('MlsGroupConfig equality', () {
    test('equal configs', () {
      final cfg1 = MlsGroupConfig(
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      final cfg2 = MlsGroupConfig(
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      expect(cfg1, equals(cfg2));
      expect(cfg1.hashCode, equals(cfg2.hashCode));
      expect(cfg1, equals(cfg1));
    });

    test('unequal configs', () {
      final cfg1 = MlsGroupConfig(
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      final cfg2 = MlsGroupConfig(
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        wireFormatPolicy: MlsWireFormatPolicy.plaintext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      expect(cfg1, isNot(equals(cfg2)));
    });

    test('wrong type', () {
      final cfg = MlsGroupConfig(
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
        useRatchetTreeExtension: true,
        maxPastEpochs: 0,
        paddingSize: 0,
        senderRatchetMaxOutOfOrder: 10,
        senderRatchetMaxForwardDistance: 1000,
        numberOfResumptionPsks: 0,
      );
      // ignore: unrelated_type_equality_checks
      expect(cfg == 'not a config', isFalse);
    });
  });

  group('FlexibleCommitOptions equality', () {
    test('equal options', () {
      final kps = [b1];
      final o1 = FlexibleCommitOptions(
        addKeyPackages: kps,
        removeIndices: u32,
        forceSelfUpdate: false,
        consumePendingProposals: true,
        createGroupInfo: true,
        useRatchetTreeExtension: true,
      );
      final o2 = FlexibleCommitOptions(
        addKeyPackages: kps,
        removeIndices: u32,
        forceSelfUpdate: false,
        consumePendingProposals: true,
        createGroupInfo: true,
        useRatchetTreeExtension: true,
      );
      expect(o1, equals(o2));
      expect(o1.hashCode, equals(o2.hashCode));
      expect(o1, equals(o1));
    });

    test('unequal options', () {
      final kps = <Uint8List>[];
      final idx = Uint32List(0);
      final o1 = FlexibleCommitOptions(
        addKeyPackages: kps,
        removeIndices: idx,
        forceSelfUpdate: false,
        consumePendingProposals: true,
        createGroupInfo: true,
        useRatchetTreeExtension: true,
      );
      final o2 = FlexibleCommitOptions(
        addKeyPackages: kps,
        removeIndices: idx,
        forceSelfUpdate: true,
        consumePendingProposals: true,
        createGroupInfo: true,
        useRatchetTreeExtension: true,
      );
      expect(o1, isNot(equals(o2)));
    });
  });

  group('KeyPackageOptions equality', () {
    test('equal options', () {
      final o1 = KeyPackageOptions(lastResort: false);
      final o2 = KeyPackageOptions(lastResort: false);
      expect(o1, equals(o2));
      expect(o1.hashCode, equals(o2.hashCode));
      expect(o1, equals(o1));
    });

    test('unequal options', () {
      final o1 = KeyPackageOptions(lastResort: false);
      final o2 = KeyPackageOptions(lastResort: true);
      expect(o1, isNot(equals(o2)));
    });
  });

  group('MlsCapabilities equality', () {
    test('equal capabilities', () {
      final c1 = MlsCapabilities(
        versions: u16a,
        ciphersuites: u16b,
        extensions: u16c,
        proposals: u16d,
        credentials: u16e,
      );
      final c2 = MlsCapabilities(
        versions: u16a,
        ciphersuites: u16b,
        extensions: u16c,
        proposals: u16d,
        credentials: u16e,
      );
      expect(c1, equals(c2));
      expect(c1.hashCode, equals(c2.hashCode));
      expect(c1, equals(c1));
    });

    test('unequal capabilities', () {
      final c1 = MlsCapabilities(
        versions: u16a,
        ciphersuites: u16b,
        extensions: u16c,
        proposals: u16d,
        credentials: u16e,
      );
      final c2 = MlsCapabilities(
        versions: Uint16List.fromList([99]),
        ciphersuites: u16b,
        extensions: u16c,
        proposals: u16d,
        credentials: u16e,
      );
      expect(c1, isNot(equals(c2)));
    });
  });

  group('MlsExtension equality', () {
    test('equal extensions', () {
      final e1 = MlsExtension(extensionType: 1, data: b1);
      final e2 = MlsExtension(extensionType: 1, data: b1);
      expect(e1, equals(e2));
      expect(e1.hashCode, equals(e2.hashCode));
      expect(e1, equals(e1));
    });

    test('unequal extensions', () {
      final e1 = MlsExtension(extensionType: 1, data: b1);
      final e2 = MlsExtension(extensionType: 2, data: b1);
      expect(e1, isNot(equals(e2)));
    });
  });

  group('MlsGroupContextInfo equality', () {
    test('equal contexts', () {
      final c1 = MlsGroupContextInfo(
        groupId: b1,
        epoch: BigInt.one,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        treeHash: b2,
        confirmedTranscriptHash: b3,
        extensions: b4,
      );
      final c2 = MlsGroupContextInfo(
        groupId: b1,
        epoch: BigInt.one,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        treeHash: b2,
        confirmedTranscriptHash: b3,
        extensions: b4,
      );
      expect(c1, equals(c2));
      expect(c1.hashCode, equals(c2.hashCode));
      expect(c1, equals(c1));
    });

    test('unequal contexts', () {
      final c1 = MlsGroupContextInfo(
        groupId: b1,
        epoch: BigInt.one,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        treeHash: b2,
        confirmedTranscriptHash: b3,
        extensions: b4,
      );
      final c2 = MlsGroupContextInfo(
        groupId: b1,
        epoch: BigInt.two,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        treeHash: b2,
        confirmedTranscriptHash: b3,
        extensions: b4,
      );
      expect(c1, isNot(equals(c2)));
    });
  });

  group('MlsLeafNodeInfo equality', () {
    test('equal leaf nodes', () {
      final caps = MlsCapabilities(
        versions: u16a,
        ciphersuites: u16b,
        extensions: u16c,
        proposals: u16d,
        credentials: u16e,
      );
      final exts = <MlsExtension>[];
      final n1 = MlsLeafNodeInfo(
        credential: b1,
        signatureKey: b2,
        encryptionKey: b3,
        capabilities: caps,
        extensions: exts,
      );
      final n2 = MlsLeafNodeInfo(
        credential: b1,
        signatureKey: b2,
        encryptionKey: b3,
        capabilities: caps,
        extensions: exts,
      );
      expect(n1, equals(n2));
      expect(n1.hashCode, equals(n2.hashCode));
      expect(n1, equals(n1));
    });

    test('unequal leaf nodes', () {
      final caps = MlsCapabilities(
        versions: u16a,
        ciphersuites: u16b,
        extensions: u16c,
        proposals: u16d,
        credentials: u16e,
      );
      final n1 = MlsLeafNodeInfo(
        credential: b1,
        signatureKey: b2,
        encryptionKey: b3,
        capabilities: caps,
        extensions: [],
      );
      final n2 = MlsLeafNodeInfo(
        credential: bOther,
        signatureKey: b2,
        encryptionKey: b3,
        capabilities: caps,
        extensions: [],
      );
      expect(n1, isNot(equals(n2)));
    });
  });

  group('MlsMemberInfo equality', () {
    test('equal members', () {
      final m1 = MlsMemberInfo(index: 0, credential: b1, signatureKey: b2);
      final m2 = MlsMemberInfo(index: 0, credential: b1, signatureKey: b2);
      expect(m1, equals(m2));
      expect(m1.hashCode, equals(m2.hashCode));
      expect(m1, equals(m1));
    });

    test('unequal members', () {
      final m1 = MlsMemberInfo(index: 0, credential: b1, signatureKey: b2);
      final m2 = MlsMemberInfo(index: 1, credential: b1, signatureKey: b2);
      expect(m1, isNot(equals(m2)));
    });
  });

  group('MlsPendingProposalInfo equality', () {
    test('equal proposals', () {
      final p1 = MlsPendingProposalInfo(
        proposalType: MlsProposalType.add,
        senderIndex: 0,
      );
      final p2 = MlsPendingProposalInfo(
        proposalType: MlsProposalType.add,
        senderIndex: 0,
      );
      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
      expect(p1, equals(p1));
    });

    test('unequal proposals', () {
      final p1 = MlsPendingProposalInfo(
        proposalType: MlsProposalType.add,
        senderIndex: 0,
      );
      final p2 = MlsPendingProposalInfo(
        proposalType: MlsProposalType.remove,
        senderIndex: 0,
      );
      expect(p1, isNot(equals(p2)));
    });
  });

  group('StagedCommitInfo equality', () {
    test('equal infos', () {
      final creds = [b1];
      final s1 = StagedCommitInfo(
        addCredentials: creds,
        removeIndices: u32,
        hasUpdate: false,
        selfRemoved: false,
        pskCount: 0,
      );
      final s2 = StagedCommitInfo(
        addCredentials: creds,
        removeIndices: u32,
        hasUpdate: false,
        selfRemoved: false,
        pskCount: 0,
      );
      expect(s1, equals(s2));
      expect(s1.hashCode, equals(s2.hashCode));
      expect(s1, equals(s1));
    });

    test('unequal infos', () {
      final creds = <Uint8List>[];
      final idx = Uint32List(0);
      final s1 = StagedCommitInfo(
        addCredentials: creds,
        removeIndices: idx,
        hasUpdate: false,
        selfRemoved: false,
        pskCount: 0,
      );
      final s2 = StagedCommitInfo(
        addCredentials: creds,
        removeIndices: idx,
        hasUpdate: true,
        selfRemoved: false,
        pskCount: 0,
      );
      expect(s1, isNot(equals(s2)));
    });
  });

  group('WelcomeInspectResult equality', () {
    test('equal results', () {
      final w1 = WelcomeInspectResult(
        groupId: b1,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        pskCount: 0,
        epoch: BigInt.one,
      );
      final w2 = WelcomeInspectResult(
        groupId: b1,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        pskCount: 0,
        epoch: BigInt.one,
      );
      expect(w1, equals(w2));
      expect(w1.hashCode, equals(w2.hashCode));
      expect(w1, equals(w1));
    });

    test('unequal results', () {
      final w1 = WelcomeInspectResult(
        groupId: b1,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        pskCount: 0,
        epoch: BigInt.one,
      );
      final w2 = WelcomeInspectResult(
        groupId: bOther,
        ciphersuite: MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519,
        pskCount: 0,
        epoch: BigInt.one,
      );
      expect(w1, isNot(equals(w2)));
    });
  });

  // --- provider.dart result types ---

  group('AddMembersProviderResult equality', () {
    test('equal results', () {
      final r1 = AddMembersProviderResult(commit: b1, welcome: b2);
      final r2 = AddMembersProviderResult(commit: b1, welcome: b2);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = AddMembersProviderResult(commit: b1, welcome: b2);
      final r2 = AddMembersProviderResult(commit: bOther, welcome: b2);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('CommitProviderResult equality', () {
    test('equal results', () {
      final r1 = CommitProviderResult(commit: b1);
      final r2 = CommitProviderResult(commit: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = CommitProviderResult(commit: b1);
      final r2 = CommitProviderResult(commit: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('CreateGroupProviderResult equality', () {
    test('equal results', () {
      final r1 = CreateGroupProviderResult(groupId: b1);
      final r2 = CreateGroupProviderResult(groupId: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = CreateGroupProviderResult(groupId: b1);
      final r2 = CreateGroupProviderResult(groupId: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('CreateMessageProviderResult equality', () {
    test('equal results', () {
      final r1 = CreateMessageProviderResult(ciphertext: b1);
      final r2 = CreateMessageProviderResult(ciphertext: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = CreateMessageProviderResult(ciphertext: b1);
      final r2 = CreateMessageProviderResult(ciphertext: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('ExternalJoinProviderResult equality', () {
    test('equal results', () {
      final r1 = ExternalJoinProviderResult(groupId: b1, commit: b2);
      final r2 = ExternalJoinProviderResult(groupId: b1, commit: b2);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = ExternalJoinProviderResult(groupId: b1, commit: b2);
      final r2 = ExternalJoinProviderResult(groupId: bOther, commit: b2);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('JoinGroupProviderResult equality', () {
    test('equal results', () {
      final r1 = JoinGroupProviderResult(groupId: b1);
      final r2 = JoinGroupProviderResult(groupId: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = JoinGroupProviderResult(groupId: b1);
      final r2 = JoinGroupProviderResult(groupId: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('KeyPackageProviderResult equality', () {
    test('equal results', () {
      final r1 = KeyPackageProviderResult(keyPackageBytes: b1);
      final r2 = KeyPackageProviderResult(keyPackageBytes: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = KeyPackageProviderResult(keyPackageBytes: b1);
      final r2 = KeyPackageProviderResult(keyPackageBytes: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('LeaveGroupProviderResult equality', () {
    test('equal results', () {
      final r1 = LeaveGroupProviderResult(message: b1);
      final r2 = LeaveGroupProviderResult(message: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = LeaveGroupProviderResult(message: b1);
      final r2 = LeaveGroupProviderResult(message: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('ProcessedMessageInspectProviderResult equality', () {
    test('equal results', () {
      final r1 = ProcessedMessageInspectProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
        applicationMessage: b1,
      );
      final r2 = ProcessedMessageInspectProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
        applicationMessage: b1,
      );
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = ProcessedMessageInspectProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
      );
      final r2 = ProcessedMessageInspectProviderResult(
        messageType: ProcessedMessageType.stagedCommit,
        epoch: BigInt.one,
      );
      expect(r1, isNot(equals(r2)));
    });
  });

  group('ProcessedMessageProviderResult equality', () {
    test('equal results', () {
      final r1 = ProcessedMessageProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
        hasStagedCommit: false,
        hasProposal: false,
      );
      final r2 = ProcessedMessageProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
        hasStagedCommit: false,
        hasProposal: false,
      );
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = ProcessedMessageProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
        hasStagedCommit: false,
        hasProposal: false,
      );
      final r2 = ProcessedMessageProviderResult(
        messageType: ProcessedMessageType.application,
        epoch: BigInt.one,
        hasStagedCommit: true,
        hasProposal: false,
      );
      expect(r1, isNot(equals(r2)));
    });
  });

  group('ProposalProviderResult equality', () {
    test('equal results', () {
      final r1 = ProposalProviderResult(proposalMessage: b1);
      final r2 = ProposalProviderResult(proposalMessage: b1);
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, equals(r1));
    });

    test('unequal results', () {
      final r1 = ProposalProviderResult(proposalMessage: b1);
      final r2 = ProposalProviderResult(proposalMessage: bOther);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('cross-type equality', () {
    test('different types are not equal', () {
      final create = CreateGroupProviderResult(groupId: b1);
      final join = JoinGroupProviderResult(groupId: b1);
      // ignore: unrelated_type_equality_checks
      expect(create == join, isFalse);
      // ignore: unrelated_type_equality_checks
      expect(create == 'string', isFalse);
      // ignore: unrelated_type_equality_checks
      expect(create == 42, isFalse);
    });
  });
}
