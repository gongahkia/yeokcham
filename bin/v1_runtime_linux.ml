module Hash = Yeokcham_hash.Sha256
module Linux_watcher = Yeokcham_linux_watcher
module Model = Yeokcham_v1_model
module Service = Yeokcham_v1_local_service
module Sync = Yeokcham_v1_sync
module Watcher = Yeokcham_watcher
module Output = V1_cli_output

let runtime_environment = "XDG_RUNTIME_DIR"
let runtime_directory_name = "yeokcham-v1"
let state_file_name = "runtime-state-v1"
let lock_file_name = "runtime.lock"
let socket_file_name = "control.sock"
let log_file_name = "runtime.log"
let protocol = "yeokcham-runtime-v1"
let max_request_bytes = 256
let max_response_bytes = 4096
let max_detail_bytes = 1024
let start_timeout_seconds = 5.0
let max_unix_socket_path_bytes = 107
let minimum_runtime_key_bytes = 24
let ( let* ) = Result.bind

type paths = {
  root : string;
  directory : string;
  state : string;
  lock : string;
  socket : string;
  log : string;
}

type task = Idle | Syncing of string

type runtime_state = {
  pid : int;
  nonce : string;
  repository_root : string;
  watcher : string;
  task : task;
  last_result : string;
}

let fail message =
  Output.print_error message;
  exit 2

let hex_of_digest digest =
  let raw = Hash.to_raw_string digest in
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length raw * 2)
    (fun index ->
      let byte = Char.code raw.[index / 2] in
      if index mod 2 = 0 then alphabet.[byte lsr 4]
      else alphabet.[byte land 0x0f])

let absolute_runtime_directory () =
  match Sys.getenv_opt runtime_environment with
  | None | Some "" -> Error (runtime_environment ^ " is required")
  | Some path when Filename.is_relative path ->
      Error (runtime_environment ^ " must be an absolute path")
  | Some path -> (
      try
        let info = Unix.stat path in
        if info.Unix.st_kind <> Unix.S_DIR then
          Error (runtime_environment ^ " is not a directory")
        else if info.Unix.st_uid <> Unix.getuid () then
          Error (runtime_environment ^ " is not owned by this user")
        else if info.Unix.st_perm land 0o077 <> 0 then
          Error (runtime_environment ^ " must not be accessible to other users")
        else Ok path
      with Unix.Unix_error (error, operation, _) ->
        Error
          (Printf.sprintf "%s %s: %s" runtime_environment operation
             (Unix.error_message error)))

let mkdir_private path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> (
      try
        let info = Unix.stat path in
        if info.Unix.st_kind <> Unix.S_DIR then
          Error (path ^ " is not a directory")
        else if info.Unix.st_uid <> Unix.getuid () then
          Error (path ^ " is not owned by this user")
        else if info.Unix.st_perm land 0o077 <> 0 then
          Error (path ^ " must not be accessible to other users")
        else Ok ()
      with Unix.Unix_error (error, operation, _) ->
        Error
          (Printf.sprintf "inspect runtime directory %s: %s" operation
             (Unix.error_message error)))
  | Unix.Unix_error (error, operation, _) ->
      Error
        (Printf.sprintf "create runtime directory %s: %s" operation
           (Unix.error_message error))

let paths ~root =
  let* runtime_root = absolute_runtime_directory () in
  let* root =
    try Ok (Unix.realpath root)
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Printf.sprintf "canonicalize repository root %s: %s" operation
           (Unix.error_message error))
  in
  let* () =
    mkdir_private (Filename.concat runtime_root runtime_directory_name)
  in
  let digest =
    Hash.digest_string ("yeokcham-v1-runtime-root-v1\\000" ^ root)
    |> hex_of_digest
  in
  let directory_prefix = Filename.concat runtime_root runtime_directory_name in
  let available =
    max_unix_socket_path_bytes
    - String.length directory_prefix
    - 1 - 1
    - String.length socket_file_name
  in
  let key_length = Int.min 40 available in
  let* key =
    if key_length < minimum_runtime_key_bytes then
      Error
        (Printf.sprintf
           "%s is too long for a private Unix-domain control socket"
           runtime_environment)
    else Ok (String.sub digest 0 key_length)
  in
  let directory = Filename.concat directory_prefix key in
  let* () = mkdir_private directory in
  Ok
    {
      root;
      directory;
      state = Filename.concat directory state_file_name;
      lock = Filename.concat directory lock_file_name;
      socket = Filename.concat directory socket_file_name;
      log = Filename.concat directory log_file_name;
    }

let truncate value =
  if String.length value <= max_detail_bytes then value
  else String.sub value 0 max_detail_bytes ^ "…"

let bounded_state state =
  {
    state with
    repository_root = truncate state.repository_root;
    watcher = truncate state.watcher;
    last_result = truncate state.last_result;
  }

let escape value = Printf.sprintf "%S" (truncate value)

let task_name = function
  | Idle -> "idle"
  | Syncing remote -> "sync " ^ escape remote

let encode_state state =
  String.concat "\n"
    [
      "yeokcham-runtime-state-v1";
      "pid=" ^ string_of_int state.pid;
      "nonce=" ^ state.nonce;
      "root=" ^ escape state.repository_root;
      "watcher=" ^ escape state.watcher;
      "task=" ^ task_name state.task;
      "last-result=" ^ escape state.last_result;
      "";
    ]

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if count = 0 then Error "runtime state write returned zero"
        else loop (offset + count)
      with Unix.Unix_error (error, operation, _) ->
        Error
          (Printf.sprintf "runtime state %s: %s" operation
             (Unix.error_message error))
  in
  loop 0

let write_state paths state =
  let temporary =
    Filename.temp_file ~temp_dir:paths.directory ".runtime-state-" ".tmp"
  in
  try
    let descriptor =
      Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.close descriptor with Unix.Unix_error _ -> ());
        try Unix.unlink temporary
        with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (fun () ->
        let* () = write_all descriptor (encode_state state) in
        Unix.fsync descriptor;
        try
          Unix.rename temporary paths.state;
          Ok ()
        with Unix.Unix_error (error, operation, _) ->
          Error
            (Printf.sprintf "publish runtime state %s: %s" operation
               (Unix.error_message error)))
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "create runtime state %s: %s" operation
         (Unix.error_message error))

let read_limited path =
  try
    let info = Unix.stat path in
    if info.Unix.st_size > max_response_bytes then
      Error "runtime response is too large"
    else In_channel.with_open_bin path In_channel.input_all |> Result.ok
  with
  | Unix.Unix_error (error, operation, _) ->
      Error
        (Printf.sprintf "read runtime state %s: %s" operation
           (Unix.error_message error))
  | Sys_error message -> Error message

let write_response descriptor response =
  let response = protocol ^ " " ^ response ^ "\n" in
  write_all descriptor response

let read_request descriptor =
  let ready, _, _ = Unix.select [ descriptor ] [] [] 2.0 in
  if ready = [] then Error "runtime request timed out"
  else
    let bytes = Bytes.create max_request_bytes in
    try
      let count = Unix.read descriptor bytes 0 max_request_bytes in
      if count = 0 then Error "runtime request is empty"
      else if
        count = max_request_bytes
        || not (String.contains (Bytes.sub_string bytes 0 count) '\n')
      then Error "runtime request is too large or incomplete"
      else
        let value = Bytes.sub_string bytes 0 count |> String.trim in
        match String.split_on_char ' ' value with
        | version :: command :: arguments when String.equal version protocol ->
            Ok (command, arguments)
        | _ -> Error "invalid runtime request"
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Printf.sprintf "read runtime request %s: %s" operation
           (Unix.error_message error))

let connect paths request =
  try
    let descriptor = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        Unix.connect descriptor (Unix.ADDR_UNIX paths.socket);
        let* () = write_all descriptor (protocol ^ " " ^ request ^ "\n") in
        let ready, _, _ = Unix.select [ descriptor ] [] [] 10.0 in
        if ready = [] then Error "runtime response timed out"
        else
          let buffer = Buffer.create 256 in
          let bytes = Bytes.create 256 in
          let rec read_response () =
            let count = Unix.read descriptor bytes 0 (Bytes.length bytes) in
            if count = 0 then
              if Buffer.length buffer = 0 then
                Error "runtime closed the control connection"
              else Ok (Buffer.contents buffer |> String.trim)
            else if Buffer.length buffer + count > max_response_bytes then
              Error "runtime response is too large"
            else (
              Buffer.add_subbytes buffer bytes 0 count;
              read_response ())
          in
          read_response ())
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "connect to runtime %s: %s" operation
         (Unix.error_message error))

let remove_if_present path =
  try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let acquire_lock path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
    try
      Unix.lockf descriptor Unix.F_TLOCK 0;
      Ok descriptor
    with Unix.Unix_error (error, operation, _) ->
      Unix.close descriptor;
      Error
        (Printf.sprintf "runtime lock is held or unavailable (%s: %s)" operation
           (Unix.error_message error))
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "open runtime lock %s: %s" operation
         (Unix.error_message error))

let open_listener paths =
  remove_if_present paths.socket;
  try
    let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Unix.bind listener (Unix.ADDR_UNIX paths.socket);
    Unix.chmod paths.socket 0o600;
    Unix.listen listener 8;
    Ok listener
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "start runtime control socket %s: %s" operation
         (Unix.error_message error))

let ignorable request =
  match request.Watcher.target with
  | Watcher.Whole_root -> false
  | Watcher.Paths paths ->
      List.for_all
        (function ".git" :: _ | ".yeokcham" :: _ -> true | _ -> false)
        paths

let lost request =
  match request.Watcher.reason with
  | Watcher.Overflow | Watcher.Watcher_lost | Watcher.Path_budget_exceeded ->
      true
  | Watcher.Initial_scan | Watcher.Path_change | Watcher.Rename
  | Watcher.Rescan_required ->
      false

let capture root =
  match Service.save ~root with
  | Ok (Service.Unchanged _) -> "capture unchanged"
  | Ok (Service.Saved status) ->
      "capture saved " ^ Model.Snapshot_id.to_string status.Service.checkpoint
  | Error error -> "capture failed " ^ Service.error_to_string error

let start_watcher root =
  match Linux_watcher.start ~root with
  | Ok watcher -> Ok watcher
  | Error error -> Error (Linux_watcher.error_to_string error)

let load_signing_capability root device =
  V1_signer.load ~root device |> Result.map_error V1_signer.error_to_string

let update paths state =
  let state = bounded_state state in
  match write_state paths state with Ok () -> state | Error _ -> state

let valid_remote_name remote =
  String.length remote > 0
  && String.length remote <= 64
  && not
       (String.exists
          (function '\000' | '\r' | '\n' | ' ' | '\t' -> true | _ -> false)
          remote)

let handle_request paths state command arguments =
  match (command, arguments) with
  | "status", [] -> (`Continue, state, "ok\n" ^ encode_state state)
  | "stop", [] -> (
      match state.task with
      | Idle -> (`Stop, state, "ok stopping")
      | Syncing remote -> (`Continue, state, "busy sync " ^ escape remote))
  | "sync", [ remote ] when not (valid_remote_name remote) ->
      (`Continue, state, "error invalid runtime remote name")
  | "sync", [ remote ] -> (
      match state.task with
      | Syncing active -> (`Continue, state, "busy sync " ^ escape active)
      | Idle ->
          let state = update paths { state with task = Syncing remote } in
          let response, state =
            match
              Sync.run ~root:paths.root ~remote
                ~load_signing_capability:(load_signing_capability paths.root)
            with
            | Ok report ->
                let upload =
                  match report.Sync.upload with
                  | Sync.Uploaded count -> "uploaded " ^ string_of_int count
                  | Sync.Pending detail -> "upload-pending " ^ truncate detail
                in
                ( "ok received "
                  ^ string_of_int report.Sync.received_revisions
                  ^ " " ^ upload,
                  {
                    state with
                    task = Idle;
                    last_result = "sync " ^ remote ^ " " ^ upload;
                  } )
            | Error error ->
                let detail = Sync.error_to_string error |> truncate in
                ( "error " ^ detail,
                  {
                    state with
                    task = Idle;
                    last_result = "sync " ^ remote ^ " failed " ^ detail;
                  } )
          in
          (`Continue, update paths state, response))
  | _ -> (`Continue, state, "error invalid runtime command")

let poll_control listener paths state =
  let ready, _, _ = Unix.select [ listener ] [] [] 0.0 in
  if ready = [] then (`Continue, state)
  else
    let descriptor, _ = Unix.accept listener in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        match read_request descriptor with
        | Error detail ->
            ignore (write_response descriptor ("error " ^ truncate detail));
            (`Continue, state)
        | Ok (command, arguments) ->
            let action, state, response =
              handle_request paths state command arguments
            in
            ignore (write_response descriptor response);
            (action, state))

let run ~root =
  let paths = paths ~root |> Result.fold ~ok:Fun.id ~error:fail in
  ignore
    (Service.inspection_state ~root
    |> Result.map_error Service.error_to_string
    |> Result.fold ~ok:(fun _ -> ()) ~error:fail);
  let lock = acquire_lock paths.lock |> Result.fold ~ok:Fun.id ~error:fail in
  Fun.protect
    ~finally:(fun () -> try Unix.close lock with Unix.Unix_error _ -> ())
    (fun () ->
      let listener =
        open_listener paths |> Result.fold ~ok:Fun.id ~error:fail
      in
      Fun.protect
        ~finally:(fun () ->
          (try Unix.close listener with Unix.Unix_error _ -> ());
          remove_if_present paths.socket;
          remove_if_present paths.state)
        (fun () ->
          let nonce =
            Hash.digest_string
              (Printf.sprintf "yeokcham-v1-runtime-nonce-v1\\000%d\\000%.9f"
                 (Unix.getpid ()) (Unix.gettimeofday ()))
            |> hex_of_digest
          in
          let state =
            {
              pid = Unix.getpid ();
              nonce;
              repository_root = paths.root;
              watcher = "starting";
              task = Idle;
              last_result = capture paths.root;
            }
            |> update paths
          in
          let watcher =
            start_watcher paths.root |> Result.fold ~ok:Fun.id ~error:fail
          in
          let[@warning "-4"] rec loop watcher window state =
            let control, state = poll_control listener paths state in
            match control with
            | `Stop -> ()
            | `Continue -> (
                match Linux_watcher.poll watcher ~timeout:0.2 with
                | Error Linux_watcher.Needs_restart | Error Linux_watcher.Closed
                  -> (
                    Linux_watcher.close watcher;
                    let state =
                      {
                        state with
                        watcher = "restarting";
                        last_result = capture paths.root;
                      }
                      |> update paths
                    in
                    match start_watcher paths.root with
                    | Ok watcher ->
                        loop watcher Service.Capture_window.clear state
                    | Error detail ->
                        Unix.sleep 1;
                        loop watcher window
                          ({
                             state with
                             watcher = "retrying";
                             last_result = detail;
                           }
                          |> update paths))
                | Error error ->
                    Unix.sleepf 0.2;
                    loop watcher window
                      ({
                         state with
                         watcher = "degraded";
                         last_result = Linux_watcher.error_to_string error;
                       }
                      |> update paths)
                | Ok None ->
                    let now = Unix.gettimeofday () in
                    if Service.Capture_window.due window ~now then
                      loop watcher Service.Capture_window.clear
                        ({
                           state with
                           watcher = "watching";
                           last_result = capture paths.root;
                         }
                        |> update paths)
                    else loop watcher window state
                | Ok (Some request) when ignorable request ->
                    loop watcher window state
                | Ok (Some request) when lost request -> (
                    Linux_watcher.close watcher;
                    let state =
                      {
                        state with
                        watcher = "restarting";
                        last_result = capture paths.root;
                      }
                      |> update paths
                    in
                    match start_watcher paths.root with
                    | Ok watcher ->
                        loop watcher Service.Capture_window.clear state
                    | Error detail ->
                        Unix.sleep 1;
                        loop watcher window
                          ({
                             state with
                             watcher = "retrying";
                             last_result = detail;
                           }
                          |> update paths))
                | Ok (Some _) ->
                    let now = Unix.gettimeofday () in
                    let window = Service.Capture_window.observe window ~now in
                    if Service.Capture_window.due window ~now then
                      loop watcher Service.Capture_window.clear
                        ({
                           state with
                           watcher = "watching";
                           last_result = capture paths.root;
                         }
                        |> update paths)
                    else loop watcher window state)
          in
          Fun.protect
            ~finally:(fun () -> Linux_watcher.close watcher)
            (fun () ->
              loop watcher Service.Capture_window.empty
                ({ state with watcher = "watching" } |> update paths))))

let wait_until_ready paths =
  let deadline = Unix.gettimeofday () +. start_timeout_seconds in
  let rec loop () =
    match connect paths "status" with
    | Ok response when String.starts_with ~prefix:(protocol ^ " ok") response ->
        Ok ()
    | Ok _ | Error _ ->
        if Unix.gettimeofday () >= deadline then
          Error "runtime did not become ready within five seconds"
        else (
          Unix.sleepf 0.05;
          loop ())
  in
  loop ()

let start ~root =
  let paths = paths ~root |> Result.fold ~ok:Fun.id ~error:fail in
  match connect paths "status" with
  | Ok _ -> fail "V1 runtime is already running"
  | Error _ ->
      let executable =
        try Unix.realpath Sys.executable_name
        with Unix.Unix_error _ -> Sys.executable_name
      in
      let log =
        Unix.openfile paths.log
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
          0o600
      in
      let null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0o600 in
      let launcher = Unix.fork () in
      if launcher = 0 then (
        (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
        match Unix.fork () with
        | 0 ->
            Unix.dup2 null Unix.stdin;
            Unix.dup2 log Unix.stdout;
            Unix.dup2 log Unix.stderr;
            Unix.close null;
            Unix.close log;
            Unix.execv executable
              [| executable; "daemon"; "run"; "--root"; paths.root |]
        | _ -> exit 0)
      else (
        Unix.close null;
        Unix.close log;
        ignore (Unix.waitpid [] launcher);
        wait_until_ready paths
        |> Result.fold
             ~ok:(fun () -> Output.print_endline "runtime started")
             ~error:(fun detail ->
               let detail =
                 match read_limited paths.log with
                 | Ok "" | Error _ -> detail
                 | Ok log -> detail ^ "\nruntime log:\n" ^ log
               in
               fail detail))

let status ~root =
  let paths = paths ~root |> Result.fold ~ok:Fun.id ~error:fail in
  match connect paths "status" with
  | Ok response -> Output.print_endline response
  | Error detail -> (
      match read_limited paths.state with
      | Ok state ->
          Output.print_string
            (Printf.sprintf "runtime unreachable %s\n%s" detail state)
      | Error _ -> fail "V1 runtime is not running")

let stop ~root =
  let paths = paths ~root |> Result.fold ~ok:Fun.id ~error:fail in
  connect paths "stop" |> Result.fold ~ok:Output.print_endline ~error:fail

let sync ~root ~remote =
  let paths = paths ~root |> Result.fold ~ok:Fun.id ~error:fail in
  if not (valid_remote_name remote) then fail "invalid runtime remote name";
  connect paths ("sync " ^ remote)
  |> Result.fold
       ~ok:(fun response ->
         if String.starts_with ~prefix:(protocol ^ " error ") response then
           fail response
         else Output.print_endline response)
       ~error:fail
