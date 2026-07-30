type t =
  | Fixed of { chunk_size : int }
  | Gear_v1 of { min_size : int; average_size : int; max_size : int }

type error =
  | Invalid_chunk_size of int
  | Invalid_gear_parameters of { min_size : int; average_size : int; max_size : int }

val error_to_string : error -> string
val default : t
val fixed_64k : t
val validate : t -> (unit, error) result
val split : t -> string -> (string list, error) result
val chunks_are_canonical : t -> string list -> bool
