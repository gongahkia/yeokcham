(** Native Linux Secret Service custody for one V4 Ed25519 signing capability.

    Private bytes are encoded before being sent to [secret-tool] on standard
    input. They never appear in a command argument, V4 object, or package. *)

type error =
  | Secret_service_unavailable
  | Secret_service_locked
  | Secret_missing
  | Secret_conflict
  | Invalid_secret_material
  | Trust_error of Yeokcham_v4_trust.error

val error_to_string : error -> string

val create :
  unit ->
  ( Yeokcham_v4_trust.device * Yeokcham_v4_trust.signing_capability,
    error )
  result

val load :
  Yeokcham_v4_model.Device_id.t ->
  (Yeokcham_v4_trust.signing_capability, error) result
