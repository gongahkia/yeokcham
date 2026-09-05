(** Bounded, session-local observations from one configured external LSP server.

    This module does not parse source, persist observations, or mutate V1
    project state. The configured executable is untrusted and receives only a
    disposable materialisation of named snapshots. *)

type snapshot_role = Base | Left | Right
type position = { line : int; character : int }
type range = { start : position; end_ : position }

type symbol = {
  snapshot : snapshot_role;
  snapshot_id : string;
  path : string;
  name : string;
  kind : string;
  ancestry : string list;
  range : range;
  selection_range : range;
  definitions : (string * range) list;
  references : (string * range) list;
  workspace_matches : (string * range) list;
}

type overlap_evidence =
  | Same_symbol_changed
  | Nearby_returned_ranges
  | Shared_definition_or_reference

type possible_overlap = {
  path : string;
  symbol : string;
  evidence : overlap_evidence;
  left_snapshot : string;
  right_snapshot : string;
}

type server_details = {
  configured_name : string;
  program : string;
  arguments : string list;
  reported_name : string option;
  reported_version : string option;
  capabilities : string list;
}

type available = {
  server : server_details;
  snapshots : (snapshot_role * string) list;
  symbols : symbol list;
  possible_overlaps : possible_overlap list;
}

type report =
  | Available of available
  | Unavailable of { server : string; reason : string }

val inspect :
  store:Yeokcham_store.repository ->
  server:Yeokcham_v1_semantic_config.server ->
  base:string * Yeokcham_snapshot.Snapshot.t ->
  left:string * Yeokcham_snapshot.Snapshot.t ->
  right:string * Yeokcham_snapshot.Snapshot.t ->
  paths:string list ->
  report
(** Uses only named exact snapshots. [paths] must be repository-relative paths
    selected from the existing byte proposal. All errors become a bounded
    unavailable report so the caller can preserve byte-only inspection. *)

val snapshot_role_to_string : snapshot_role -> string
val overlap_evidence_to_string : overlap_evidence -> string
