(** Pure complete-mark and deterministic encrypted-cache planning from ADR-063.

    The caller supplies authenticated objects and explicit live roots. This
    module has no filesystem, key, clock, ledger-selection, or mutation effect.
*)

module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object

type object_entry
type candidate
type plan

type error =
  | Duplicate_object of Model.Opaque_object_ref.t
  | Missing_object of Model.Opaque_object_ref.t
  | Negative_stored_bytes of {
      object_ref : Model.Opaque_object_ref.t;
      bytes : int64;
    }
  | Size_overflow
  | Negative_cache_budget of int64
  | Invalid_digest_length of { name : string; actual : int }
  | Invalid_plan_id
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_manifest

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64

val object_entry :
  object_ref:Model.Opaque_object_ref.t ->
  object_kind:Object.kind ->
  stored_bytes:int64 ->
  direct_links:Model.Opaque_object_ref.t list ->
  (object_entry, error) result

val object_ref : object_entry -> Model.Opaque_object_ref.t
val object_kind : object_entry -> Object.kind
val stored_bytes : object_entry -> int64
val direct_links : object_entry -> Model.Opaque_object_ref.t list

val mark :
  objects:object_entry list ->
  roots:Model.Opaque_object_ref.t list ->
  (Model.Opaque_object_ref.t list * string, error) result
(** Returns the canonical marked closure and its 32-byte root-set digest. *)

val make_plan :
  objects:object_entry list ->
  roots:Model.Opaque_object_ref.t list ->
  cache_budget_bytes:int64 ->
  (plan, error) result

val plan_id : plan -> string
val root_digest : plan -> string
val cache_budget_bytes : plan -> int64
val total_bytes : plan -> int64
val marked_bytes : plan -> int64
val projected_bytes : plan -> int64
val required_overrun : plan -> int64 option
val marked : plan -> Model.Opaque_object_ref.t list
val candidates : plan -> candidate list
val candidate_object_ref : candidate -> Model.Opaque_object_ref.t
val candidate_kind : candidate -> Object.kind
val candidate_stored_bytes : candidate -> int64
val encode_manifest : plan -> string

val decode_manifest : string -> (plan, error) result
(** [decode_manifest] checks canonical bytes and the domain-separated plan ID.
*)
