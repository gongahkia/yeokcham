(** Crash-safe create-only persistence for V2 MLS epoch transitions. *)

module Authority = Yeokcham_v2_authority
module Epoch = Yeokcham_v2_mls_epoch
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type publication = Published | Already_published

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Epoch_error of Epoch.error
  | Missing_record of string
  | Invalid_record_path of string
  | Record_collision of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string

val error_to_string : error -> string
val directory : root:string -> string
val path : root:string -> Model.Mls_epoch_id.t -> string

val write :
  root:string ->
  authority:Authority.repository_authority ->
  Epoch.transition ->
  (publication, error) result

val read_all :
  root:string ->
  authority:Authority.repository_authority ->
  (Epoch.transition list, error) result

val load_current :
  runtime:Runtime.configuration ->
  root:string ->
  authority:Authority.repository_authority ->
  state_key:Yeokcham_v2_envelope.key ->
  initial_state:Group.t ->
  (Group.t, error) result
