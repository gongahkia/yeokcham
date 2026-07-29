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

type repository

type error =
  | Root_not_directory of string
  | Repository_not_initialized of string
  | Incompatible_repository_format of string
  | Not_regular_file of string
  | Object_too_large of { path : string; size : int; limit : int }
  | File_size_changed of string
  | Io_error of { operation : string; path : string; message : string }
  | Object_identity_mismatch of {
      expected : Stored_object_id.t;
      actual : Stored_object_id.t;
    }
  | Object_integrity_error of Paengi_envelope.decode_error
  | Collision_or_corruption of {
      id : Stored_object_id.t;
      detail : string;
    }
  | Unsupported_publication of { path : string; detail : string }
  | Temporary_name_exhausted of string

val error_to_string : error -> string
val repository_format : string
val max_object_bytes : int
val init : root:string -> (repository, error) result
val open_repository : root:string -> (repository, error) result
val object_path : repository -> Stored_object_id.t -> string
val put : repository -> Paengi_envelope.t -> (Stored_object_id.t, error) result
val get : repository -> Stored_object_id.t -> (Paengi_envelope.t, error) result
