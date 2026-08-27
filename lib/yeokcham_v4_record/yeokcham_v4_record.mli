(** Canonical, versioned persistence records for the V4 pure model.

    This module deliberately serialises only model state. Object storage,
    signing, snapshots, and transport remain adapter concerns. *)

type error =
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of Yeokcham_encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Model_error of Yeokcham_v4_model.error
  | Noncanonical_bytes

val error_to_string : error -> string
val schema_version : int64
val encode_state : Yeokcham_v4_model.state -> (string, error) result
val decode_state : string -> (Yeokcham_v4_model.state, error) result
val encode_project : Yeokcham_v4_model.project -> (string, error) result
val decode_project : string -> (Yeokcham_v4_model.project, error) result

(* Canonical standalone revision bytes used by signed V4 exchange records.
   They are intentionally separate from the mutable project-state encoding. *)
val encode_change_revision :
  Yeokcham_v4_model.change_revision -> (string, error) result

val decode_change_revision :
  string -> (Yeokcham_v4_model.change_revision, error) result
