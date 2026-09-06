type color_mode = Auto | Always | Never

val configure : mode:color_mode -> machine_output:bool -> unit
val print_string : string -> unit
val print_endline : string -> unit
val print_error : string -> unit
val print_warning : string -> unit
val print_raw_string : string -> unit
val print_raw_endline : string -> unit
