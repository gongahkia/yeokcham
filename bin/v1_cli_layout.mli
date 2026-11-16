type graph_row = {
  prefix : string;
  node_column : int;
  rails : string;
  connectors : string list;
}

val history_graph :
  (int64 * int64 option) list -> graph_row list * (string * int64) list
(** Descending, single-parent local history. Open lanes identify parents outside
    this page. An X is a crossing, not a shared parent. *)

val diff_hunks :
  columns:int ->
  escape:(string -> string) ->
  Yeokcham_v1_local_service.Text_diff.hunk list ->
  string list
(** Numbered unified rows below 100 columns; paired, wrapped columns otherwise.
    No content is elided. Input text must be escaped before terminal layout. *)
