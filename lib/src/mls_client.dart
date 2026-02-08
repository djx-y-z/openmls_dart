import 'dart:async';
import 'dart:typed_data';

import 'rust/api/config.dart';
import 'rust/api/provider.dart' as provider;
import 'rust/api/types.dart';

/// Abstract key-value storage interface for MLS state persistence.
///
/// Implement this with any backend (SQLite, Hive, shared preferences, etc.)
/// to provide persistent storage for MLS groups, key packages, and secrets.
///
/// Keys and values are opaque byte arrays. The key format is internal to
/// OpenMLS and should not be interpreted by the implementation.
abstract class MlsStorage {
  /// Read a value by key. Returns `null` if not found.
  FutureOr<Uint8List?> read(Uint8List key);

  /// Write a key-value pair. Overwrites if key already exists.
  FutureOr<void> write(Uint8List key, Uint8List value);

  /// Delete a key-value pair. No-op if key does not exist.
  FutureOr<void> delete(Uint8List key);
}

/// Convenience wrapper that injects [MlsStorage] callbacks into every
/// provider-based API call.
///
/// Usage:
/// ```dart
/// final storage = MyDatabaseStorage(); // implements MlsStorage
/// final client = MlsClient(storage);
///
/// final result = await client.createGroup(
///   config: config,
///   signerBytes: signer,
///   credentialIdentity: identity,
///   signerPublicKey: pubKey,
/// );
/// ```
class MlsClient {
  /// Creates an [MlsClient] backed by the given [storage].
  MlsClient(this.storage);

  /// The storage backend used for all MLS operations.
  final MlsStorage storage;

  // ---------------------------------------------------------------------------
  // Key Packages
  // ---------------------------------------------------------------------------

  Future<provider.KeyPackageProviderResult> createKeyPackage({
    required MlsCiphersuite ciphersuite,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
    required List<int> signerPublicKey,
  }) => provider.createKeyPackage(
    ciphersuite: ciphersuite,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    signerPublicKey: signerPublicKey,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.KeyPackageProviderResult> createKeyPackageWithOptions({
    required MlsCiphersuite ciphersuite,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
    required List<int> signerPublicKey,
    required KeyPackageOptions options,
  }) => provider.createKeyPackageWithOptions(
    ciphersuite: ciphersuite,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    signerPublicKey: signerPublicKey,
    options: options,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Group Creation
  // ---------------------------------------------------------------------------

  Future<provider.CreateGroupProviderResult> createGroup({
    required MlsGroupConfig config,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
    required List<int> signerPublicKey,
    Uint8List? groupId,
  }) => provider.createGroup(
    config: config,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    signerPublicKey: signerPublicKey,
    groupId: groupId,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.CreateGroupProviderResult> createGroupWithBuilder({
    required MlsGroupConfig config,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
    required List<int> signerPublicKey,
    Uint8List? groupId,
    BigInt? lifetimeSeconds,
    List<MlsExtension>? groupContextExtensions,
    List<MlsExtension>? leafNodeExtensions,
    MlsCapabilities? capabilities,
  }) => provider.createGroupWithBuilder(
    config: config,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    signerPublicKey: signerPublicKey,
    groupId: groupId,
    lifetimeSeconds: lifetimeSeconds,
    groupContextExtensions: groupContextExtensions,
    leafNodeExtensions: leafNodeExtensions,
    capabilities: capabilities,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Join Group
  // ---------------------------------------------------------------------------

  Future<provider.JoinGroupProviderResult> joinGroupFromWelcome({
    required MlsGroupConfig config,
    required List<int> welcomeBytes,
    Uint8List? ratchetTreeBytes,
    required List<int> signerBytes,
  }) => provider.joinGroupFromWelcome(
    config: config,
    welcomeBytes: welcomeBytes,
    ratchetTreeBytes: ratchetTreeBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.JoinGroupProviderResult> joinGroupFromWelcomeWithOptions({
    required MlsGroupConfig config,
    required List<int> welcomeBytes,
    Uint8List? ratchetTreeBytes,
    required List<int> signerBytes,
    required bool skipLifetimeValidation,
  }) => provider.joinGroupFromWelcomeWithOptions(
    config: config,
    welcomeBytes: welcomeBytes,
    ratchetTreeBytes: ratchetTreeBytes,
    signerBytes: signerBytes,
    skipLifetimeValidation: skipLifetimeValidation,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<WelcomeInspectResult> inspectWelcome({
    required MlsGroupConfig config,
    required List<int> welcomeBytes,
  }) => provider.inspectWelcome(
    config: config,
    welcomeBytes: welcomeBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ExternalJoinProviderResult> joinGroupExternalCommit({
    required MlsGroupConfig config,
    required List<int> groupInfoBytes,
    Uint8List? ratchetTreeBytes,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
    required List<int> signerPublicKey,
  }) => provider.joinGroupExternalCommit(
    config: config,
    groupInfoBytes: groupInfoBytes,
    ratchetTreeBytes: ratchetTreeBytes,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    signerPublicKey: signerPublicKey,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ExternalJoinProviderResult> joinGroupExternalCommitV2({
    required MlsGroupConfig config,
    required List<int> groupInfoBytes,
    Uint8List? ratchetTreeBytes,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
    required List<int> signerPublicKey,
    Uint8List? aad,
    required bool skipLifetimeValidation,
  }) => provider.joinGroupExternalCommitV2(
    config: config,
    groupInfoBytes: groupInfoBytes,
    ratchetTreeBytes: ratchetTreeBytes,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    signerPublicKey: signerPublicKey,
    aad: aad,
    skipLifetimeValidation: skipLifetimeValidation,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Group State Queries
  // ---------------------------------------------------------------------------

  Future<Uint8List> groupId({required List<int> groupIdBytes}) =>
      provider.groupId(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<BigInt> groupEpoch({required List<int> groupIdBytes}) =>
      provider.groupEpoch(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<bool> groupIsActive({required List<int> groupIdBytes}) =>
      provider.groupIsActive(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<List<MlsMemberInfo>> groupMembers({required List<int> groupIdBytes}) =>
      provider.groupMembers(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<MlsCiphersuite> groupCiphersuite({required List<int> groupIdBytes}) =>
      provider.groupCiphersuite(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<int> groupOwnIndex({required List<int> groupIdBytes}) =>
      provider.groupOwnIndex(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<Uint8List> groupCredential({required List<int> groupIdBytes}) =>
      provider.groupCredential(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<Uint8List> groupExtensions({required List<int> groupIdBytes}) =>
      provider.groupExtensions(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<List<MlsPendingProposalInfo>> groupPendingProposals({
    required List<int> groupIdBytes,
  }) => provider.groupPendingProposals(
    groupIdBytes: groupIdBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<bool> groupHasPendingProposals({required List<int> groupIdBytes}) =>
      provider.groupHasPendingProposals(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<MlsMemberInfo?> groupMemberAt({
    required List<int> groupIdBytes,
    required int leafIndex,
  }) => provider.groupMemberAt(
    groupIdBytes: groupIdBytes,
    leafIndex: leafIndex,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<int?> groupMemberLeafIndex({
    required List<int> groupIdBytes,
    required List<int> credentialIdentity,
  }) => provider.groupMemberLeafIndex(
    groupIdBytes: groupIdBytes,
    credentialIdentity: credentialIdentity,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Exports
  // ---------------------------------------------------------------------------

  Future<Uint8List> exportRatchetTree({required List<int> groupIdBytes}) =>
      provider.exportRatchetTree(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<Uint8List> exportGroupInfo({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
  }) => provider.exportGroupInfo(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<Uint8List> exportSecret({
    required List<int> groupIdBytes,
    required String label,
    required List<int> context,
    required int keyLength,
  }) => provider.exportSecret(
    groupIdBytes: groupIdBytes,
    label: label,
    context: context,
    keyLength: keyLength,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<MlsGroupContextInfo> exportGroupContext({
    required List<int> groupIdBytes,
  }) => provider.exportGroupContext(
    groupIdBytes: groupIdBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<Uint8List> groupConfirmationTag({required List<int> groupIdBytes}) =>
      provider.groupConfirmationTag(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<MlsLeafNodeInfo> groupOwnLeafNode({required List<int> groupIdBytes}) =>
      provider.groupOwnLeafNode(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<Uint8List?> getPastResumptionPsk({
    required List<int> groupIdBytes,
    required BigInt epoch,
  }) => provider.getPastResumptionPsk(
    groupIdBytes: groupIdBytes,
    epoch: epoch,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Member Management
  // ---------------------------------------------------------------------------

  Future<provider.AddMembersProviderResult> addMembers({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<Uint8List> keyPackagesBytes,
  }) => provider.addMembers(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    keyPackagesBytes: keyPackagesBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.AddMembersProviderResult> addMembersWithoutUpdate({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<Uint8List> keyPackagesBytes,
  }) => provider.addMembersWithoutUpdate(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    keyPackagesBytes: keyPackagesBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.CommitProviderResult> removeMembers({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<int> memberIndices,
  }) => provider.removeMembers(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    memberIndices: memberIndices,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.CommitProviderResult> selfUpdate({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
  }) => provider.selfUpdate(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.CommitProviderResult> selfUpdateWithNewSigner({
    required List<int> groupIdBytes,
    required List<int> oldSignerBytes,
    required List<int> newSignerBytes,
    required List<int> newCredentialIdentity,
    required List<int> newSignerPublicKey,
  }) => provider.selfUpdateWithNewSigner(
    groupIdBytes: groupIdBytes,
    oldSignerBytes: oldSignerBytes,
    newSignerBytes: newSignerBytes,
    newCredentialIdentity: newCredentialIdentity,
    newSignerPublicKey: newSignerPublicKey,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.AddMembersProviderResult> swapMembers({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<int> removeIndices,
    required List<Uint8List> addKeyPackagesBytes,
  }) => provider.swapMembers(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    removeIndices: removeIndices,
    addKeyPackagesBytes: addKeyPackagesBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.LeaveGroupProviderResult> leaveGroup({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
  }) => provider.leaveGroup(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.LeaveGroupProviderResult> leaveGroupViaSelfRemove({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
  }) => provider.leaveGroupViaSelfRemove(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Proposals
  // ---------------------------------------------------------------------------

  Future<provider.ProposalProviderResult> proposeAdd({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<int> keyPackageBytes,
  }) => provider.proposeAdd(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    keyPackageBytes: keyPackageBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProposalProviderResult> proposeRemove({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required int memberIndex,
  }) => provider.proposeRemove(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    memberIndex: memberIndex,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProposalProviderResult> proposeSelfUpdate({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
  }) => provider.proposeSelfUpdate(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProposalProviderResult> proposeExternalPsk({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<int> pskId,
    required List<int> pskNonce,
  }) => provider.proposeExternalPsk(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    pskId: pskId,
    pskNonce: pskNonce,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProposalProviderResult> proposeGroupContextExtensions({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<MlsExtension> extensions,
  }) => provider.proposeGroupContextExtensions(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    extensions: extensions,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProposalProviderResult> proposeCustomProposal({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required int proposalType,
    required List<int> payload,
  }) => provider.proposeCustomProposal(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    proposalType: proposalType,
    payload: payload,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProposalProviderResult> proposeRemoveMemberByCredential({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<int> credentialIdentity,
  }) => provider.proposeRemoveMemberByCredential(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    credentialIdentity: credentialIdentity,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Commit / Merge
  // ---------------------------------------------------------------------------

  Future<provider.CommitProviderResult> commitToPendingProposals({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
  }) => provider.commitToPendingProposals(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<void> mergePendingCommit({required List<int> groupIdBytes}) =>
      provider.mergePendingCommit(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<void> clearPendingCommit({required List<int> groupIdBytes}) =>
      provider.clearPendingCommit(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<void> clearPendingProposals({required List<int> groupIdBytes}) =>
      provider.clearPendingProposals(
        groupIdBytes: groupIdBytes,
        storageRead: storage.read,
        storageWrite: storage.write,
        storageDelete: storage.delete,
      );

  Future<void> setConfiguration({
    required List<int> groupIdBytes,
    required MlsGroupConfig config,
  }) => provider.setConfiguration(
    groupIdBytes: groupIdBytes,
    config: config,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.CommitProviderResult> updateGroupContextExtensions({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<MlsExtension> extensions,
  }) => provider.updateGroupContextExtensions(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    extensions: extensions,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.CommitProviderResult> flexibleCommit({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required FlexibleCommitOptions options,
  }) => provider.flexibleCommit(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    options: options,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<provider.CreateMessageProviderResult> createMessage({
    required List<int> groupIdBytes,
    required List<int> signerBytes,
    required List<int> message,
    Uint8List? aad,
  }) => provider.createMessage(
    groupIdBytes: groupIdBytes,
    signerBytes: signerBytes,
    message: message,
    aad: aad,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProcessedMessageProviderResult> processMessage({
    required List<int> groupIdBytes,
    required List<int> messageBytes,
  }) => provider.processMessage(
    groupIdBytes: groupIdBytes,
    messageBytes: messageBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );

  Future<provider.ProcessedMessageInspectProviderResult>
  processMessageWithInspect({
    required List<int> groupIdBytes,
    required List<int> messageBytes,
  }) => provider.processMessageWithInspect(
    groupIdBytes: groupIdBytes,
    messageBytes: messageBytes,
    storageRead: storage.read,
    storageWrite: storage.write,
    storageDelete: storage.delete,
  );
}
