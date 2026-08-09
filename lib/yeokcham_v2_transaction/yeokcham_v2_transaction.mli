(** Canonical local recovery records from ADR-049.

    Prepare and commit records describe encrypted immutable candidates only.
    They establish neither a mutable ref nor trust, authorization, or history.
*)

module Repository_id = Yeokcham_v2_model.Repository_id
module Transaction_id = Yeokcham_v2_model.Transaction_id
module Opaque_object_ref = Yeokcham_v2_model.Opaque_object_ref
module Envelope = Yeokcham_v2_envelope

type staged
type prepare
type commit

type journal_file =
  | Prepare_file of Transaction_id.t
  | Commit_file of Transaction_id.t

type error =
  | Empty_staged_objects
  | Too_many_staged_objects of int
  | Prepare_too_large of int
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_prepare_schema_version of int64
  | Unsupported_commit_schema_version of int64
  | Invalid_payload of string
  | Envelope_error of Envelope.error
  | Duplicate_object_ref of Opaque_object_ref.t
  | Noncanonical_object_ref_order of {
      previous : Opaque_object_ref.t;
      current : Opaque_object_ref.t;
    }
  | Noncanonical_prepare
  | Noncanonical_commit
  | Invalid_prepare_digest_length of int
  | Commit_transaction_mismatch of {
      commit : Transaction_id.t;
      prepare : Transaction_id.t;
    }
  | Commit_prepare_mismatch
  | Invalid_journal_filename of string

val error_to_string : error -> string
val supported_mandatory_features : int64
val max_staged_objects : int
val max_prepare_bytes : int
val max_commit_bytes : int
val stage : object_ref:Opaque_object_ref.t -> envelope:Envelope.t -> staged
val staged_object_ref : staged -> Opaque_object_ref.t
val staged_envelope : staged -> Envelope.t

val make_prepare :
  repository_id:Repository_id.t ->
  transaction_id:Transaction_id.t ->
  mandatory_features:int64 ->
  staged list ->
  (prepare, error) result

val prepare_repository_id : prepare -> Repository_id.t
val prepare_transaction_id : prepare -> Transaction_id.t
val prepare_staged : prepare -> staged list
val encode_prepare : prepare -> string
val decode_prepare : string -> (prepare, error) result
val prepare_digest : prepare -> string
val make_commit : prepare -> commit
val commit_transaction_id : commit -> Transaction_id.t
val commit_prepare_digest : commit -> string
val encode_commit : commit -> string
val decode_commit : string -> (commit, error) result
val validate_commit : prepare:prepare -> commit -> (unit, error) result
val prepare_filename : Transaction_id.t -> string
val commit_filename : Transaction_id.t -> string
val parse_journal_filename : string -> (journal_file, error) result
val is_temporary_journal_filename : string -> bool
