type node = {
  id : int64;
  parent : int64 option;
  snapshot : Yeokcham_v1_model.Snapshot_id.t;
  draft : Yeokcham_v1_model.Draft_id.t;
  created_at : int64;
}
(** Local history of observed workspace states. Node identity is independent of
    snapshot identity. No node is shared, signed, or part of the project model.
*)

type t

val seed :
  snapshot:Yeokcham_v1_model.Snapshot_id.t ->
  draft:Yeokcham_v1_model.Draft_id.t ->
  t
(** Old repositories begin at their known current checkpoint. No ancestry is
    inferred from the old deduplicated checkpoint list. *)

val nodes : t -> node list
(** Nodes in creation order. *)

val current : t -> node
val find : t -> int64 -> (node, string) result
val children : t -> int64 -> node list
val select : t -> int64 -> (t, string) result

val record :
  t ->
  snapshot:Yeokcham_v1_model.Snapshot_id.t ->
  draft:Yeokcham_v1_model.Draft_id.t ->
  created_at:int64 ->
  (t, string) result
(** An unchanged snapshot is a no-op. Returning to earlier contents by editing
    creates a distinct node; selecting an existing node does not. *)

val target_snapshot :
  t ->
  snapshot:Yeokcham_v1_model.Snapshot_id.t ->
  draft:Yeokcham_v1_model.Draft_id.t ->
  created_at:int64 ->
  (t * node, string) result
(** Prefer the nearest matching ancestor, then the newest matching node. A
    legacy/imported checkpoint without history becomes a separate root. The
    current position is not changed. *)

val record_exact :
  t ->
  expected:int64 ->
  snapshot:Yeokcham_v1_model.Snapshot_id.t ->
  draft:Yeokcham_v1_model.Draft_id.t ->
  created_at:int64 ->
  (t, string) result
(** Consumes the exact next sequence and selects a new child even when bytes are
    unchanged. Pure staging only; the state-root commit owns durable allocation.
*)

val encode : t -> (string, string) result
val decode : string -> (t, string) result
val workspace : t -> Yeokcham_v1_model.Core.Workspace_id.t option
val next_sequence : t -> int64 option

val bind_workspace :
  t -> Yeokcham_v1_model.Core.Workspace_id.t -> (t, string) result
(** Bind an unnamespaced current history exactly once without losing ancestry.
    The store generates entropy and publishes this with the existing root. *)

val identity : t -> node -> (Yeokcham_v1_model.Core.History_id.t, string) result

val validate_update : previous:t -> t -> (t, string) result
(** A state-root update may append nodes and move the cursor; it cannot erase
    existing nodes, alter their payloads or reassign a workspace namespace. *)
