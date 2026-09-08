# What this package binds and exposes

This file is pasted into the prompt that writes the CHANGELOG entry for an
upstream dependency bump (`make update-changelog`, and the automatic update pull
request). It is the list that entry is classified against: an upstream change
that cannot be tied to something named here is invisible to this package's
users, and saying otherwise turns somebody else's release notes into a list of
features this package does not have. That is the single most common way this
step goes wrong.

**This file is yours, not the template's.** The template writes it once and never
overwrites it (`_skip_if_exists`), so `copier update` will not touch your edits
and there is no conflict to resolve later.

Three labels here are load-bearing, because the prompt quotes them: the
heading `## Not bound or exposed`, and the two bullet labels `Crates bound:` and
`Exposed surface:`. Keep all three verbatim — rewriting a bullet into prose
leaves the prompt's rule 2 pointing at nothing. Everything else is yours. And
prefer concrete names over categories: a model can check "does this change touch
`HpkeKemType`" and cannot check "does this change touch key management".

## Crates bound and surface exposed

- Crates bound: `openmls`, `openmls_rust_crypto`, `openmls_basic_credential`,
  `openmls_traits`, `openmls_libcrux_crypto` — all five unconditionally, in
  `[dependencies]`. `openmls_libcrux_crypto` is reached for one thing only: the
  X-Wing hybrid post-quantum KEM (`HpkeKemType::XWingKemDraft6`). Everything
  else runs on `openmls_rust_crypto`, so a change confined to libcrux affects
  users only through that ciphersuite.

- Exposed surface — one object, `MlsEngine`, plus the value types its methods
  take and return. Everything below is reachable from Dart through
  `lib/openmls.dart`:
  - **Group lifecycle**: create a group, join from a Welcome, join by external
    commit, inspect a Welcome, delete a group, close the engine.
  - **Membership**: add / remove / swap members, leave, leave via self-remove,
    and the member/leaf accessors (`group_members`, `group_member_at`,
    `group_member_leaf_index`, `group_own_index`, `group_own_leaf_node`).
  - **Proposals and commits**: propose add / remove / self-update / external PSK
    / group-context-extensions / custom, commit to pending proposals, flexible
    commit, merge or clear a pending commit, clear or remove pending proposals.
    Signature-key rotation is exposed in both forms — `self_update_with_new_signer`
    (commit) and `propose_self_update_with_new_signer` (proposal), the latter
    reachable only while openmls's `virtual-clients-draft` feature stays off.
  - **Messages**: `create_message`, `process_message`,
    `process_message_with_inspect`, and the three sync helpers that read a
    serialized `MlsMessage` without a group — group id, epoch, content type.
  - **Key material and exports**: key packages (create, delete), signature keys,
    credentials, `export_secret`, `export_welcome_secret` (the same derivation
    on a `ProcessedWelcome`, before joining), `export_ratchet_tree`,
    `export_group_info`, `export_group_context`, `group_epoch_authenticator`,
    `get_past_resumption_psk`, `group_confirmation_tag`.
  - **Group state and configuration**: epoch, ciphersuite, extensions, active
    flag, `set_configuration`, `update_group_context_extensions`.
  - **Key package validity**: `Lifetime` — both its bounds
    (`KeyPackage::life_time`, read out through `key_package_lifetime`) and its
    comparison against a supplied instant (`Lifetime::validate_with_time`,
    through `check_lifetime_at`). `KeyPackageIn::validate` is on that path, so
    its checks — signature, protocol version, extensions, lifetime — are visible
    to users of this package.
  - **Ciphersuites and crypto types** that appear in those signatures —
    `Ciphersuite`, `HpkeKemType`, credential and extension types. A ciphersuite
    added, removed or renamed upstream is visible here even when nothing else
    changes, because it is named in this package's own API.

## Not bound or exposed

Treat any change here as INVISIBLE to this package's users, and never present it
as a feature or change of this package:

- **Storage**: `openmls_memory_storage` and the `StorageProvider`
  implementations shipped upstream. This package implements its own
  (`SnapshotStorageProvider` over `EncryptedDb` — SQLCipher natively,
  IndexedDB + Web Crypto on WASM), so upstream storage work reaches nothing
  here. Changes to the `StorageProvider` *trait* itself are the exception:
  those land in `openmls_traits`, which is bound, and force this package's
  implementation to move.
- **Delivery service, interop client and the test harness** — `openmls_test`,
  `interop_client`, the delivery-service crates and the fuzzing targets.
- **The book and other documentation** in the upstream repository.
- Any crate in the upstream repository that is not in the bound list above.
