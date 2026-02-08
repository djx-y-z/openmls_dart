//! Group configuration for OpenMLS.

use openmls::prelude::*;

use super::types::{ciphersuite_to_native, wire_format_to_native, MlsCiphersuite, MlsWireFormatPolicy};

/// Group configuration parameters.
///
/// This is a plain data struct (transparent to FRB) — Dart can create/modify directly.
pub struct MlsGroupConfig {
    pub ciphersuite: MlsCiphersuite,
    pub wire_format_policy: MlsWireFormatPolicy,
    pub use_ratchet_tree_extension: bool,
    pub max_past_epochs: u32,
    pub padding_size: u32,
    pub sender_ratchet_max_out_of_order: u32,
    pub sender_ratchet_max_forward_distance: u32,
    /// How many past resumption PSKs to keep (0 = none).
    pub number_of_resumption_psks: u32,
}

impl MlsGroupConfig {
    /// Create a default configuration for the given ciphersuite.
    #[flutter_rust_bridge::frb(sync)]
    pub fn default_config(ciphersuite: MlsCiphersuite) -> MlsGroupConfig {
        MlsGroupConfig {
            ciphersuite,
            wire_format_policy: MlsWireFormatPolicy::Ciphertext,
            use_ratchet_tree_extension: true,
            max_past_epochs: 0,
            padding_size: 0,
            sender_ratchet_max_out_of_order: 5,
            sender_ratchet_max_forward_distance: 1000,
            number_of_resumption_psks: 0,
        }
    }

    pub(crate) fn to_create_config(&self) -> MlsGroupCreateConfig {
        let cs = ciphersuite_to_native(&self.ciphersuite);
        let wf = wire_format_to_native(&self.wire_format_policy);
        MlsGroupCreateConfig::builder()
            .ciphersuite(cs)
            .wire_format_policy(wf)
            .use_ratchet_tree_extension(self.use_ratchet_tree_extension)
            .max_past_epochs(self.max_past_epochs as usize)
            .padding_size(self.padding_size as usize)
            .number_of_resumption_psks(self.number_of_resumption_psks as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                self.sender_ratchet_max_out_of_order,
                self.sender_ratchet_max_forward_distance,
            ))
            .build()
    }

    pub(crate) fn to_join_config(&self) -> MlsGroupJoinConfig {
        let wf = wire_format_to_native(&self.wire_format_policy);
        MlsGroupJoinConfig::builder()
            .wire_format_policy(wf)
            .use_ratchet_tree_extension(self.use_ratchet_tree_extension)
            .max_past_epochs(self.max_past_epochs as usize)
            .padding_size(self.padding_size as usize)
            .number_of_resumption_psks(self.number_of_resumption_psks as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                self.sender_ratchet_max_out_of_order,
                self.sender_ratchet_max_forward_distance,
            ))
            .build()
    }
}
