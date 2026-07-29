val profile_version : int
val max_nesting : int

type t = private
  | Integer of int64
  | Bytes of string
  | Text of string
  | Array of t list
  | Map of (int64 * t) list
  | Bool of bool
  | Null

type construction_error =
  | Invalid_text_utf8 of int
  | Negative_map_key of int64
  | Duplicate_map_key of int64
  | Nesting_limit_exceeded of int

val construction_error_to_string : construction_error -> string
val integer : int64 -> t
val bytes : string -> t
val text : string -> (t, construction_error) result
val array : t list -> (t, construction_error) result
val map : (int64 * t) list -> (t, construction_error) result
val bool : bool -> t
val null : t
val equal : t -> t -> bool

type limits
type limit_error = Invalid_max_depth of int | Invalid_max_items of int

val limit_error_to_string : limit_error -> string

val make_limits :
  ?max_depth:int -> ?max_items:int -> unit -> (limits, limit_error) result

val default_limits : limits

type decode_error_kind =
  | Empty_input
  | Truncated of int
  | Trailing_bytes of int
  | Reserved_additional_information of int
  | Indefinite_length
  | Non_minimal_argument of int64
  | Argument_out_of_range
  | Unsupported_major_type of int
  | Unsupported_simple_value of int
  | Invalid_utf8_text
  | Non_integer_map_key
  | Negative_decoded_map_key of int64
  | Duplicate_decoded_map_key of int64
  | Non_increasing_map_key of { previous : int64; current : int64 }
  | Declared_length_exceeds_input of int64
  | Declared_items_exceed_input of int64
  | Depth_limit_exceeded of int
  | Work_limit_exceeded

type decode_error = { offset : int; kind : decode_error_kind }

val decode_error_to_string : decode_error -> string
val encode : t -> string
val decode : ?limits:limits -> string -> (t, decode_error) result
