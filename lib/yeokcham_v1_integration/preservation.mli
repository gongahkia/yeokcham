module Core = Yeokcham_v1_model.Core

type error = Content of Yeokcham_v1_composition.error | Invalid of string

val error_to_string : error -> string

type t = {
  known_present : Core.Object_id.t;
  workspace_result : Core.Object_id.t;
  contributions : Yeokcham_v1_store.Local.publication list;
}

type basis = {
  known_present : Core.Object_id.t;
  contributions : Yeokcham_v1_store.Local.publication list;
}

val basis :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  represented:Core.Record_id.t list ->
  (basis, error) result

val prepare :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  represented:Core.Record_id.t list ->
  accepted:Yeokcham_v1_composition.tree ->
  observed:Core.Object_id.t ->
  (t, error) result
(** Derive the shared work already present on the selected private lineage from
    exact scoped publication witnesses, then preserve its private continuation.
    Stages only immutable snapshots; accepted/history/ordinary files are
    untouched. *)
