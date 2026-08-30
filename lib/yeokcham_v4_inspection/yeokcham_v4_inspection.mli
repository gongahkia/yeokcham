(** Pure, read-only terminal projections of persisted V4 state.

    These renderers never infer a shared history from delivery milestones or a
    unified authority policy from concurrent heads. *)

type state

val state :
  project:Yeokcham_v4_model.project ->
  signed_revisions:Yeokcham_v4_trust.signed_revision list ->
  authority:Yeokcham_v4_trust.authority option ->
  review_publications:string list ->
  state

val has_authority : state -> bool

val render_log : width:int -> state -> string
(** A stable ledger for the current V4 work domain. *)

val render_work_graph : width:int -> state -> string
(** A stable ASCII graph of current V4 work only. *)

val render_authority_graph : width:int -> state -> string option
(** A separate authority-epoch graph. [None] means no signed authority state was
    available, not that authority was empty. *)
