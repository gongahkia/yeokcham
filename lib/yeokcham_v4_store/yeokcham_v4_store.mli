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

val error_to_string : error -> string

type repository

type loaded = {
  project : Yeokcham_v4_model.project;
  head : Yeokcham_store.Mutable_ref.t;
  object_id : Yeokcham_store.Stored_object_id.t;
}

val state_head_name : string
val underlying_store : repository -> Yeokcham_store.repository

val init :
  root:string -> project:Yeokcham_v4_model.project -> (repository, error) result

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
