//! SnapshotStorageProvider — HashMap-based OpenMLS StorageProvider.
//!
//! Loaded from an EncryptedDb snapshot, provides sync read/write/delete
//! on an in-memory HashMap. After OpenMLS operations, diff the initial
//! vs current state to produce StorageUpdates for persistence.
//!
//! Key format matches MemoryStorage: `[LABEL || serde_json(key) || VERSION_BE_U16]`

use std::collections::HashMap;
use openmls_traits::storage::{traits, CURRENT_VERSION, StorageProvider};
use openmls_traits::OpenMlsProvider;
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
    current: HashMap<Vec<u8>, Vec<u8>>,
}

impl Drop for SnapshotStorageProvider {
    fn drop(&mut self) {
        for (_k, v) in self.initial.drain() {
            let mut v = v;
            v.zeroize();
        }
        for (_k, v) in self.current.drain() {
            let mut v = v;
            v.zeroize();
        }
    }
}

impl SnapshotStorageProvider {
    /// Create a snapshot from DB entries.
    pub fn from_entries(entries: Vec<(Vec<u8>, Vec<u8>)>) -> Self {
        let initial: HashMap<Vec<u8>, Vec<u8>> = entries.into_iter().collect();
        let current = initial.clone();
        Self { initial, current }
    }

    /// Diff initial vs current to produce StorageUpdates.
    pub fn into_updates(mut self) -> StorageUpdates {
        let mut upserts = Vec::new();
        let mut deletes = Vec::new();

        // Find new or changed entries.
        for (key, value) in &self.current {
            match self.initial.get(key) {
                Some(old_value) if old_value == value => {} // unchanged
                _ => upserts.push((key.clone(), value.clone())),
            }
        }

        // Find deleted entries.
        for key in self.initial.keys() {
            if !self.current.contains_key(key) {
                deletes.push(key.clone());
            }
        }

        // Zeroize before dropping.
        for (_k, v) in self.initial.drain() {
            let mut v = v;
            v.zeroize();
        }
        for (_k, v) in self.current.drain() {
            let mut v = v;
            v.zeroize();
        }
        // Prevent double-zeroize in Drop.
        std::mem::forget(self);

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
    let key_bytes = serde_json::to_vec(key)
        .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
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

    fn kv_write(&mut self, key: Vec<u8>, value: Vec<u8>) {
        self.current.insert(key, value);
    }

    fn kv_read(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.current.get(key).cloned()
    }

    fn kv_delete(&mut self, key: &[u8]) {
        self.current.remove(key);
    }

    // -- higher-level helpers --

    fn write_val<const V: u16>(
        &mut self,
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
        &mut self,
        label: &[u8],
        key: &impl serde::Serialize,
    ) -> Result<(), SnapshotStorageError> {
        let storage_key = build_key_serde::<V>(label, key)?;
        self.kv_delete(&storage_key);
        Ok(())
    }

    fn append_to_list<const V: u16>(
        &mut self,
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
        &mut self,
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
        // Safety: StorageProvider takes &self but we need &mut self.
        // This is sound because SnapshotStorageProvider is never shared across threads.
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(JOIN_CONFIG_LABEL, group_id, config)
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.append_to_list::<{ CURRENT_VERSION }>(OWN_LEAF_NODES_LABEL, group_id, item)
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
            serde_json::to_value(group_id).map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            serde_json::to_value(proposal_ref).map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
        );
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(QUEUED_PROPOSAL_LABEL, &composite_key, proposal)?;

        let ref_bytes = serde_json::to_vec(proposal_ref)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        this.append_to_list::<{ CURRENT_VERSION }>(PROPOSAL_QUEUE_REFS_LABEL, group_id, ref_bytes)
    }

    fn write_tree<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        TreeSync: traits::TreeSync<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        tree: &TreeSync,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(TREE_LABEL, group_id, tree)
    }

    fn write_interim_transcript_hash<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        InterimTranscriptHash: traits::InterimTranscriptHash<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        interim_transcript_hash: &InterimTranscriptHash,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id, interim_transcript_hash)
    }

    fn write_context<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        GroupContext: traits::GroupContext<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        group_context: &GroupContext,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(GROUP_CONTEXT_LABEL, group_id, group_context)
    }

    fn write_confirmation_tag<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ConfirmationTag: traits::ConfirmationTag<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        confirmation_tag: &ConfirmationTag,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(CONFIRMATION_TAG_LABEL, group_id, confirmation_tag)
    }

    fn write_group_state<
        GroupState: traits::GroupState<{ CURRENT_VERSION }>,
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        group_state: &GroupState,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(GROUP_STATE_LABEL, group_id, group_state)
    }

    fn write_message_secrets<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        MessageSecrets: traits::MessageSecrets<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        message_secrets: &MessageSecrets,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(MESSAGE_SECRETS_LABEL, group_id, message_secrets)
    }

    fn write_resumption_psk_store<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        ResumptionPskStore: traits::ResumptionPskStore<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        resumption_psk_store: &ResumptionPskStore,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(RESUMPTION_PSK_STORE_LABEL, group_id, resumption_psk_store)
    }

    fn write_own_leaf_index<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        LeafNodeIndex: traits::LeafNodeIndex<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        own_leaf_index: &LeafNodeIndex,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(OWN_LEAF_NODE_INDEX_LABEL, group_id, own_leaf_index)
    }

    fn write_group_epoch_secrets<
        GroupId: traits::GroupId<{ CURRENT_VERSION }>,
        GroupEpochSecrets: traits::GroupEpochSecrets<{ CURRENT_VERSION }>,
    >(
        &self,
        group_id: &GroupId,
        group_epoch_secrets: &GroupEpochSecrets,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(EPOCH_SECRETS_LABEL, group_id, group_epoch_secrets)
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(SIGNATURE_KEY_PAIR_LABEL, public_key, signature_key_pair)
    }

    fn write_encryption_key_pair<
        EncryptionKey: traits::EncryptionKey<{ CURRENT_VERSION }>,
        HpkeKeyPair: traits::HpkeKeyPair<{ CURRENT_VERSION }>,
    >(
        &self,
        public_key: &EncryptionKey,
        key_pair: &HpkeKeyPair,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(ENCRYPTION_KEY_PAIR_LABEL, public_key, key_pair)
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.kv_write(storage_key, val_bytes);
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(KEY_PACKAGE_LABEL, hash_ref, key_package)
    }

    fn write_psk<
        PskId: traits::PskId<{ CURRENT_VERSION }>,
        PskBundle: traits::PskBundle<{ CURRENT_VERSION }>,
    >(
        &self,
        psk_id: &PskId,
        psk: &PskBundle,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.write_val::<{ CURRENT_VERSION }>(PSK_LABEL, psk_id, psk)
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
            if let Some(proposal) =
                self.read_val::<{ CURRENT_VERSION }, QueuedProposal>(QUEUED_PROPOSAL_LABEL, &composite_key)?
            {
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(QUEUED_PROPOSAL_LABEL, &composite_key)?;

        let ref_bytes = serde_json::to_vec(proposal_ref)
            .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?;
        this.remove_from_list::<{ CURRENT_VERSION }>(PROPOSAL_QUEUE_REFS_LABEL, group_id, ref_bytes)
    }

    fn delete_own_leaf_nodes<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(OWN_LEAF_NODES_LABEL, group_id)
    }

    fn delete_group_config<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(JOIN_CONFIG_LABEL, group_id)
    }

    fn delete_tree<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(TREE_LABEL, group_id)
    }

    fn delete_confirmation_tag<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(CONFIRMATION_TAG_LABEL, group_id)
    }

    fn delete_group_state<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(GROUP_STATE_LABEL, group_id)
    }

    fn delete_context<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(GROUP_CONTEXT_LABEL, group_id)
    }

    fn delete_interim_transcript_hash<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id)
    }

    fn delete_message_secrets<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(MESSAGE_SECRETS_LABEL, group_id)
    }

    fn delete_all_resumption_psk_secrets<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(RESUMPTION_PSK_STORE_LABEL, group_id)
    }

    fn delete_own_leaf_index<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(OWN_LEAF_NODE_INDEX_LABEL, group_id)
    }

    fn delete_group_epoch_secrets<GroupId: traits::GroupId<{ CURRENT_VERSION }>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(EPOCH_SECRETS_LABEL, group_id)
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        for prop_ref in &refs {
            let composite_key = (
                serde_json::to_value(group_id)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
                serde_json::to_value(prop_ref)
                    .map_err(|e| SnapshotStorageError::Serialization(e.to_string()))?,
            );
            this.delete_val::<{ CURRENT_VERSION }>(QUEUED_PROPOSAL_LABEL, &composite_key)?;
        }
        this.delete_val::<{ CURRENT_VERSION }>(PROPOSAL_QUEUE_REFS_LABEL, group_id)
    }

    // ═══════════════════════════════════════════════════════════
    // F. DELETERS — CRYPTO OBJECTS
    // ═══════════════════════════════════════════════════════════

    fn delete_signature_key_pair<SignaturePublicKey: traits::SignaturePublicKey<{ CURRENT_VERSION }>>(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(SIGNATURE_KEY_PAIR_LABEL, public_key)
    }

    fn delete_encryption_key_pair<EncryptionKey: traits::EncryptionKey<{ CURRENT_VERSION }>>(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(ENCRYPTION_KEY_PAIR_LABEL, public_key)
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
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.kv_delete(&storage_key);
        Ok(())
    }

    fn delete_key_package<KeyPackageRef: traits::HashReference<{ CURRENT_VERSION }>>(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(KEY_PACKAGE_LABEL, hash_ref)
    }

    fn delete_psk<PskKey: traits::PskId<{ CURRENT_VERSION }>>(
        &self,
        psk_id: &PskKey,
    ) -> Result<(), Self::Error> {
        #[allow(invalid_reference_casting)]
        let this = unsafe { &mut *(self as *const Self as *mut Self) };
        this.delete_val::<{ CURRENT_VERSION }>(PSK_LABEL, psk_id)
    }
}

// ═══════════════════════════════════════════════════════════════
// SNAPSHOT OPENMLS PROVIDER (crypto + snapshot storage)
// ═══════════════════════════════════════════════════════════════

pub struct SnapshotOpenMlsProvider {
    crypto: openmls_rust_crypto::RustCrypto,
    storage: SnapshotStorageProvider,
}

impl SnapshotOpenMlsProvider {
    pub fn new(storage: SnapshotStorageProvider) -> Self {
        Self {
            crypto: openmls_rust_crypto::RustCrypto::default(),
            storage,
        }
    }

    /// Extract the storage provider for diffing.
    pub fn into_storage(self) -> SnapshotStorageProvider {
        self.storage
    }
}

impl OpenMlsProvider for SnapshotOpenMlsProvider {
    type CryptoProvider = openmls_rust_crypto::RustCrypto;
    type RandProvider = openmls_rust_crypto::RustCrypto;
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
