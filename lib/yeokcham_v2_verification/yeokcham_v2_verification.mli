(** Read-only verification of one V2 encrypted-ledger repository. *)

module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Transaction_store = Yeokcham_v2_transaction_store

type repository

type report = {
  verified_objects : int;
  verified_events : int;
  verified_refs : int;
  causal_heads : int;
  unresolved_divergences : int;
  prepared_transactions : int;
  committed_transactions : int;
}

type error =
  | Ledger_store_error of Ledger_store.error
  | Transaction_store_error of Transaction_store.error
  | Object_error of {
      object_ref : Model.Opaque_object_ref.t;
      path : string;
      error : Ledger_store.error;
    }
  | Causal_error of { ref_name : Ledger.Ref_name.t; error : Ledger.error }

val error_to_string : error -> string

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  address_key:Address.key ->
  encryption_key:Envelope.key ->
  public_keys:Ledger.public_key_registry ->
  (repository, error) result

val verify : repository -> (report, error) result
(** Does not publish, remove, repair, or otherwise mutate objects, refs, or
    journal entries. *)
