module Stored_object_id : sig
  type t

  type parse_error =
    | Invalid_length of int
    | Invalid_hex_character of int * char

  val parse_error_to_string : parse_error -> string
  val of_raw_bytes : string -> t option
  val to_raw_bytes : t -> string
  val of_hex : string -> (t, parse_error) result
  val to_hex : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Mutable_ref : sig
  type t

  val generation : t -> int64
  val target : t -> Stored_object_id.t option
  val equal : t -> t -> bool
  val decode : string -> (t, string) result
end

type repository

type object_info = {
  id : Stored_object_id.t;
  object_type : Yeokcham_envelope.object_type;
  stored_bytes : int;
}

type error =
  | Root_not_directory of string
  | Repository_not_initialized of string
  | Repository_incomplete of { path : string; required : string }
  | Incompatible_repository_format of string
  | Not_regular_file of string
  | Object_too_large of { path : string; size : int; limit : int }
  | File_size_changed of string
  | Io_error of { operation : string; path : string; message : string }
  | Object_identity_mismatch of {
      expected : Stored_object_id.t;
      actual : Stored_object_id.t;
    }
  | Object_integrity_error of {
      id : Stored_object_id.t;
      error : Yeokcham_envelope.decode_error;
    }
  | Collision_or_corruption of { id : Stored_object_id.t; detail : string }
  | Unsupported_publication of { path : string; detail : string }
  | Temporary_name_exhausted of string
  | Invalid_ref_name of string
  | Corrupt_ref of { name : string; detail : string }
  | Concurrent_ref_update of {
      name : string;
      expected : Mutable_ref.t option;
      actual : Mutable_ref.t option;
    }
  | Ref_lock_held of string
  | Ref_generation_exhausted of string
  | Invalid_ref_path of string list
  | Concurrent_ref_file_update of {
      path : string;
      expected_present : bool;
      actual_present : bool;
    }

module Ref_file : sig
  val read :
    repository -> components:string list -> (string option, error) result

  val compare_and_swap :
    repository ->
    components:string list ->
    expected:string option ->
    replacement:string ->
    (unit, error) result
end

val error_to_string : error -> string
val repository_format : string
val root_format : string
val max_object_bytes : int
val root : repository -> string
val init : root:string -> (repository, error) result
val open_repository : root:string -> (repository, error) result
val object_path : repository -> Stored_object_id.t -> string
val id_of_envelope : Yeokcham_envelope.t -> Stored_object_id.t

val put :
  ?after_staging:(unit -> unit) ->
  repository ->
  Yeokcham_envelope.t ->
  (Stored_object_id.t, error) result
(** Creates and fsyncs a same-directory temporary object before publication.
    [after_staging], when supplied, runs after that durable staging point and
    before the add-if-missing link. It is a fault-injection seam: an exception
    from it leaves no successful publication result and may leave the staged
    temporary file for later inspection. *)

val get :
  repository -> Stored_object_id.t -> (Yeokcham_envelope.t, error) result

val list_objects : repository -> (object_info list, error) result
(** Lists every canonical object file in lexicographic object-ID order. Each
    returned entry has passed the same identity and Envelope-1 checks as [get].
*)

val read_ref : repository -> name:string -> (Mutable_ref.t option, error) result

val compare_and_swap_ref :
  repository ->
  name:string ->
  expected:Mutable_ref.t option ->
  target:Stored_object_id.t option ->
  (Mutable_ref.t, error) result

val with_lock :
  repository ->
  name:string ->
  on_error:(error -> 'e) ->
  (unit -> ('a, 'e) result) ->
  ('a, 'e) result
