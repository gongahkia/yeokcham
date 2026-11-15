module Core = Yeokcham_v1_model.Core

type error =
  | Package_error of Yeokcham_v1_package.error
  | Store_error of Yeokcham_v1_store.error
  | Trust_error of Yeokcham_v1_trust.error
  | Admission_error of Yeokcham_v1_store.Local.receive_error
  | Metadata of string

val error_to_string : error -> string

type outcome = {
  records_added : int;
  branches_added : int;
  unchanged : bool;
  cursor : Core.History_id.t;
  working_basis : Core.Record_id.t;
  selected_branch : Core.Branch_id.t;
  known_branches : Core.branch_state list;
  state_head : Yeokcham_store.Stored_object_id.t;
}

val receive : root:string -> package:string -> (outcome, error) result
(** Isolated public-package verification, current authority admission, then one
    serialized metadata publication preserving current history/cursor/files. No
    signing, project hooks, integration or transport acknowledgement. Known
    shared branches receive no fabricated private working positions. *)

type boundary = Before_metadata_publish | After_metadata_publish

module For_test : sig
  val receive :
    observe:(boundary -> unit) ->
    root:string ->
    package:string ->
    (outcome, error) result
end
