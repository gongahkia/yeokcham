type error = Unavailable of string

external monotonic_milliseconds : unit -> int
  = "yeokcham_monotonic_milliseconds"

let error_to_string = function
  | Unavailable detail -> "monotonic clock unavailable: " ^ detail

let now () =
  try Ok (Int64.of_int (monotonic_milliseconds ()))
  with Failure detail -> Error (Unavailable detail)
