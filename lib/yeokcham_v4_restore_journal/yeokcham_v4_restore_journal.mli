(** Immutable V4 in-place restore journal generations.

    Records name exact V4 snapshots only. They contain no filesystem paths or
    bytes; an adapter re-derives the materialisation plan from the target. *)

type phase = Prepared | Applying | Materialized | Published
type t

type error =
  | Invalid_operation_id of string
  | Identical_snapshots
  | Invalid_generation of int64
  | Invalid_transition of { previous : phase; next : phase }
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of Yeokcham_encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | Journal_collision of string
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string
val schema_version : int64

val make_prepared :
  operation_id:string ->
  safety:Yeokcham_v4_model.Snapshot_id.t ->
  target:Yeokcham_v4_model.Snapshot_id.t ->
  (t, error) result

val operation_id : t -> string
val safety : t -> Yeokcham_v4_model.Snapshot_id.t
val target : t -> Yeokcham_v4_model.Snapshot_id.t
val generation : t -> int64
val phase : t -> phase
val advance : t -> phase -> (t, error) result
val encode : t -> (string, error) result
val decode : string -> (t, error) result

val append : root:string -> t -> (unit, error) result
(** Create-only append. Equal existing bytes are an idempotent retry. *)

val scan : root:string -> (t list, error) result
val latest_pending : root:string -> (t option, error) result
