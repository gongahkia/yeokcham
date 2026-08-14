(** Create-only storage for authenticated typed V2 encrypted objects. *)

module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object

type repository

type publication =
  | Published of Model.Opaque_object_ref.t
  | Already_published of Model.Opaque_object_ref.t

type quarantine_outcome = Quarantined of int64 | Already_quarantined of int64
type prune_outcome = Pruned of int64 | Already_pruned

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_object_path of string
  | Envelope_error of Envelope.error
  | Address_error of Address.error
  | Object_error of Object.error
  | Object_collision of Model.Opaque_object_ref.t
  | Invalid_quarantine_generation of string
  | Quarantine_target_collision of Model.Opaque_object_ref.t
  | Quarantine_candidate_missing of Model.Opaque_object_ref.t
  | Quarantine_candidate_in_other_generation of Model.Opaque_object_ref.t
  | Quarantine_source_still_present of Model.Opaque_object_ref.t
  | Unexpected_object_kind of {
      object_ref : Model.Opaque_object_ref.t;
      expected : Object.kind;
      actual : Object.kind;
    }

val error_to_string : error -> string
val repository_id : repository -> Model.Repository_id.t

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  address_key:Address.key ->
  encryption_key:Envelope.key ->
  (repository, error) result

val seal :
  repository ->
  nonce:Envelope.nonce ->
  Object.t ->
  (Envelope.t, error) result
(** Encrypts one typed repository object using the repository's current object
    epoch and an opaque per-object context commitment. *)

val object_path : repository -> Model.Opaque_object_ref.t -> string

val stored_bytes :
  repository -> object_ref:Model.Opaque_object_ref.t -> (int64, error) result
(** Returns the exact regular-file length of one canonical opaque object. This
    is observation only; it does not decrypt, repair, or rewrite the object. *)

val list_object_refs :
  repository -> (Model.Opaque_object_ref.t list, error) result
(** Lists every canonical opaque object path without decrypting or mutating it.
*)

val validate_envelope :
  repository ->
  envelope:Envelope.t ->
  (Model.Opaque_object_ref.t * Object.t, error) result
(** Strictly checks one typed candidate without writing an object. *)

val publish : repository -> envelope:Envelope.t -> (publication, error) result

val load :
  repository -> object_ref:Model.Opaque_object_ref.t -> (Object.t, error) result

val quarantine_path :
  repository ->
  generation:string ->
  object_ref:Model.Opaque_object_ref.t ->
  (string, error) result
(** Returns the validated local path for an exact generation-specific quarantine
    entry. [generation] is a lowercase hexadecimal ledger-event ID, never an
    untrusted pathname. *)

val quarantine :
  repository ->
  generation:string ->
  object_ref:Model.Opaque_object_ref.t ->
  expected_kind:Object.kind ->
  (quarantine_outcome, error) result
(** Authenticates the source frame and moves it with a no-overwrite hard-link
    then unlink protocol. An already present byte-identical target finishes an
    interrupted move rather than replacing it. *)

val prune_quarantine :
  repository ->
  generation:string ->
  object_ref:Model.Opaque_object_ref.t ->
  expected_kind:Object.kind ->
  (prune_outcome, error) result
(** Irreversibly removes only an authenticated entry already in the named
    generation quarantine. It never removes an object from the live namespace.
*)
