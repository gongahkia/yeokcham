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

let should_render ~no_progress ~stderr_isatty ~environment =
  not no_progress && stderr_isatty
  &&
  match environment with Some "1" -> false | None | Some _ -> true

let stderr_isatty () =
  try Unix.isatty Unix.stderr with Unix.Unix_error _ -> false

let enabled ~no_progress =
  should_render ~no_progress ~stderr_isatty:(stderr_isatty ())
    ~environment:(Sys.getenv_opt "YEOKCHAM_NO_PROGRESS")

type state = {
  mutex : Mutex.t;
  mutable running : bool;
  mutable tick : int;
  message : string;
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

let draw state tick = write (clear_sequence ^ render_line ~tick ~message:state.message)

let clear () = write clear_sequence

let rec loop state =
  Thread.delay refresh_interval_seconds;
  Mutex.lock state.mutex;
  let tick =
    if state.running then (
      state.tick <- state.tick + 1;
      Some state.tick)
    else None
  in
  Mutex.unlock state.mutex;
  match tick with None -> () | Some tick -> draw state tick; loop state

let stop state =
  Mutex.lock state.mutex;
  let worker = state.worker in
  state.running <- false;
  state.worker <- None;
  Mutex.unlock state.mutex;
  Option.iter Thread.join worker;
  Mutex.lock active_mutex;
  if Option.fold ~none:false ~some:(fun current -> current == state) !active then
    active := None;
  Mutex.unlock active_mutex;
  clear ()

let stop_active () =
  Mutex.lock active_mutex;
  let current = !active in
  Mutex.unlock active_mutex;
  Option.iter stop current

let start message =
  stop_active ();
  let state =
    { mutex = Mutex.create (); running = true; tick = 0; message; worker = None }
  in
  Mutex.lock active_mutex;
  active := Some state;
  Mutex.unlock active_mutex;
  draw state 0;
  let worker = Thread.create loop state in
  Mutex.lock state.mutex;
  state.worker <- Some worker;
  Mutex.unlock state.mutex;
  state

let with_progress ~enabled message callback =
  if not enabled then callback ()
  else
    let state = start message in
    Fun.protect callback ~finally:(fun () -> stop state)

let () = at_exit stop_active
