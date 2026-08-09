(** Create-only publication of verified ADR-048 records into a V2 root.

    The adapter writes raw ADR-045 envelopes at ADR-046 opaque addresses. It
    owns no mutable ref, plaintext index, private key, trust policy, or repair
    action. *)

module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

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
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_object_path of string
  | Envelope_error of Envelope.error
  | Address_error of Address.error
  | Ledger_error of Ledger.error
  | Unknown_signer of Ledger.Signer_key_id.t
  | Object_collision of Model.Opaque_object_ref.t

val error_to_string : error -> string

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  address_key:Address.key ->
  encryption_key:Envelope.key ->
  public_keys:Ledger.public_key_registry ->
  (repository, error) result

val object_path : repository -> Model.Opaque_object_ref.t -> string
val publish : repository -> envelope:Envelope.t -> (publication, error) result

val load :
  repository ->
  object_ref:Model.Opaque_object_ref.t ->
  (Ledger.verified, error) result
