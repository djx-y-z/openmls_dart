//! SnapshotStorageProvider — HashMap-based OpenMLS StorageProvider.
//!
//! Loaded from caller-owned storage entries, provides sync read/write/delete
//! on an in-memory HashMap. After OpenMLS operations, diff the initial
//! vs current state to produce StorageUpdates for the caller to persist.
//!
//! Key format matches MemoryStorage: `[LABEL || serde_json(key) || VERSION_BE_U16]`

use openmls_traits::OpenMlsProvider;
use openmls_traits::storage::{CURRENT_VERSION, StorageProvider, traits};
use parking_lot::Mutex;
use std::collections::HashMap;
use zeroize::Zeroize;

use crate::encrypted_db::StorageUpdates;

// ═══════════════════════════════════════════════════════════════
// ERROR TYPE
// ═══════════════════════════════════════════════════════════════

#[derive(thiserror::Error, Debug)]
pub enum SnapshotStorageError {
    #[error("Serialization error: {0}")]
    Serialization(String),
}

// ═══════════════════════════════════════════════════════════════
// LABELS (matching MemoryStorage exactly)
// ═══════════════════════════════════════════════════════════════

const KEY_PACKAGE_LABEL: &[u8] = b"KeyPackage";
const PSK_LABEL: &[u8] = b"Psk";
const ENCRYPTION_KEY_PAIR_LABEL: &[u8] = b"EncryptionKeyPair";
const SIGNATURE_KEY_PAIR_LABEL: &[u8] = b"SignatureKeyPair";
const EPOCH_KEY_PAIRS_LABEL: &[u8] = b"EpochKeyPairs";
const TREE_LABEL: &[u8] = b"Tree";
const GROUP_CONTEXT_LABEL: &[u8] = b"GroupContext";
const INTERIM_TRANSCRIPT_HASH_LABEL: &[u8] = b"InterimTranscriptHash";
const CONFIRMATION_TAG_LABEL: &[u8] = b"ConfirmationTag";
const JOIN_CONFIG_LABEL: &[u8] = b"MlsGroupJoinConfig";
const OWN_LEAF_NODES_LABEL: &[u8] = b"OwnLeafNodes";
const GROUP_STATE_LABEL: &[u8] = b"GroupState";
const QUEUED_PROPOSAL_LABEL: &[u8] = b"QueuedProposal";
const PROPOSAL_QUEUE_REFS_LABEL: &[u8] = b"ProposalQueueRefs";
const OWN_LEAF_NODE_INDEX_LABEL: &[u8] = b"OwnLeafNodeIndex";
const EPOCH_SECRETS_LABEL: &[u8] = b"EpochSecrets";
const RESUMPTION_PSK_STORE_LABEL: &[u8] = b"ResumptionPsk";
const MESSAGE_SECRETS_LABEL: &[u8] = b"MessageSecrets";

// ═══════════════════════════════════════════════════════════════
// SNAPSHOT STORAGE PROVIDER
// ═══════════════════════════════════════════════════════════════

pub struct SnapshotStorageProvider {
    initial: HashMap<Vec<u8>, Vec<u8>>,
    current: Mutex<HashMap<Vec<u8>, Vec<u8>>>,
}

impl Drop for SnapshotStorageProvider {
    fn drop(&mut self) {
        for (_k, v) in self.initial.drain() {
            let mut v = v;
            v.zeroize();
        }
        for (_k, v) in self.current.get_mut().drain() {
            let mut v = v;
            v.zeroize();
        }
    }
}

impl SnapshotStorageProvider {
    /// Create a snapshot from DB entries.
    pub fn from_entries(entries: Vec<(Vec<u8>, Vec<u8>)>) -> Self {
        let initial: HashMap<Vec<u8>, Vec<u8>> = entries.into_iter().collect();
        let current = Mutex::new(initial.clone());
        Self { initial, current }
    }

    /// Diff initial vs current to produce StorageUpdates.
    pub fn into_updates(mut self) -> StorageUpdates {
        let mut upserts = Vec::new();
        let mut deletes = Vec::new();
        let current = self.current.get_mut();

        // Find new or changed entries.
        for (key, value) in current.iter() {
            match self.initial.get(key) {
                Some(old_value) if old_value == value => {} // unchanged
                _ => upserts.push((key.clone(), value.clone())),
            }
        }

        // Find deleted entries.
        for key in self.initial.keys() {
            if !current.contains_key(key) {
                deletes.push(key.clone());
            }
        }

        // Zeroize before dropping.
        for (_k, v) in self.initial.drain() {
            let mut v = v;
            v.zeroize();
        }
        for (_k, v) in current.drain() {
            let mut v = v;
            v.zeroize();
        }

        StorageUpdates { upserts, deletes }
    }
}

// ═══════════════════════════════════════════════════════════════
// INTERNAL HELPERS
// ═══════════════════════════════════════════════════════════════

/// Build composite key: `[label || key_bytes || version_be_u16]`
fn build_key<const V: u16>(label: &[u8], key_bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(label.len() + key_bytes.len() + 2);
    out.extend_from_slice(label);
    out.extend_from_slice(key_bytes);
    out.extend_from_slice(&u16::to_be_bytes(V));
    out
}

/// Serialize a key via serde_json, then build the composite storage key.
fn build_key_serde<const V: u16>(
    label: &[u8],
    key: &impl serde::Serialize,
) -> Result<Vec<u8>, SnapshotStorageError> {
    let key_bytes =
        serde_json::to_vec(key).map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
    Ok(build_key::<V>(label, &key_bytes))
}

/// Build composite key for epoch key pairs (group_id + epoch + leaf_index).
fn build_epoch_key<const V: u16>(
    group_id: &impl serde::Serialize,
    epoch: &impl serde::Serialize,
    leaf_index: u32,
) -> Result<Vec<u8>, SnapshotStorageError> {
    let mut key_bytes = serde_json::to_vec(group_id)
        .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
    key_bytes.extend_from_slice(
        &serde_json::to_vec(epoch)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
    );
    key_bytes.extend_from_slice(
        &serde_json::to_vec(&leaf_index)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
    );
    Ok(build_key::<V>(EPOCH_KEY_PAIRS_LABEL, &key_bytes))
}

impl SnapshotStorageProvider {
    // -- low-level operations --

    fn kv_write(&self, key: Vec<u8>, value: Vec<u8>) {
        if let Some(mut previous) = self.current.lock().insert(key, value) {
            previous.zeroize();
        }
    }

    fn kv_read(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.current.lock().get(key).cloned()
    }

    fn kv_delete(&self, key: &[u8]) {
        if let Some(mut removed) = self.current.lock().remove(key) {
            removed.zeroize();
        }
    }

    // -- higher-level helpers --

    fn write_val<const V: u16>(
        &self,
        label: &[u8],
        key: &impl serde::Serialize,
        value: &impl serde::Serialize,
    ) -> Result<(), SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        let val_bytes = serde_json::to_vec(value)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.kv_write(storage_key, val_bytes);
        Ok(())
    }

    fn read_val<const V: u16, Val: serde::de::DeserializeOwned>(
        &self,
        label: &[u8],
        key: &impl serde::Serialize,
    ) -> Result<Option<Val>, SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        match self.kv_read(&storage_key) {
            Some(bytes) => {
                let val = serde_json::from_slice(&bytes)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
                Ok(Some(val))
            }
            None => Ok(None),
        }
    }

    fn delete_val<const V: u16>(
        &self,
        label: &[u8],
        key: &impl serde::Serialize,
    ) -> Result<(), SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        self.kv_delete(&storage_key);
        Ok(())
    }

    fn append_to_list<const V: u16>(
        &self,
        label: &[u8],
        key: &impl serde::Serialize,
        item: Vec<u8>,
    ) -> Result<(), SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        let mut list: Vec<Vec<u8>> = match self.kv_read(&storage_key) {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            None => Vec::new(),
        };
        list.push(item);
        let val_bytes = serde_json::to_vec(&list)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.kv_write(storage_key, val_bytes);
        Ok(())
    }

    fn read_list<const V: u16, Val: serde::de::DeserializeOwned>(
        &self,
        label: &[u8],
        key: &impl serde::Serialize,
    ) -> Result<Vec<Val>, SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        match self.kv_read(&storage_key) {
            Some(bytes) => {
                let raw_list: Vec<Vec<u8>> = serde_json::from_slice(&bytes)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
                let mut result = Vec::with_capacity(raw_list.len());
                for item_bytes in raw_list {
                    let item: Val = serde_json::from_slice(&item_bytes)
                        .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
                    result.push(item);
                }
                Ok(result)
            }
            None => Ok(Vec::new()),
        }
    }

    fn remove_from_list<const V: u16>(
        &self,
        label: &[u8],
        key: &impl serde::Serialize,
        item: Vec<u8>,
    ) -> Result<(), SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        let mut list: Vec<Vec<u8>> = match self.kv_read(&storage_key) {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            None => return Ok(()),
        };
        if let Some(pos) = list.iter().position(|x| *x == item) {
            list.remove(pos);
        }
        let val_bytes = serde_json::to_vec(&list)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.kv_write(storage_key, val_bytes);
        Ok(())
    }
}

// ═══════════════════════════════════════════════════════════════
// STORAGE PROVIDER TRAIT IMPLEMENTATION
// ═══════════════════════════════════════════════════════════════

impl StorageProvider<{ CURRENT_VERSION }> for SnapshotStorageProvider {
    type Error = SnapshotStorageError;

    // ═══════════════════════════════════════════════════════════
    // A. WRITERS — GROUP STATE
    // ═══════════════════════════════════════════════════════════

    fn write_mls_join_config<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        config: &MlsGroupJoinConfig,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(JOIN_CONFIG_LABEL, group_id, config)
    }

    fn append_own_leaf_node<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        LeafNode: traits::LeafNode<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        leaf_node: &LeafNode,
    ) -> Result<(), Self::Error> {
        let item = serde_json::to_vec(leaf_node)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.append_to_list::<{ CURRENT_VERSION }>(OWN_LEAF_NODES_LABEL, group_id, item)
    }

    fn queue_proposal<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ProposalRef: traits::ProposalRef<{ CURRENT_VERSION }>,
        QueuedProposal: traits::QueuedProposal<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
        proposal: &QueuedProposal,
    ) -> Result<(), Self::Error> {
        let composite_key = (
            serde_json::to_value(group_id)
                .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            serde_json::to_value(proposal_ref)
                .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
        );
        self.write_val::<{ CURRENT_VERSION }>(QUEUED_PROPOSAL_LABEL, &composite_key, proposal)?;

        let ref_bytes = serde_json::to_vec(proposal_ref)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.append_to_list::<{ CURRENT_VERSION }>(PROPOSAL_QUEUE_REFS_LABEL, group_id, ref_bytes)
    }

    fn write_tree<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        TreeSync: traits::TreeSync<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        tree: &TreeSync,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(TREE_LABEL, group_id, tree)
    }

    fn write_interim_transcript_hash<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        InterimTranscriptHash: traits::InterimTranscriptHash<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        interim_transcript_hash: &InterimTranscriptHash,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(
            INTERIM_TRANSCRIPT_HASH_LABEL,
            group_id,
            interim_transcript_hash,
        )
    }

    fn write_context<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        GroupContext: traits::GroupContext<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        group_context: &GroupContext,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(GROUP_CONTEXT_LABEL, group_id, group_context)
    }

    fn write_confirmation_tag<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ConfirmationTag: traits::ConfirmationTag<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        confirmation_tag: &ConfirmationTag,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(CONFIRMATION_TAG_LABEL, group_id, confirmation_tag)
    }

    fn write_group_state<
        GroupState: traits::GroupState<{ CURRENT_VERSION }>,
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        group_state: &GroupState,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(GROUP_STATE_LABEL, group_id, group_state)
    }

    fn write_message_secrets<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        MessageSecrets: traits::MessageSecrets<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        message_secrets: &MessageSecrets,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(MESSAGE_SECRETS_LABEL, group_id, message_secrets)
    }

    fn write_resumption_psk_store<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ResumptionPskStore: traits::ResumptionPskStore<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        resumption_psk_store: &ResumptionPskStore,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(
            RESUMPTION_PSK_STORE_LABEL,
            group_id,
            resumption_psk_store,
        )
    }

    fn write_own_leaf_index<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        LeafNodeIndex: traits::LeafNodeIndex<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        own_leaf_index: &LeafNodeIndex,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(OWN_LEAF_NODE_INDEX_LABEL, group_id, own_leaf_index)
    }

    fn write_group_epoch_secrets<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        GroupEpochSecrets: traits::GroupEpochSecrets<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        group_epoch_secrets: &GroupEpochSecrets,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(EPOCH_SECRETS_LABEL, group_id, group_epoch_secrets)
    }

    // ═══════════════════════════════════════════════════════════
    // B. WRITERS — CRYPTO OBJECTS
    // ═══════════════════════════════════════════════════════════

    fn write_signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<{ CURRENT_VERSION }>,
        SignatureKeyPair: traits::SignatureKeyPair<{ CURRENT_VERSION }>,
    >(
        &self,
        public_key: &SignaturePublicKey,
        signature_key_pair: &SignatureKeyPair,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(
            SIGNATURE_KEY_PAIR_LABEL,
            public_key,
            signature_key_pair,
        )
    }

    fn write_encryption_key_pair<
        EncryptionKey: traits::EncryptionKey<{ CURRENT_VERSION }>,
        HpkeKeyPair: traits::HpkeKeyPair<{ CURRENT_VERSION }>,
    >(
        &self,
        public_key: &EncryptionKey,
        key_pair: &HpkeKeyPair,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(ENCRYPTION_KEY_PAIR_LABEL, public_key, key_pair)
    }

    fn write_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        EpochKey: traits::EpochKey<{ CURRENT_VERSION }>,
        HpkeKeyPair: traits::HpkeKeyPair<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
        key_pairs: &[HpkeKeyPair],
    ) -> Result<(), Self::Error> {
        let storage_key = build_epoch_key::<{ CURRENT_VERSION }>(group_id, epoch, leaf_index)?;
        let val_bytes = serde_json::to_vec(key_pairs)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.kv_write(storage_key, val_bytes);
        Ok(())
    }

    fn write_key_package<
        HashReference: traits::HashReference<{ CURRENT_VERSION }>,
        KeyPackage: traits::KeyPackage<{ CURRENT_VERSION }>,
    >(
        &self,
        hash_ref: &HashReference,
        key_package: &KeyPackage,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(KEY_PACKAGE_LABEL, hash_ref, key_package)
    }

    fn write_psk<
        PskId: traits::PskId<{ CURRENT_VERSION }>,
        PskBundle: traits::PskBundle<{ CURRENT_VERSION }>,
    >(
        &self,
        psk_id: &PskId,
        psk: &PskBundle,
    ) -> Result<(), Self::Error> {
        self.write_val::<{ CURRENT_VERSION }>(PSK_LABEL, psk_id, psk)
    }

    // ═══════════════════════════════════════════════════════════
    // C. READERS — GROUP STATE
    // ═══════════════════════════════════════════════════════════

    fn mls_group_join_config<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MlsGroupJoinConfig>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(JOIN_CONFIG_LABEL, group_id)
    }

    fn own_leaf_nodes<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        LeafNode: traits::LeafNode<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<LeafNode>, Self::Error> {
        self.read_list::<{ CURRENT_VERSION }, _>(OWN_LEAF_NODES_LABEL, group_id)
    }

    fn queued_proposal_refs<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ProposalRef: traits::ProposalRef<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<ProposalRef>, Self::Error> {
        self.read_list::<{ CURRENT_VERSION }, _>(PROPOSAL_QUEUE_REFS_LABEL, group_id)
    }

    fn queued_proposals<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ProposalRef: traits::ProposalRef<{ CURRENT_VERSION }>,
        QueuedProposal: traits::QueuedProposal<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<(ProposalRef, QueuedProposal)>, Self::Error> {
        let refs: Vec<ProposalRef> =
            self.read_list::<{ CURRENT_VERSION }, _>(PROPOSAL_QUEUE_REFS_LABEL, group_id)?;
        let mut result = Vec::with_capacity(refs.len());
        for prop_ref in refs {
            let composite_key = (
                serde_json::to_value(group_id)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
                serde_json::to_value(&prop_ref)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            );
            if let Some(proposal) = self.read_val::<{ CURRENT_VERSION }, QueuedProposal>(
                QUEUED_PROPOSAL_LABEL,
                &composite_key,
            )? {
                result.push((prop_ref, proposal));
            }
        }
        Ok(result)
    }

    fn tree<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        TreeSync: traits::TreeSync<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<TreeSync>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(TREE_LABEL, group_id)
    }

    fn group_context<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        GroupContext: traits::GroupContext<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupContext>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(GROUP_CONTEXT_LABEL, group_id)
    }

    fn interim_transcript_hash<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        InterimTranscriptHash: traits::InterimTranscriptHash<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<InterimTranscriptHash>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id)
    }

    fn confirmation_tag<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ConfirmationTag: traits::ConfirmationTag<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ConfirmationTag>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(CONFIRMATION_TAG_LABEL, group_id)
    }

    fn group_state<
        GroupState: traits::GroupState<{ CURRENT_VERSION }>,
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupState>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(GROUP_STATE_LABEL, group_id)
    }

    fn message_secrets<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        MessageSecrets: traits::MessageSecrets<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MessageSecrets>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(MESSAGE_SECRETS_LABEL, group_id)
    }

    fn resumption_psk_store<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ResumptionPskStore: traits::ResumptionPskStore<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ResumptionPskStore>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(RESUMPTION_PSK_STORE_LABEL, group_id)
    }

    fn own_leaf_index<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        LeafNodeIndex: traits::LeafNodeIndex<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<LeafNodeIndex>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(OWN_LEAF_NODE_INDEX_LABEL, group_id)
    }

    fn group_epoch_secrets<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        GroupEpochSecrets: traits::GroupEpochSecrets<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupEpochSecrets>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(EPOCH_SECRETS_LABEL, group_id)
    }

    // ═══════════════════════════════════════════════════════════
    // D. READERS — CRYPTO OBJECTS
    // ═══════════════════════════════════════════════════════════

    fn signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<{ CURRENT_VERSION }>,
        SignatureKeyPair: traits::SignatureKeyPair<{ CURRENT_VERSION }>,
    >(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<Option<SignatureKeyPair>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(SIGNATURE_KEY_PAIR_LABEL, public_key)
    }

    fn encryption_key_pair<
        HpkeKeyPair: traits::HpkeKeyPair<{ CURRENT_VERSION }>,
        EncryptionKey: traits::EncryptionKey<{ CURRENT_VERSION }>,
    >(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<Option<HpkeKeyPair>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(ENCRYPTION_KEY_PAIR_LABEL, public_key)
    }

    fn encryption_epoch_key_pairs<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        EpochKey: traits::EpochKey<{ CURRENT_VERSION }>,
        HpkeKeyPair: traits::HpkeKeyPair<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<Vec<HpkeKeyPair>, Self::Error> {
        let storage_key = build_epoch_key::<{ CURRENT_VERSION }>(group_id, epoch, leaf_index)?;
        match self.kv_read(&storage_key) {
            Some(bytes) => {
                let val: Vec<HpkeKeyPair> = serde_json::from_slice(&bytes)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
                Ok(val)
            }
            None => Ok(Vec::new()),
        }
    }

    fn key_package<
        KeyPackageRef: traits::HashReference<{ CURRENT_VERSION }>,
        KeyPackage: traits::KeyPackage<{ CURRENT_VERSION }>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<Option<KeyPackage>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(KEY_PACKAGE_LABEL, hash_ref)
    }

    fn psk<
        PskBundle: traits::PskBundle<{ CURRENT_VERSION }>,
        PskId: traits::PskId<{ CURRENT_VERSION }>,
    >(
        &self,
        psk_id: &PskId,
    ) -> Result<Option<PskBundle>, Self::Error> {
        self.read_val::<{ CURRENT_VERSION }, _>(PSK_LABEL, psk_id)
    }

    // ═══════════════════════════════════════════════════════════
    // E. DELETERS — GROUP STATE
    // ═══════════════════════════════════════════════════════════

    fn remove_proposal<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ProposalRef: traits::ProposalRef<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
    ) -> Result<(), Self::Error> {
        let composite_key = (
            serde_json::to_value(group_id)
                .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            serde_json::to_value(proposal_ref)
                .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
        );
        self.delete_val::<{ CURRENT_VERSION }>(QUEUED_PROPOSAL_LABEL, &composite_key)?;

        let ref_bytes = serde_json::to_vec(proposal_ref)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        self.remove_from_list::<{ CURRENT_VERSION }>(PROPOSAL_QUEUE_REFS_LABEL, group_id, ref_bytes)
    }

    fn delete_own_leaf_nodes<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(OWN_LEAF_NODES_LABEL, group_id)
    }

    fn delete_group_config<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(JOIN_CONFIG_LABEL, group_id)
    }

    fn delete_tree<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(TREE_LABEL, group_id)
    }

    fn delete_confirmation_tag<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(CONFIRMATION_TAG_LABEL, group_id)
    }

    fn delete_group_state<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(GROUP_STATE_LABEL, group_id)
    }

    fn delete_context<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(GROUP_CONTEXT_LABEL, group_id)
    }

    fn delete_interim_transcript_hash<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id)
    }

    fn delete_message_secrets<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(MESSAGE_SECRETS_LABEL, group_id)
    }

    fn delete_all_resumption_psk_secrets<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(RESUMPTION_PSK_STORE_LABEL, group_id)
    }

    fn delete_own_leaf_index<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(OWN_LEAF_NODE_INDEX_LABEL, group_id)
    }

    fn delete_group_epoch_secrets<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(EPOCH_SECRETS_LABEL, group_id)
    }

    fn clear_proposal_queue<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ProposalRef: traits::ProposalRef<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        let refs: Vec<ProposalRef> =
            self.read_list::<{ CURRENT_VERSION }, _>(PROPOSAL_QUEUE_REFS_LABEL, group_id)?;
        for prop_ref in &refs {
            let composite_key = (
                serde_json::to_value(group_id)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
                serde_json::to_value(prop_ref)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            );
            self.delete_val::<{ CURRENT_VERSION }>(QUEUED_PROPOSAL_LABEL, &composite_key)?;
        }
        self.delete_val::<{ CURRENT_VERSION }>(PROPOSAL_QUEUE_REFS_LABEL, group_id)
    }

    // ═══════════════════════════════════════════════════════════
    // F. DELETERS — CRYPTO OBJECTS
    // ═══════════════════════════════════════════════════════════

    fn delete_signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<{ CURRENT_VERSION }>,
    >(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(SIGNATURE_KEY_PAIR_LABEL, public_key)
    }

    fn delete_encryption_key_pair<EncryptionKey: traits::EncryptionKey<{ CURRENT_VERSION }>>(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(ENCRYPTION_KEY_PAIR_LABEL, public_key)
    }

    fn delete_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        EpochKey: traits::EpochKey<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<(), Self::Error> {
        let storage_key = build_epoch_key::<{ CURRENT_VERSION }>(group_id, epoch, leaf_index)?;
        self.kv_delete(&storage_key);
        Ok(())
    }

    fn delete_key_package<KeyPackageRef: traits::HashReference<{ CURRENT_VERSION }>>(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(KEY_PACKAGE_LABEL, hash_ref)
    }

    fn delete_psk<PskKey: traits::PskId<{ CURRENT_VERSION }>>(
        &self,
        psk_id: &PskKey,
    ) -> Result<(), Self::Error> {
        self.delete_val::<{ CURRENT_VERSION }>(PSK_LABEL, psk_id)
    }
}

// ═══════════════════════════════════════════════════════════════
// SNAPSHOT OPENMLS PROVIDER (crypto + snapshot storage)
// ═══════════════════════════════════════════════════════════════

pub struct SnapshotOpenMlsProvider {
    crypto: crate::hybrid_crypto::HybridCrypto,
    storage: SnapshotStorageProvider,
}

impl SnapshotOpenMlsProvider {
    pub fn new(storage: SnapshotStorageProvider) -> Self {
        Self {
            crypto: crate::hybrid_crypto::HybridCrypto::new(),
            storage,
        }
    }

    /// Extract the storage provider for diffing.
    pub fn into_storage(self) -> SnapshotStorageProvider {
        self.storage
    }
}

impl OpenMlsProvider for SnapshotOpenMlsProvider {
    type CryptoProvider = crate::hybrid_crypto::HybridCrypto;
    type RandProvider = crate::hybrid_crypto::HybridCrypto;
    type StorageProvider = SnapshotStorageProvider;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unchanged_snapshot_has_no_updates() {
        let provider =
            SnapshotStorageProvider::from_entries(vec![(b"key".to_vec(), b"value".to_vec())]);

        let updates = provider.into_updates();
        assert!(updates.upserts.is_empty());
        assert!(updates.deletes.is_empty());
    }

    #[test]
    fn snapshot_reads_its_own_writes_and_deletes() {
        let provider = SnapshotStorageProvider::from_entries(Vec::new());

        provider.kv_write(b"key".to_vec(), b"value".to_vec());
        assert_eq!(provider.kv_read(b"key"), Some(b"value".to_vec()));

        provider.kv_delete(b"key");
        assert_eq!(provider.kv_read(b"key"), None);
    }

    #[test]
    fn snapshot_reports_upserts_and_deletes() {
        let provider = SnapshotStorageProvider::from_entries(vec![
            (b"changed".to_vec(), b"old".to_vec()),
            (b"deleted".to_vec(), b"old".to_vec()),
        ]);
        provider.kv_write(b"changed".to_vec(), b"new".to_vec());
        provider.kv_write(b"created".to_vec(), b"new".to_vec());
        provider.kv_delete(b"deleted");

        let mut updates = provider.into_updates();
        updates.upserts.sort_by(|left, right| left.0.cmp(&right.0));
        updates.deletes.sort();

        assert_eq!(
            updates.upserts,
            vec![
                (b"changed".to_vec(), b"new".to_vec()),
                (b"created".to_vec(), b"new".to_vec()),
            ]
        );
        assert_eq!(updates.deletes, vec![b"deleted".to_vec()]);
    }
}
