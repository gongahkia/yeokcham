(** Immutable, local-only evidence that an in-place restore completed.

    A proof is a durable compaction root for both snapshots named by one
    destructive restore. It is deliberately absent from packages and transport.
*)

type t

type error =
  | Invalid_operation_id of string
  | Identical_snapshots
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of Yeokcham_encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | Proof_collision of string
  | Not_found of string
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string
val schema_version : int64

val make :
  operation_id:string ->
  safety:Yeokcham_v1_model.Snapshot_id.t ->
  target:Yeokcham_v1_model.Snapshot_id.t ->
  (t, error) result

val operation_id : t -> string
val safety : t -> Yeokcham_v1_model.Snapshot_id.t
val target : t -> Yeokcham_v1_model.Snapshot_id.t
val encode : t -> (string, error) result
val decode : string -> (t, error) result

val append : root:string -> t -> (unit, error) result
(** Create-only and idempotent for equal canonical bytes. The proof directory is
    fsynced after creation. *)

val scan : root:string -> (t list, error) result
val find : root:string -> operation_id:string -> (t, error) result

val forget : root:string -> operation_id:string -> (unit, error) result
(** Removes exactly one durable recovery root. It does not delete object bytes.
*)

val snapshots : t list -> Yeokcham_v1_model.Snapshot_id.t list
