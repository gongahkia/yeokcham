type t =
  | Fixed of { chunk_size : int }
  | Buzhash_v1 of {
      window_size : int;
      min_size : int;
      average_size : int;
      max_size : int;
    }

type error =
  | Invalid_chunk_size of int
  | Invalid_buzhash_parameters of {
      window_size : int;
      min_size : int;
      average_size : int;
      max_size : int;
    }

type splitter

val error_to_string : error -> string
val default : t
val fixed_64k : t
val validate : t -> (unit, error) result
val create_splitter : t -> (splitter, error) result
val feed : splitter -> string -> string list
val finish : splitter -> string list
val split : t -> string -> (string list, error) result
val chunks_are_canonical : t -> string list -> bool
