(** Immutable scoped local restore generations. In-place operations bind exact
    snapshots, history position and optional branch selection. Copy-out binds an
    exact target and canonical output directory without navigating source
    history. Both bind separately staged physical plans by digest. *)

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
  safety:Yeokcham_v1_model.Snapshot_id.t ->
  target:Yeokcham_v1_model.Snapshot_id.t ->
  (t, error) result

val make_copyout :
  operation_id:string ->
  target:Yeokcham_v1_model.Snapshot_id.t ->
  digest:string ->
  destination:string ->
  (t, error) result

val destination : t -> string option
(** Schema 4 copy-out scope. Safety equals target because source work is not
    replaced; history and branch fields are absent. *)

val history_node : t -> int64 option

val with_history_node : t -> int64 -> (t, error) result
(** V2 journals bind the exact local history node to resume after interruption.
    Legacy V1 bytes remain readable and unchanged when no node is supplied. *)

val plan : t -> (string * Yeokcham_v1_model.Core.Branch_id.t option) option

val with_plan :
  t ->
  digest:string ->
  selected_branch:Yeokcham_v1_model.Core.Branch_id.t option ->
  (t, error) result
(** V3 binds the exact physical-plan digest and optional branch selection. Every
    journal generation must retain the same operation, node and plan scope. *)

val selection_plan : t -> string option

val with_selection_plan : t -> string -> (t, error) result
(** Schema 5 binds the exact local selection intent for confirmation/retry. This
    is a local CLI plan ID, not review approval or a signed acceptance. *)

val make_selection :
  operation_id:string ->
  safety:Yeokcham_v1_model.Snapshot_id.t ->
  target:Yeokcham_v1_model.Snapshot_id.t ->
  history_node:int64 ->
  digest:string ->
  selected_branch:Yeokcham_v1_model.Core.Branch_id.t option ->
  selection_plan:string ->
  (t, error) result

val requires_source_proof : t -> bool
(** Metadata-only selection has equal snapshots and no destructive source proof;
    schema 5 still journals its exact cursor/branch movement for crash retry. *)

val operation_id : t -> string
val safety : t -> Yeokcham_v1_model.Snapshot_id.t
val target : t -> Yeokcham_v1_model.Snapshot_id.t
val generation : t -> int64
val phase : t -> phase
val advance : t -> phase -> (t, error) result
val encode : t -> (string, error) result
val decode : string -> (t, error) result

val append : root:string -> t -> (unit, error) result
(** Create-only append. Equal existing bytes are an idempotent retry. *)

val scan : root:string -> (t list, error) result
val pending : root:string -> (t list, error) result
val latest_pending : root:string -> (t option, error) result

val pending_snapshots :
  root:string -> (Yeokcham_v1_model.Snapshot_id.t list, error) result
(** Safety and target snapshots named by an incomplete restore operation. *)

val prune_published :
  root:string -> operations:string list -> (string list, error) result
(** Deletes only named operations whose latest generation is [Published]. The
    caller must first establish that another durable root names their snapshots.
*)
