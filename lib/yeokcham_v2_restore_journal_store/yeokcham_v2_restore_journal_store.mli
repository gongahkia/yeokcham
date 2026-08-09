(** Create-only local persistence for ADR-056 restore journal generations.

    The store owns only [restore-*.cbor] entries in the shared strict V2 journal
    directory. It neither reads snapshot plaintext nor mutates a working tree.
*)

module Journal = Yeokcham_v2_restore_journal
module Model = Yeokcham_v2_model

type repository
type append_outcome = Appended | Already_appended

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Journal_error of Journal.error
  | Repository_mismatch of {
      expected : Model.Repository_id.t;
      actual : Model.Repository_id.t;
    }
  | Journal_collision of string
  | Journal_entry_changed of string
  | Invalid_journal_path of string
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  (repository, error) result

val record_path : repository -> Journal.t -> string

val append : repository -> Journal.t -> (append_outcome, error) result
(** Appends one exact legal successor using create-only publication. Equal
    pre-existing bytes are an idempotent retry; differing bytes are a collision.
*)

val scan : repository -> (Journal.t list, error) result
(** Returns every record for this repository in operation/generation order after
    validating each complete immutable operation chain. *)

val latest :
  repository ->
  operation_id:Model.Transaction_id.t ->
  (Journal.t option, error) result
