(** Read-only repository inspection. These functions never write an object or
    mutable reference. *)

type storage_bucket =
  | Scratch
  | Capsule
  | Release
  | Chunk
  | Snapshot
  | Workspace
  | Other

type storage_stat = {
  bucket : storage_bucket;
  object_count : int;
  stored_bytes : int64;
}

type storage_report = {
  total_objects : int;
  total_stored_bytes : int64;
  buckets : storage_stat list;
  retained_checkpoints : int;
  retained_checkpoint_object_bytes : int64;
}

type status = {
  scratch_head : Yeokcham_scratch.Checkpoint_id.t option;
  active_generation : Yeokcham_scratch.Generation_id.t option;
  capsule_count : int;
  workspace_count : int;
  release_count : int;
  repository_object_count : int;
}

type timeline_entry = {
  checkpoint : Yeokcham_scratch.Checkpoint_id.t;
  created_at : int64;
  changed_paths : string list;
  snapshot_bytes : int64;
  tags : string list;
  validation_state : string;
  retention : string list;
}

type history_scope =
  | Combined_history
  | Scratch_history
  | Capsule_histories
  | Workspace_history of Yeokcham_id.Workspace_id.t
  | Release_history

type history_graph

type verification_report = {
  verified_objects : int;
  verified_snapshots : int;
  verified_capsules : int;
  verified_capsule_revisions : int;
  verified_workspaces : int;
  verified_releases : int;
}

type error

val error_to_string : error -> string
val storage_bucket_to_string : storage_bucket -> string
val storage : Yeokcham_store.repository -> (storage_report, error) result
val status : Yeokcham_store.repository -> (status, error) result

val timeline :
  Yeokcham_store.repository -> limit:int -> (timeline_entry list, error) result

val history_graph :
  Yeokcham_store.repository ->
  scope:history_scope ->
  (history_graph, error) result
(** Loads a read-only graph of retained native history. It does not represent a
    command event log and does not include Git or peer provenance. *)

val render_history_graph : history_graph -> string list
(** Renders a deterministic ASCII view with no terminal control sequences. *)

val verify : Yeokcham_store.repository -> (verification_report, error) result
(** Verifies every object file, every stored snapshot's reachable tree/content
    graph, all capsule-revision links and declared dependencies, current
    workspaces, and all published releases. *)
