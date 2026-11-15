module Core = Yeokcham_v1_model.Core

type t = {
  operation : Core.Operation_id.t;
  intent : Core.Digest.t;
  revision : Core.Record_id.t;
  publication_branch : Core.Branch_id.t;
  source : Core.History_id.t;
  observed : Core.Object_id.t;
  contributed_scope : Core.Object_id.t;
  title : string;
  witness_root : Yeokcham_store.Stored_object_id.t;
  witnesses : Yeokcham_store.Stored_object_id.t list;
}

val store :
  Yeokcham_store.repository ->
  scope:Core.Repository_id.t ->
  t list ->
  (Yeokcham_store.Stored_object_id.t, string) result

val load :
  Yeokcham_store.repository ->
  scope:Core.Repository_id.t ->
  Yeokcham_store.Stored_object_id.t ->
  (t list, string) result

val validate :
  Yeokcham_store.repository -> Core.pool -> t list -> (unit, string) result

val add :
  random_bytes:(int -> (string, string) result) ->
  Yeokcham_store.repository ->
  Core.pool ->
  branch:Core.Branch_id.t ->
  intent:Core.Digest.t ->
  revision:Core.Record_id.t ->
  source:Core.History_id.t ->
  observed:Core.Object_id.t ->
  contributed_scope:Core.Object_id.t ->
  title:string ->
  t list ->
  (t list * t, string) result

val validate_history : Yeokcham_v1_undo.t -> t list -> (unit, string) result
