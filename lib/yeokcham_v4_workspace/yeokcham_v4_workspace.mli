(** Explicit local materialisation metadata for a verified V4 projection.

    This module is deliberately outside the V4 [Project], authority, package,
    transport, and bootstrap records. Its pure transitions return plans only;
    filesystem adapters must validate a snapshot closure before executing one.
*)

type projection_basis
type workspace_projection_receipt
type observed_tree
type closure = Closure_complete | Closure_missing

type destination =
  | Destination_empty
  | Destination_nonempty
  | Destination_unsafe

type refusal =
  | Nonempty_destination
  | Dirty_workspace
  | Missing_closure
  | No_verified_basis
  | Receipt_mismatch
  | Unsafe_path

type materialization_plan

type update_plan =
  | Already_current of workspace_projection_receipt
  | Update of materialization_plan

type error =
  | Invalid_basis_id of string
  | Invalid_tree_id of string
  | Invalid_source_fingerprint of string
  | Source_fingerprint_mismatch
  | Invalid_generation of int64
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of Yeokcham_encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | Basis_collision of string
  | Io_error of { operation : string; path : string; message : string }

val schema_version : int64
val error_to_string : error -> string
val refusal_to_string : refusal -> string

val make_projection_basis :
  repository:Yeokcham_v4_trust.Repository_id.t ->
  imported_basis_id:string ->
  snapshot:Yeokcham_v4_model.Snapshot_id.t ->
  canonical_tree:string ->
  source_fingerprint:string ->
  (projection_basis, error) result

val basis_repository : projection_basis -> Yeokcham_v4_trust.Repository_id.t
val basis_imported_basis_id : projection_basis -> string
val basis_snapshot : projection_basis -> Yeokcham_v4_model.Snapshot_id.t
val basis_canonical_tree : projection_basis -> string
val basis_source_fingerprint : projection_basis -> string

val make_observed_tree :
  canonical_tree:string ->
  source_fingerprint:string ->
  (observed_tree, error) result

val observed_canonical_tree : observed_tree -> string
val observed_source_fingerprint : observed_tree -> string

val receipt_repository :
  workspace_projection_receipt -> Yeokcham_v4_trust.Repository_id.t

val receipt_imported_basis_id : workspace_projection_receipt -> string

val receipt_snapshot :
  workspace_projection_receipt -> Yeokcham_v4_model.Snapshot_id.t

val receipt_canonical_tree : workspace_projection_receipt -> string
val receipt_activation_generation : workspace_projection_receipt -> int64
val receipt_source_fingerprint : workspace_projection_receipt -> string
val plan_basis : materialization_plan -> projection_basis
val plan_receipt : materialization_plan -> workspace_projection_receipt
val plan_requires_safety_checkpoint : materialization_plan -> bool

val activate :
  basis:projection_basis option ->
  closure:closure ->
  destination:destination ->
  (materialization_plan, refusal) result
(** Produces generation one for an empty, verified destination. *)

val plan_update :
  basis:projection_basis option ->
  receipt:workspace_projection_receipt option ->
  closure:closure ->
  observed:observed_tree ->
  replace:bool ->
  (update_plan, refusal) result
(** A non-replacing update refuses a tree that does not match the receipt.
    Replacing a dirty tree marks the returned plan as requiring a durable safety
    checkpoint before materialisation. *)

val encode_basis : projection_basis -> (string, error) result
val decode_basis : string -> (projection_basis, error) result
val encode_receipt : workspace_projection_receipt -> (string, error) result
val decode_receipt : string -> (workspace_projection_receipt, error) result
val basis_path : root:string -> string
val receipt_path : root:string -> string
val write_basis : root:string -> projection_basis -> (unit, error) result
val read_basis : root:string -> (projection_basis option, error) result

val write_receipt :
  root:string -> workspace_projection_receipt -> (unit, error) result

val read_receipt :
  root:string -> (workspace_projection_receipt option, error) result
