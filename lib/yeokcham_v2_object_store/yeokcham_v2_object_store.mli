(** Create-only storage for authenticated typed V2 encrypted objects. *)

module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object

type repository

type publication =
  | Published of Model.Opaque_object_ref.t
  | Already_published of Model.Opaque_object_ref.t

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_object_path of string
  | Envelope_error of Envelope.error
  | Address_error of Address.error
  | Object_error of Object.error
  | Object_collision of Model.Opaque_object_ref.t

val error_to_string : error -> string
val repository_id : repository -> Model.Repository_id.t

val open_repository :
  root:string ->
  repository_id:Model.Repository_id.t ->
  address_key:Address.key ->
  encryption_key:Envelope.key ->
  (repository, error) result

val object_path : repository -> Model.Opaque_object_ref.t -> string

val list_object_refs :
  repository -> (Model.Opaque_object_ref.t list, error) result
(** Lists every canonical opaque object path without decrypting or mutating it.
*)

val validate_envelope :
  repository ->
  envelope:Envelope.t ->
  (Model.Opaque_object_ref.t * Object.t, error) result
(** Strictly checks one typed candidate without writing an object. *)

val publish : repository -> envelope:Envelope.t -> (publication, error) result

val load :
  repository -> object_ref:Model.Opaque_object_ref.t -> (Object.t, error) result
