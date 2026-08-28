(** Immutable V4 model-state objects and their sole mutable head.

    The store is intentionally not a V3 compatibility layer. V4 initialization
    refuses any pre-existing [.yeokcham] directory. *)

type error =
  | Store_error of Yeokcham_store.error
  | Record_error of Yeokcham_v4_record.error
  | Envelope_error of Yeokcham_envelope.creation_error
  | Existing_repository of string
  | Bootstrap_error of string
  | Missing_state_head
  | Empty_state_head
  | Unexpected_object_type of Yeokcham_envelope.object_type
  | Trust_error of Yeokcham_v4_trust.error
  | Transport_error of Yeokcham_v4_transport.error
  | Invalid_collaboration_state of string
  | Collaborative_state_requires_collaborative_save

val error_to_string : error -> string

type repository

type collaboration
(** Public collaboration state carried atomically with a V4 project. It holds
    only public certificates and detached signed revision records. Local signing
    capabilities deliberately do not belong here. *)

val collaboration :
  membership:Yeokcham_v4_trust.membership ->
  revisions:Yeokcham_v4_trust.signed_revision list ->
  local_certificate:string ->
  (collaboration, error) result
(** Retained only to reject authority-less call paths explicitly. Released V4
    collaboration state always requires [collaboration_with_authority]. *)

val collaboration_with_authority :
  authority:Yeokcham_v4_trust.authority ->
  revisions:Yeokcham_v4_trust.signed_revision list ->
  local_certificate:string ->
  authorizations:Yeokcham_v4_trust.authorization list ->
  adoptions:Yeokcham_v4_trust.adoption list ->
  (collaboration, error) result
(** The V4 lifecycle-aware collaboration state. Every revision is bound to an
    authority epoch; exceptional late arrivals must carry one exact signed
    authorization or adoption record. *)

val collaboration_with_authority_transport :
  transport:Yeokcham_v4_transport.local_state ->
  authority:Yeokcham_v4_trust.authority ->
  revisions:Yeokcham_v4_trust.signed_revision list ->
  local_certificate:string ->
  authorizations:Yeokcham_v4_trust.authorization list ->
  adoptions:Yeokcham_v4_trust.adoption list ->
  (collaboration, error) result

val membership : collaboration -> Yeokcham_v4_trust.membership
val authority : collaboration -> Yeokcham_v4_trust.authority option
val signed_revisions : collaboration -> Yeokcham_v4_trust.signed_revision list
val authorizations : collaboration -> Yeokcham_v4_trust.authorization list
val adoptions : collaboration -> Yeokcham_v4_trust.adoption list
val transport : collaboration -> Yeokcham_v4_transport.local_state
val local_certificate : collaboration -> string

type loaded = {
  project : Yeokcham_v4_model.project;
  collaboration : collaboration option;
  head : Yeokcham_store.Mutable_ref.t;
  object_id : Yeokcham_store.Stored_object_id.t;
}

val state_head_name : string
val underlying_store : repository -> Yeokcham_store.repository

val init :
  root:string -> project:Yeokcham_v4_model.project -> (repository, error) result

val init_collaborative :
  root:string ->
  project:Yeokcham_v4_model.project ->
  collaboration:collaboration ->
  (repository, error) result

val init_collaborative_with :
  root:string ->
  bootstrap:
    (Yeokcham_store.repository ->
    (Yeokcham_v4_model.project * collaboration, string) result) ->
  (repository, error) result
(** The collaboration-aware counterpart to [init_with]. It makes initial
    snapshot capture possible without ever publishing an unsigned state head. *)

val init_with :
  root:string ->
  bootstrap:
    (Yeokcham_store.repository -> (Yeokcham_v4_model.project, string) result) ->
  (repository, error) result
(** Creates the generic immutable store only after refusing existing metadata,
    then asks [bootstrap] for the first V4 project before publishing its head.
    The callback is the only supported way to scan an initial working tree
    without exposing a moment where an existing repository could be adopted. *)

val open_repository : root:string -> (repository, error) result
val load : repository -> (loaded, error) result

val save :
  repository ->
  expected:Yeokcham_store.Mutable_ref.t ->
  project:Yeokcham_v4_model.project ->
  (loaded, error) result
(** Refuses to discard the public signed-collaboration wrapper of the expected
    head. Use [save_collaborative] to preserve and validate that state. *)

val save_collaborative :
  repository ->
  expected:Yeokcham_store.Mutable_ref.t ->
  project:Yeokcham_v4_model.project ->
  collaboration:collaboration ->
  (loaded, error) result
