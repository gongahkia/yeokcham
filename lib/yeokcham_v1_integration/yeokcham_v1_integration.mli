module Preservation = Preservation
module Core = Yeokcham_v1_model.Core

type error =
  | Invalid of string
  | Choice of string
  | Policy of string
  | Content of Yeokcham_v1_composition.error
  | Metadata of string
  | Integrity of string
  | Stale of string

val error_to_string : error -> string

val observation_digest :
  Yeokcham_snapshot.Observation.t -> (Core.Digest.t, error) result
(** Canonical digest of the captured entry/rule/directory identities. *)

type readiness =
  | Ready of Core.composition_result
  | Conflicted of Core.conflict list
  | Decision of string

type t

val prepare :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  observed:Yeokcham_v1_model.Snapshot_id.t ->
  observation:Yeokcham_snapshot.Observation.t ->
  selected_revisions:Core.Record_id.t list ->
  reconcile_heads:Core.Record_id.t list option ->
  (t, error) result
(** Exact immutable preparation from verified domain records and a complete
    filesystem observation. Divergent heads require explicit reconciliation. No
    ordinary file, history cursor, accepted head or outbox is published. *)

val prepare_resolved :
  resolution_ids:Core.Record_id.t list ->
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  observed:Yeokcham_v1_model.Snapshot_id.t ->
  observation:Yeokcham_snapshot.Observation.t ->
  selected_revisions:Core.Record_id.t list ->
  reconcile_heads:Core.Record_id.t list option ->
  (t, error) result
(** Exact immutable preparation from verified domain records and a complete
    filesystem observation. Divergent heads require explicit reconciliation. No
    ordinary file, history cursor, accepted head or outbox is published. *)

val id : t -> Core.Plan_id.t
val stored_id : t -> Yeokcham_store.Stored_object_id.t
val encode : t -> string
val request : t -> Core.composition_request
val event_heads : t -> Core.Record_id.t list
val readiness : t -> readiness
val accepted_snapshot : t -> Core.Object_id.t option
val known_present : t -> Core.Object_id.t
val contributions : t -> Yeokcham_v1_store.Local.publication list
val no_op : t -> bool

val decode :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  string ->
  (t, error) result
(** Bounded canonical control/reference decoding. Ready contents remain a
    proposal; revalidate current inputs before starting an application. *)

val revalidate :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  observed:Yeokcham_v1_model.Snapshot_id.t ->
  observation:Yeokcham_snapshot.Observation.t ->
  t ->
  (t, error) result
(** Freeze this plan's exact chosen revisions and reconcile-head set. Unrelated
    received records are preserved; changed relevant inputs return Stale. *)

val retain : store:Yeokcham_store.repository -> t -> (unit, error) result
(** Create-only private proposal root under the existing retention lock.
    Verifies complete proposed contents first. Does not publish accepted/history
    state. *)

val load :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  Core.Plan_id.t ->
  (t, error) result

val scan :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  (t list, error) result

val retention_roots : t -> Core.Object_id.t list

val revalidate_shared :
  store:Yeokcham_store.repository ->
  loaded:Yeokcham_v1_store.loaded ->
  cursor:Core.History_id.t ->
  t ->
  (unit, error) result
(** Recheck relevant shared inputs and the durable operation's safety cursor
    during resume. Does not inspect a possibly partially materialized live tree.
    Only use after full revalidation and durable operation preparation; this
    narrower check alone never authorizes starting a decoded proposal. *)

val forget :
  store:Yeokcham_store.repository -> Core.Plan_id.t -> (unit, error) result
(** Releases only this immutable proposal alias. Refuses retirement while an
    incomplete durable operation references the plan. Operation roots are also
    protected independently of this alias. *)
