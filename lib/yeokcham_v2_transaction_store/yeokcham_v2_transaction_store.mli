(** Durable ADR-049 object-publication transactions.

    This adapter stages only verified encrypted immutable objects. It has no
    mutable ref, trust, authorization, key, or history-selection operation. *)

module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Transaction = Yeokcham_v2_transaction

type repository

type prepare_outcome =
  | Prepared of Transaction.prepare
  | Already_prepared of Transaction.prepare

type commit_outcome = Committed | Already_committed

type recovery_outcome = {
  discarded_prepares : Transaction.Transaction_id.t list;
  completed_transactions : Transaction.Transaction_id.t list;
}

type error =
  | Ledger_store_error of Ledger_store.error
  | Transaction_error of Transaction.error
  | Repository_mismatch of {
      expected : Model.Repository_id.t;
      actual : Model.Repository_id.t;
    }
  | Candidate_address_mismatch of {
      transaction_id : Transaction.Transaction_id.t;
      expected : Model.Opaque_object_ref.t;
      actual : Model.Opaque_object_ref.t;
    }
  | Journal_collision of string
  | Journal_entry_changed of string
  | Stray_commit of Transaction.Transaction_id.t
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_journal_path of string

val error_to_string : error -> string

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  address_key:Address.key ->
  encryption_key:Envelope.key ->
  public_keys:Ledger.public_key_registry ->
  (repository, error) result

val prepare_path : repository -> Transaction.Transaction_id.t -> string
val commit_path : repository -> Transaction.Transaction_id.t -> string

val prepare :
  repository ->
  transaction_id:Transaction.Transaction_id.t ->
  envelopes:Envelope.t list ->
  (prepare_outcome, error) result

val commit :
  repository ->
  transaction_id:Transaction.Transaction_id.t ->
  (commit_outcome, error) result

val recover : repository -> (recovery_outcome, error) result
