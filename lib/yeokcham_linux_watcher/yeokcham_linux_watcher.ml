module Watcher = Yeokcham_watcher

type watch = { descriptor : Inotify.watch; path : string list }

type t = {
  root : string;
  fd : Unix.file_descr;
  mutable watches : watch list;
  mutable expected_ignored : int list;
  mutable closed : bool;
  mutable needs_restart : bool;
}

type error =
  | Root_not_directory of string
  | Root_is_symlink of string
  | Invalid_timeout of float
  | Closed
  | Needs_restart
  | Watch_limit_exceeded of int
  | Io_error of { operation : string; path : string; message : string }
  | Normalization_error of Watcher.error

let max_watches = 8_192

let error_to_string = function
  | Root_not_directory path -> "watch root is not a directory: " ^ path
  | Root_is_symlink path -> "watch root must not be a symbolic link: " ^ path
  | Invalid_timeout timeout ->
      Printf.sprintf "watch poll timeout must be finite and nonnegative: %g"
        timeout
  | Closed -> "watcher is closed"
  | Needs_restart -> "watcher has lost coverage and must be restarted"
  | Watch_limit_exceeded limit ->
      Printf.sprintf "watcher exceeds its %d-directory limit" limit
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Normalization_error error -> Watcher.error_to_string error

let retry_start = function
  | Io_error _ -> true
  | Root_not_directory _ | Root_is_symlink _ | Invalid_timeout _ | Closed
  | Needs_restart | Watch_limit_exceeded _ | Normalization_error _ ->
      false

let restart_error = function
  | Needs_restart | Io_error _ -> true
  | Root_not_directory _ | Root_is_symlink _ | Invalid_timeout _ | Closed
  | Watch_limit_exceeded _ | Normalization_error _ ->
      false

let closed_error = function
  | Closed -> true
  | Root_not_directory _ | Root_is_symlink _ | Invalid_timeout _ | Needs_restart
  | Watch_limit_exceeded _ | Io_error _ | Normalization_error _ ->
      false

let ( let* ) = Result.bind

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let valid_component component =
  (not (String.is_empty component))
  && (not (String.equal component "."))
  && (not (String.equal component ".."))
  && (not (String.contains component '/'))
  && not (String.contains component '\000')

let is_repository_metadata_path = function
  | ".yeokcham" :: _ -> true
  | _ -> false

let path_has_prefix prefix path =
  let rec loop prefix path =
    match (prefix, path) with
    | [], _ -> true
    | prefix_component :: prefix_rest, path_component :: path_rest ->
        String.equal prefix_component path_component
        && loop prefix_rest path_rest
    | _ :: _, [] -> false
  in
  loop prefix path

let path_suffix prefix path =
  let rec loop prefix path =
    match (prefix, path) with
    | [], suffix -> suffix
    | _ :: prefix_rest, _ :: path_rest -> loop prefix_rest path_rest
    | _ :: _, [] -> invalid_arg "path suffix requires a prefix"
  in
  loop prefix path

let absolute_path state path = List.fold_left Filename.concat state.root path

let same_watch left right =
  Int.equal (Inotify.int_of_watch left) (Inotify.int_of_watch right)

let find_watch state descriptor =
  List.find_opt
    (fun watch -> same_watch watch.descriptor descriptor)
    state.watches

let has_path state path =
  List.exists (fun watch -> watch.path = path) state.watches

let remove_watch_safely state watch =
  try Inotify.rm_watch state.fd watch.descriptor with Unix.Unix_error _ -> ()

let drop_subtree state path =
  let removed, retained =
    List.partition (fun watch -> path_has_prefix path watch.path) state.watches
  in
  state.expected_ignored <-
    List.map (fun watch -> Inotify.int_of_watch watch.descriptor) removed
    @ state.expected_ignored;
  List.iter (remove_watch_safely state) removed;
  state.watches <- retained

let expected_removed state descriptor =
  let descriptor = Inotify.int_of_watch descriptor in
  List.exists
    (fun candidate -> Int.equal candidate descriptor)
    state.expected_ignored

let finish_expected_removal state descriptor =
  let descriptor = Inotify.int_of_watch descriptor in
  state.expected_ignored <-
    List.filter
      (fun candidate -> not (Int.equal candidate descriptor))
      state.expected_ignored

let rename_subtree state ~source ~destination =
  state.watches <-
    List.map
      (fun watch ->
        if path_has_prefix source watch.path then
          { watch with path = destination @ path_suffix source watch.path }
        else watch)
      state.watches

let read_directory path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
  with Sys_error message ->
    Error (Io_error { operation = "read directory"; path; message })

let lstat_or_missing path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let selectors =
  [
    Inotify.S_Attrib;
    Inotify.S_Close_write;
    Inotify.S_Create;
    Inotify.S_Delete;
    Inotify.S_Delete_self;
    Inotify.S_Dont_follow;
    Inotify.S_Modify;
    Inotify.S_Move_self;
    Inotify.S_Moved_from;
    Inotify.S_Moved_to;
    Inotify.S_Onlydir;
  ]

let rec watch_directory state path =
  if is_repository_metadata_path path then Ok ()
  else
    let absolute = absolute_path state path in
    let* stat = lstat_or_missing absolute in
    match stat with
    | None -> Ok ()
    | Some stat when stat.Unix.st_kind <> Unix.S_DIR -> Ok ()
    | Some _ when has_path state path -> Ok ()
    | Some _ when List.length state.watches >= max_watches ->
        Error (Watch_limit_exceeded max_watches)
    | Some _ -> (
        let* descriptor =
          try Ok (Inotify.add_watch state.fd absolute selectors)
          with Unix.Unix_error (error, _, _) ->
            Error (io_error "add inotify watch" absolute error)
        in
        state.watches <- { descriptor; path } :: state.watches;
        let* names = read_directory absolute in
        let result =
          List.fold_left
            (fun result name ->
              let* () = result in
              if valid_component name then
                watch_directory state (path @ [ name ])
              else
                Error
                  (Io_error
                     {
                       operation = "watch directory";
                       path = absolute;
                       message = "unsafe directory entry";
                     }))
            (Ok ()) names
        in
        match result with
        | Ok () -> Ok ()
        | Error _ as error ->
            (match find_watch state descriptor with
            | Some watch ->
                remove_watch_safely state watch;
                state.watches <-
                  List.filter
                    (fun candidate ->
                      not (same_watch candidate.descriptor descriptor))
                    state.watches
            | None -> ());
            error)

let start ~root =
  let* root_stat =
    try Ok (Unix.lstat root) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Root_not_directory root)
    | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" root error)
  in
  if root_stat.Unix.st_kind = Unix.S_LNK then Error (Root_is_symlink root)
  else if root_stat.Unix.st_kind <> Unix.S_DIR then
    Error (Root_not_directory root)
  else
    let* root =
      try Ok (Unix.realpath root) with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Root_not_directory root)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error "canonicalize root" root error)
    in
    let* descriptor =
      try Ok (Inotify.create ())
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "create inotify" root error)
    in
    let state =
      {
        root;
        fd = descriptor;
        watches = [];
        expected_ignored = [];
        closed = false;
        needs_restart = false;
      }
    in
    let result =
      try
        Unix.set_nonblock descriptor;
        watch_directory state []
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "configure inotify" root error)
    in
    match result with
    | Ok () -> Ok state
    | Error _ as error ->
        (try Unix.close descriptor with Unix.Unix_error _ -> ());
        error

let contains kind kinds = List.exists (fun candidate -> candidate = kind) kinds

let event_path watch name =
  match name with
  | None -> Ok watch.path
  | Some name when valid_component name -> Ok (watch.path @ [ name ])
  | Some _ -> Error ()

let take_move cookie moves =
  let rec loop reversed = function
    | [] -> (None, List.rev reversed)
    | (candidate, path) :: rest when Int32.equal candidate cookie ->
        (Some path, List.rev_append reversed rest)
    | move :: rest -> loop (move :: reversed) rest
  in
  loop [] moves

let normalize events =
  Watcher.Linux.normalize events
  |> Result.map_error (fun error -> Normalization_error error)

let poll state ~timeout =
  if
    classify_float timeout = FP_nan
    || classify_float timeout = FP_infinite
    || timeout < 0.0
  then Error (Invalid_timeout timeout)
  else if state.closed then Error Closed
  else if state.needs_restart then Error Needs_restart
  else
    let* readable =
      try
        let readable, _, _ = Unix.select [ state.fd ] [] [] timeout in
        Ok readable
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "poll inotify" state.root error)
    in
    match readable with
    | [] -> Ok None
    | _ ->
        let* raw_events =
          try Ok (Inotify.read state.fd) with
          | Unix.Unix_error (Unix.EAGAIN, _, _) -> Ok []
          | Unix.Unix_error (error, _, _) ->
              Error (io_error "read inotify" state.root error)
        in
        let rec process moves reversed = function
          | [] ->
              let reversed =
                List.fold_left
                  (fun reversed (_, source) ->
                    drop_subtree state source;
                    Watcher.Linux.Deleted source :: reversed)
                  reversed moves
              in
              Ok (List.rev reversed)
          | (descriptor, kinds, cookie, name) :: rest -> (
              if contains Inotify.Q_overflow kinds then (
                state.needs_restart <- true;
                process moves (Watcher.Linux.Queue_overflow :: reversed) rest)
              else if contains Inotify.Unmount kinds then (
                state.needs_restart <- true;
                process moves (Watcher.Linux.Watch_lost :: reversed) rest)
              else
                match find_watch state descriptor with
                | None when expected_removed state descriptor ->
                    if contains Inotify.Ignored kinds then
                      finish_expected_removal state descriptor;
                    process moves reversed rest
                | None ->
                    state.needs_restart <- true;
                    process moves (Watcher.Linux.Watch_lost :: reversed) rest
                | Some watch -> (
                    let path = event_path watch name in
                    match path with
                    | Error () ->
                        state.needs_restart <- true;
                        process moves
                          (Watcher.Linux.Watch_lost :: reversed)
                          rest
                    | Ok path when is_repository_metadata_path path ->
                        process moves reversed rest
                    | Ok _ when contains Inotify.Ignored kinds ->
                        state.watches <-
                          List.filter
                            (fun candidate ->
                              not (same_watch candidate.descriptor descriptor))
                            state.watches;
                        if watch.path = [] then (
                          state.needs_restart <- true;
                          process moves
                            (Watcher.Linux.Watch_lost :: reversed)
                            rest)
                        else process moves reversed rest
                    | Ok path
                      when contains Inotify.Delete_self kinds
                           || contains Inotify.Move_self kinds ->
                        drop_subtree state watch.path;
                        if watch.path = [] then (
                          state.needs_restart <- true;
                          process moves
                            (Watcher.Linux.Watch_lost :: reversed)
                            rest)
                        else
                          process moves
                            (Watcher.Linux.Deleted path :: reversed)
                            rest
                    | Ok path when contains Inotify.Moved_from kinds ->
                        process ((cookie, path) :: moves) reversed rest
                    | Ok path when contains Inotify.Moved_to kinds ->
                        let source, moves = take_move cookie moves in
                        let* () =
                          match source with
                          | Some source ->
                              rename_subtree state ~source ~destination:path;
                              Ok ()
                          | None when contains Inotify.Isdir kinds ->
                              watch_directory state path
                          | None -> Ok ()
                        in
                        let event =
                          match source with
                          | Some source ->
                              Watcher.Linux.Moved { source; destination = path }
                          | None -> Watcher.Linux.Created path
                        in
                        process moves (event :: reversed) rest
                    | Ok path when contains Inotify.Create kinds ->
                        let* () =
                          if contains Inotify.Isdir kinds then
                            watch_directory state path
                          else Ok ()
                        in
                        process moves
                          (Watcher.Linux.Created path :: reversed)
                          rest
                    | Ok path when contains Inotify.Delete kinds ->
                        if contains Inotify.Isdir kinds then
                          drop_subtree state path;
                        process moves
                          (Watcher.Linux.Deleted path :: reversed)
                          rest
                    | Ok path
                      when contains Inotify.Modify kinds
                           || contains Inotify.Attrib kinds
                           || contains Inotify.Close_write kinds ->
                        process moves
                          (Watcher.Linux.Changed path :: reversed)
                          rest
                    | Ok _ -> process moves reversed rest))
        in
        Result.fold ~ok:normalize
          ~error:(fun _ ->
            state.needs_restart <- true;
            normalize [ Watcher.Linux.Watch_lost ])
          (process [] [] raw_events)

let close state =
  if not state.closed then (
    state.closed <- true;
    state.watches <- [];
    state.expected_ignored <- [];
    try Unix.close state.fd with Unix.Unix_error _ -> ())
