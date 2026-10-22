type color_mode = Auto | Always | Never

val configure : mode:color_mode -> machine_output:bool -> unit

val display_value : string -> string
(** Quote whitespace and control bytes so one value cannot become extra rows or
    terminal instructions. Ordinary single-token values remain readable. *)

val print_string : string -> unit
val print_endline : string -> unit
val print_error : string -> unit
val print_warning : string -> unit
val print_raw_string : string -> unit
val print_raw_endline : string -> unit
