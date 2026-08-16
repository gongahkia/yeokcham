(* This is the default indicatif spinner used by uv. The trailing blank frame
   is preserved so callers can test the exact sequence; active rendering does
   not dwell on it because completion clears the line. *)
let spinner_frames =
  [
    "⠁";
    "⠁";
    "⠉";
    "⠙";
    "⠚";
    "⠒";
    "⠂";
    "⠂";
    "⠒";
    "⠲";
    "⠴";
    "⠤";
    "⠄";
    "⠄";
    "⠤";
    "⠠";
    "⠠";
    "⠤";
    "⠦";
    "⠖";
    "⠒";
    "⠐";
    "⠐";
    "⠒";
    "⠓";
    "⠋";
    "⠉";
    "⠈";
    "⠈";
    " ";
  ]

let refresh_interval_seconds = 0.05
let clear_sequence = "\r\027[2K"

let spinner_frame tick =
  match spinner_frames with
  | [] -> ""
  | frames -> List.nth frames (tick mod List.length frames)

let render_line ~tick ~message = spinner_frame tick ^ " " ^ message

external stderr_columns : unit -> int = "yeokcham_cli_progress_stderr_columns"

let clamp ~lower ~upper value = max lower (min upper value)

let normalized_progress ~completed ~total =
  let total = max 0 total in
  let completed = if total = 0 then 0 else clamp ~lower:0 ~upper:total completed in
  (completed, total)

let bar_width ~columns ~message ~completed ~total =
  let completed, total = normalized_progress ~completed ~total in
  match columns with
  | None -> 20
  | Some columns ->
      let suffix = string_of_int completed ^ "/" ^ string_of_int total in
      max 10 (columns - String.length message - String.length suffix - 5)

let repeat text count = String.concat "" (List.init count (fun _ -> text))

let render_bar ~columns ~message ~completed ~total =
  let completed, total = normalized_progress ~completed ~total in
  let width = bar_width ~columns ~message ~completed ~total in
  let filled =
    if total = 0 then 0
    else
      Int64.(
        div
          (mul (of_int completed) (of_int width))
          (of_int total)
        |> to_int)
  in
  message ^ " [" ^ repeat "█" filled ^ repeat "░" (width - filled) ^ "] "
  ^ string_of_int completed ^ "/" ^ string_of_int total

let should_render ~no_progress ~stderr_isatty ~environment =
  not no_progress && stderr_isatty
  &&
  match environment with Some "1" -> false | None | Some _ -> true

let stderr_isatty () =
  try Unix.isatty Unix.stderr with Unix.Unix_error _ -> false

let enabled ~no_progress =
  should_render ~no_progress ~stderr_isatty:(stderr_isatty ())
    ~environment:(Sys.getenv_opt "YEOKCHAM_NO_PROGRESS")

type display = Spinner | Bar of { completed : int; total : int }

type state = {
  mutex : Mutex.t;
  mutable running : bool;
  mutable tick : int;
  message : string;
  mutable display : display;
  mutable worker : Thread.t option;
}

let active_mutex = Mutex.create ()
let active : state option ref = ref None
let output_mutex = Mutex.create ()

let write value =
  Mutex.lock output_mutex;
  (try
     output_string stderr value;
     flush stderr
   with Sys_error _ -> ());
  Mutex.unlock output_mutex

let terminal_columns () =
  match stderr_columns () with value when value > 0 -> Some value | _ -> None

let draw state ~tick ~display =
  let line =
    match display with
    | Spinner -> render_line ~tick ~message:state.message
    | Bar { completed; total } ->
        render_bar ~columns:(terminal_columns ()) ~message:state.message
          ~completed ~total
  in
  write (clear_sequence ^ line)

let clear () = write clear_sequence

let rec loop state =
  Thread.delay refresh_interval_seconds;
  Mutex.lock state.mutex;
  let frame =
    if state.running then (
      state.tick <- state.tick + 1;
      Some (state.tick, state.display))
    else None
  in
  Mutex.unlock state.mutex;
  match frame with
  | None -> ()
  | Some (tick, display) ->
      draw state ~tick ~display;
      loop state

let stop state =
  Mutex.lock state.mutex;
  let worker = state.worker in
  state.running <- false;
  state.worker <- None;
  Mutex.unlock state.mutex;
  Option.iter Thread.join worker;
  Mutex.lock active_mutex;
  let was_active =
    Option.fold ~none:false ~some:(fun current -> current == state) !active
  in
  if was_active then active := None;
  Mutex.unlock active_mutex;
  if was_active then clear ()

let stop_active () =
  Mutex.lock active_mutex;
  let current = !active in
  Mutex.unlock active_mutex;
  Option.iter stop current

let start ~display message =
  stop_active ();
  let state =
    {
      mutex = Mutex.create ();
      running = true;
      tick = 0;
      message;
      display;
      worker = None;
    }
  in
  Mutex.lock active_mutex;
  active := Some state;
  Mutex.unlock active_mutex;
  draw state ~tick:0 ~display;
  let worker = Thread.create loop state in
  Mutex.lock state.mutex;
  state.worker <- Some worker;
  Mutex.unlock state.mutex;
  state

let with_progress ~enabled message callback =
  if not enabled then callback ()
  else
    let state = start ~display:Spinner message in
    Fun.protect callback ~finally:(fun () -> stop state)

let set_bar_position state ~completed ~total =
  let completed, total = normalized_progress ~completed ~total in
  Mutex.lock state.mutex;
  state.display <- Bar { completed; total };
  Mutex.unlock state.mutex

let with_determinate_progress ~enabled ~message callback =
  if not enabled then callback ~report:(fun ~completed:_ ~total:_ -> ())
  else
    let state = ref None in
    let report ~completed ~total =
      match !state with
      | Some state -> set_bar_position state ~completed ~total
      | None ->
          let completed, total = normalized_progress ~completed ~total in
          let progress = start ~display:(Bar { completed; total }) message in
          state := Some progress
    in
    Fun.protect (fun () -> callback ~report) ~finally:(fun () ->
        Option.iter stop !state)

let () = at_exit stop_active
