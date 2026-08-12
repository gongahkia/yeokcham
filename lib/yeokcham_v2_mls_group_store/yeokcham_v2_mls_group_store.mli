(** Create-only local persistence for V2-029's encrypted MLS group snapshot.

    The repository file contains one canonical V2 envelope whose plaintext is
    never returned as bytes. Callers supply the already-validated local
    bootstrap capability; an MLS state is accepted only when it binds that
    bootstrap's repository and device and the constrained runtime reloads it. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Group = Yeokcham_v2_mls_group
module Runtime = Yeokcham_v2_mls_runtime

type initialization = Initialized | Already_initialized

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Bootstrap_store_error of Bootstrap_store.error
  | Bootstrap_error of Yeokcham_v2_bootstrap.error
  | Bootstrap_mismatch
  | Group_error of Group.error
  | Missing_group_state of string
  | Invalid_group_path of string
  | Unexpected_group_entry of string
  | Group_already_initialized of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string
  | Entropy_failure

val error_to_string : error -> string
val filename : string
val group_path : root:string -> string

val initialize :
  runtime:Runtime.configuration ->
  root:string ->
  bootstrap:Bootstrap_store.repository ->
  Group.t ->
  (initialization, error) result
(** Validates and durably publishes one encrypted group snapshot using a
    same-directory create-only link. Exact state retries are idempotent;
    foreign, corrupt, or divergent bytes are never replaced. *)

val read :
  runtime:Runtime.configuration ->
  root:string ->
  bootstrap:Bootstrap_store.repository ->
  (Group.t, error) result
(** Opens only the canonical state encrypted for the supplied local bootstrap,
    checks repository/device bindings, and asks the MLS runtime to reload it. *)
