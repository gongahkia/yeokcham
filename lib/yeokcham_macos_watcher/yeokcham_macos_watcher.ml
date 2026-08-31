module Watcher = Yeokcham_watcher

type native

type t = {
  root : string;
  native : native;
  mutable closed : bool;
  mutable needs_restart : bool;
}

type raw_event =
  | Path_changed of string
  | Item_renamed of string
  | Must_scan_subdirs
  | Kernel_dropped
  | User_dropped
  | Client_overflow
  | Event_ids_wrapped
  | Root_changed
  | Unmounted

type error =
  | Root_not_directory of string
  | Root_is_symlink of string
  | Invalid_timeout of float
  | Closed
  | Needs_restart
  | Fsevents_unavailable of string
  | Io_error of { operation : string; path : string; message : string }
  | Normalization_error of Watcher.error

let max_pending_events = 4_096
let max_pending_path_bytes = 1_048_576

let error_to_string = function
  | Root_not_directory path -> "watch root is not a directory: " ^ path
  | Root_is_symlink path -> "watch root must not be a symbolic link: " ^ path
  | Invalid_timeout timeout ->
      Printf.sprintf "watch poll timeout must be finite and nonnegative: %g"
        timeout
  | Closed -> "watcher is closed"
  | Needs_restart -> "watcher has lost coverage and must be restarted"
  | Fsevents_unavailable message ->
      "FSEvents watcher is unavailable: " ^ message
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Normalization_error error -> Watcher.error_to_string error

let retry_start = function
  | Io_error _ -> true
  | Root_not_directory _ | Root_is_symlink _ | Invalid_timeout _ | Closed
  | Needs_restart | Fsevents_unavailable _ | Normalization_error _ ->
      false

let restart_error = function
  | Needs_restart | Io_error _ -> true
  | Root_not_directory _ | Root_is_symlink _ | Invalid_timeout _ | Closed
  | Fsevents_unavailable _ | Normalization_error _ ->
      false

let closed_error = function
  | Closed -> true
  | Root_not_directory _ | Root_is_symlink _ | Invalid_timeout _ | Needs_restart
  | Fsevents_unavailable _ | Io_error _ | Normalization_error _ ->
      false

external native_start : string -> native = "caml_yeokcham_macos_watcher_start"

external native_poll : native -> float -> (int * string option) list
  = "caml_yeokcham_macos_watcher_poll"

external native_close : native -> unit = "caml_yeokcham_macos_watcher_close"

let ( let* ) = Result.bind

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let is_repository_metadata_path = function
  | ".yeokcham" :: _ | ".git" :: _ -> true
  | _ -> false

let safe_component component =
  (not (String.is_empty component))
  && (not (String.equal component "."))
  && (not (String.equal component ".."))
  && (not (String.contains component '/'))
  && not (String.contains component '\000')

let relative_path ~root path =
  let relative =
    if String.equal root "/" then
      if String.starts_with ~prefix:"/" path then
        Some (String.sub path 1 (String.length path - 1))
      else None
    else
      let prefix = root ^ "/" in
      if String.equal path root then Some ""
      else if String.starts_with ~prefix path then
        Some
          (String.sub path (String.length prefix)
             (String.length path - String.length prefix))
      else None
  in
  match relative with
  | None -> None
  | Some "" -> Some []
  | Some relative ->
      let path = String.split_on_char '/' relative in
      if List.for_all safe_component path then Some path else None

type path_event = Changed | Renamed

let macos_event_for_path ~root kind path =
  match relative_path ~root path with
  | None -> Some Watcher.Macos.Root_changed
  | Some [] -> Some Watcher.Macos.Must_scan_subdirs
  | Some relative when kind = Changed && is_repository_metadata_path relative ->
      None
  | Some relative -> (
      match kind with
      | Changed -> Some (Watcher.Macos.Item_modified relative)
      | Renamed -> Some (Watcher.Macos.Item_renamed relative))

let watcher_events ~root events =
  List.filter_map
    (function
      | Path_changed path -> macos_event_for_path ~root Changed path
      | Item_renamed path -> macos_event_for_path ~root Renamed path
      | Must_scan_subdirs -> Some Watcher.Macos.Must_scan_subdirs
      | Kernel_dropped -> Some Watcher.Macos.Kernel_dropped
      | User_dropped -> Some Watcher.Macos.User_dropped
      | Client_overflow -> Some Watcher.Macos.Client_overflow
      | Event_ids_wrapped -> Some Watcher.Macos.Event_ids_wrapped
      | Root_changed -> Some Watcher.Macos.Root_changed
      | Unmounted -> Some Watcher.Macos.Unmounted)
    events

let normalize ~root events =
  Watcher.Macos.normalize (watcher_events ~root events)
  |> Result.map_error (fun error -> Normalization_error error)

let start ~root =
  let* stat =
    try Ok (Unix.lstat root) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Root_not_directory root)
    | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" root error)
  in
  if stat.Unix.st_kind = Unix.S_LNK then Error (Root_is_symlink root)
  else if stat.Unix.st_kind <> Unix.S_DIR then Error (Root_not_directory root)
  else
    let* root =
      try Ok (Unix.realpath root) with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Root_not_directory root)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error "canonicalize root" root error)
    in
    try
      Ok
        {
          root;
          native = native_start root;
          closed = false;
          needs_restart = false;
        }
    with
    | Failure message -> Error (Fsevents_unavailable message)
    | Unix.Unix_error (error, _, _) ->
        Error (io_error "start FSEvents" root error)

let path_changed = 0
let item_renamed = 1
let must_scan_subdirs = 2
let kernel_dropped = 3
let user_dropped = 4
let client_overflow = 5
let event_ids_wrapped = 6
let root_changed = 7
let unmounted = 8

let decode_wire_event = function
  | kind, Some path when Int.equal kind path_changed -> Some (Path_changed path)
  | kind, Some path when Int.equal kind item_renamed -> Some (Item_renamed path)
  | kind, None when Int.equal kind must_scan_subdirs -> Some Must_scan_subdirs
  | kind, None when Int.equal kind kernel_dropped -> Some Kernel_dropped
  | kind, None when Int.equal kind user_dropped -> Some User_dropped
  | kind, None when Int.equal kind client_overflow -> Some Client_overflow
  | kind, None when Int.equal kind event_ids_wrapped -> Some Event_ids_wrapped
  | kind, None when Int.equal kind root_changed -> Some Root_changed
  | kind, None when Int.equal kind unmounted -> Some Unmounted
  | _ -> None

let restart_request = function
  | Some { Watcher.reason = Watcher.Overflow | Watcher.Watcher_lost; _ } -> true
  | Some
      {
        Watcher.reason =
          ( Watcher.Initial_scan | Watcher.Path_change | Watcher.Rename
          | Watcher.Rescan_required | Watcher.Path_budget_exceeded );
        _;
      }
  | None ->
      false

let poll state ~timeout =
  if
    classify_float timeout = FP_nan
    || classify_float timeout = FP_infinite
    || timeout < 0.0
  then Error (Invalid_timeout timeout)
  else if state.closed then Error Closed
  else if state.needs_restart then Error Needs_restart
  else
    try
      let raw_events = native_poll state.native timeout in
      let events, malformed =
        List.fold_right
          (fun raw (events, malformed) ->
            match decode_wire_event raw with
            | Some event -> (event :: events, malformed)
            | None -> (events, true))
          raw_events ([], false)
      in
      let events = if malformed then Root_changed :: events else events in
      let* request = normalize ~root:state.root events in
      if malformed || restart_request request then state.needs_restart <- true;
      Ok request
    with
    | Failure message ->
        Error
          (Io_error { operation = "poll FSEvents"; path = state.root; message })
    | Unix.Unix_error (error, _, _) ->
        Error (io_error "poll FSEvents" state.root error)

let close state =
  if not state.closed then (
    state.closed <- true;
    native_close state.native)
