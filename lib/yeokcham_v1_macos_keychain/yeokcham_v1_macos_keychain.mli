(** Native macOS Keychain custody for one V1 Ed25519 signing capability.

    Only public self-certifying device IDs select items. Private bytes are
    generic-password data protected with [WhenUnlockedThisDeviceOnly], never
    repository state. *)

type error =
  | Keychain_unavailable
  | Keychain_locked
  | Keychain_item_missing
  | Keychain_item_conflict
  | Invalid_keychain_material
  | Trust_error of Yeokcham_v1_trust.error

val error_to_string : error -> string

val create :
  unit ->
  ( Yeokcham_v1_trust.device * Yeokcham_v1_trust.signing_capability,
    error )
  result
(** Generates a V1 device key and atomically creates its Keychain item. *)

val load :
  Yeokcham_v1_model.Device_id.t ->
  (Yeokcham_v1_trust.signing_capability, error) result
