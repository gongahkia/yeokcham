(** Terminal-only progress rendering for finite CLI mutations.

    The frame sequence and clear-on-finish behavior mirror uv's current
    indicatif spinner defaults. This adapter deliberately owns no model or
    persistence state. *)

val spinner_frames : string list
val refresh_interval_seconds : float
val clear_sequence : string

val spinner_frame : int -> string
val render_line : tick:int -> message:string -> string
val bar_width : columns:int option -> message:string -> completed:int -> total:int -> int
val render_bar :
  columns:int option -> message:string -> completed:int -> total:int -> string

val should_render :
  no_progress:bool -> stderr_isatty:bool -> environment:string option -> bool
(** [should_render] is the deterministic visibility policy used by [enabled]. *)

val enabled : no_progress:bool -> bool
(** [enabled] requires an interactive stderr, no [--no-progress] flag, and no
    [YEOKCHAM_NO_PROGRESS=1] environment override. *)

val with_progress : enabled:bool -> string -> (unit -> 'a) -> 'a
(** Render a spinner until the callback returns or raises. The spinner is
    cleared before the callback's output, exception, or process exit is shown. *)

val with_determinate_progress :
  enabled:bool ->
  message:string ->
  (report:(completed:int -> total:int -> unit) -> 'a) ->
  'a
(** [with_determinate_progress] leaves its caller's spinner active until
    [report] receives the first exact [completed]/[total] value, then replaces
    it with a bar. It clears the bar before ordinary output or errors. *)

val stop_active : unit -> unit
