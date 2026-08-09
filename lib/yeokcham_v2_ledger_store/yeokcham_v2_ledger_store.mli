(** Typed verified ref-ledger view over generic V2 encrypted object storage.

    Every V2 object remains in the opaque create-only namespace. This adapter
    accepts only the ledger frame kind; callers that need a different kind use
    [Yeokcham_v2_object_store]. *)

module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store

type repository

type publication =
  | Published of {
      object_ref : Model.Opaque_object_ref.t;
      event_id : Ledger.Event_id.t;
    }
  | Already_published of {
      object_ref : Model.Opaque_object_ref.t;
      event_id : Ledger.Event_id.t;
    }

type error =
  | Object_store_error of Object_store.error
  | Ledger_object_required of Object.kind
  | Ledger_error of Ledger.error
  | Unknown_signer of Ledger.Signer_key_id.t
  | Repository_mismatch of {
      expected : Model.Repository_id.t;
      actual : Model.Repository_id.t;
    }

val error_to_string : error -> string
val repository_id : repository -> Model.Repository_id.t

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  address_key:Address.key ->
  encryption_key:Envelope.key ->
  public_keys:Ledger.public_key_registry ->
  (repository, error) result

val object_path : repository -> Model.Opaque_object_ref.t -> string

val list_object_refs :
  repository -> (Model.Opaque_object_ref.t list, error) result
(** Lists every canonical opaque object path without decrypting or mutating it.
*)

val validate_envelope :
  repository ->
  envelope:Envelope.t ->
  (Model.Opaque_object_ref.t * Ledger.Event_id.t, error) result
(** Strictly checks one ledger-frame candidate without writing an object. *)

val publish : repository -> envelope:Envelope.t -> (publication, error) result

val load_object :
  repository -> object_ref:Model.Opaque_object_ref.t -> (Object.t, error) result
(** Strictly opens an authenticated typed frame but grants it no ledger result.
*)

val load :
  repository ->
  object_ref:Model.Opaque_object_ref.t ->
  (Ledger.verified, error) result
