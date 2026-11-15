module Core = Yeokcham_v1_model.Core

type error =
  | Invalid of string
  | Choice of string
  | Policy of string
  | Content of Yeokcham_v1_composition.error
  | Metadata of string

val error_to_string : error -> string

type result = {
  publication : Yeokcham_v1_store.Local.publication option;
  change : Core.Change_id.t option;
  revision : Core.Record_id.t option;
  title : string;
  source : Core.History_id.t;
  observed : Core.Object_id.t;
  base_snapshot : Core.Object_id.t;
  public_snapshot : Core.Object_id.t;
  contributed_paths : string list list;
  public_paths : string list list;
  captures_unsaved : bool;
  preview : bool;
  repeated : bool;
}

type prepared

val prepare :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  observed:Yeokcham_v1_model.Snapshot_id.t ->
  observation:Yeokcham_snapshot.Observation.t ->
  paths:string list list ->
  update:Core.Change_id.t option ->
  title:string option ->
  (prepared, error) Stdlib.result

val preview : prepared -> result

val stage :
  store:Yeokcham_store.repository ->
  signing_capability:Yeokcham_v1_trust.signing_capability ->
  prepared ->
  ( Yeokcham_v1_model.project
    * Yeokcham_v1_undo.t
    * Yeokcham_v1_store.Local.t
    * result,
    error )
  Stdlib.result
(** Stages a signed revision and its scoped private receipt. The service must
    publish these together with history/project under its current writer lock.
*)
