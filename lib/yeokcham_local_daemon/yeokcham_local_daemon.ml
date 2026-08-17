module Cutover = Yeokcham_cutover
module Hash = Yeokcham_hash.Sha256

type operation = Ping | Shutdown
type runtime_location = Xdg_runtime of string | Fallback_runtime of string

type endpoint = {
  directory : string;
  socket_directory : string;
  identity : string;
}

type daemon = {
  endpoint : endpoint;
  listener : Unix.file_descr;
  capability : string;
  mutable closed : bool;
}

type error =
  | Root_unavailable of string
  | Runtime_path_rejected of string
  | Endpoint_busy of string
  | Stale_endpoint of string
  | Discovery_invalid of string
  | Protocol_invalid of string
  | Unauthorized
  | Invalid_idle_timeout of float
  | Worker_error of string
  | Io_error of { operation : string; path : string; message : string }

type serve_result = Continue | Stopped

let ( let* ) = Result.bind

let error_to_string = function
  | Root_unavailable detail -> "V2 daemon requires a ready V2 root: " ^ detail
  | Runtime_path_rejected path ->
      "runtime path is not private and usable: " ^ path
  | Endpoint_busy path -> "local daemon endpoint is already in use: " ^ path
  | Stale_endpoint path -> "local daemon endpoint is stale: " ^ path
  | Discovery_invalid detail -> "local daemon discovery is invalid: " ^ detail
  | Protocol_invalid detail -> "local daemon protocol is invalid: " ^ detail
  | Unauthorized -> "local daemon capability was rejected"
  | Invalid_idle_timeout timeout ->
      Printf.sprintf "daemon idle timeout must be finite and nonnegative: %g"
        timeout
  | Worker_error detail -> "local daemon worker failed: " ^ detail
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let io operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let hex bytes =
  let alphabet = "0123456789abcdef" in
  let result = Bytes.create (2 * String.length bytes) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set result (2 * index) alphabet.[value lsr 4];
      Bytes.set result ((2 * index) + 1) alphabet.[value land 15])
    bytes;
  Bytes.unsafe_to_string result

let is_hex value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let socket_path endpoint =
  Filename.concat endpoint.socket_directory ("y-" ^ endpoint.identity ^ ".sock")

let discovery_path endpoint =
  Filename.concat endpoint.directory ("y-" ^ endpoint.identity ^ ".discovery")

let secure_directory path =
  try
    let stat = Unix.lstat path in
    if
      stat.Unix.st_kind <> Unix.S_DIR
      || stat.Unix.st_uid <> Unix.getuid ()
      || stat.Unix.st_perm land 0o077 <> 0
    then Error (Runtime_path_rejected path)
    else Ok ()
  with Unix.Unix_error (error, _, _) -> Error (io "lstat" path error)

let ensure_private_directory path =
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  |> fun () -> secure_directory path

let short_socket_directory () =
  Filename.concat "/tmp" (Printf.sprintf "yeokcham-%d-sockets" (Unix.getuid ()))

let socket_path_for directory identity =
  Filename.concat directory ("y-" ^ identity ^ ".sock")

let runtime_path = function Xdg_runtime path | Fallback_runtime path -> path

let default_runtime_location () =
  match Sys.getenv_opt "XDG_RUNTIME_DIR" with
  | Some base when not (String.is_empty base) ->
      let* () = secure_directory base in
      let path = Filename.concat base "yeokcham" in
      let* () = ensure_private_directory path in
      Ok (Xdg_runtime path)
  | None | Some _ ->
      let path =
        Filename.concat
          (Filename.get_temp_dir_name ())
          (Printf.sprintf "yeokcham-%d" (Unix.getuid ()))
      in
      let* () = ensure_private_directory path in
      Ok (Fallback_runtime path)

let endpoint ~runtime_dir ~root =
  let* () = secure_directory runtime_dir in
  try
    let canonical_root = Unix.realpath root in
    let identity =
      Hash.digest_string canonical_root |> Hash.to_raw_string |> hex
      |> fun value -> String.sub value 0 32
    in
    let direct_socket = socket_path_for runtime_dir identity in
    let* socket_directory =
      if String.length direct_socket <= 90 then Ok runtime_dir
      else
        let directory = short_socket_directory () in
        let* () = ensure_private_directory directory in
        Ok directory
    in
    Ok { directory = runtime_dir; socket_directory; identity }
  with Unix.Unix_error (error, _, _) -> Error (io "realpath" root error)

let check_v2_root root =
  Cutover.detect ~root |> Result.map_error Cutover.error_to_string
  |> fun result ->
  Result.bind result (fun classification ->
      if classification = Cutover.V2 then Ok ()
      else Error (Cutover.classification_to_string classification))
  |> Result.map_error (fun detail -> Root_unavailable detail)

let write_all descriptor path bytes =
  let rec loop offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if count = 0 then
          Error
            (Io_error { operation = "write"; path; message = "zero-byte write" })
        else loop (offset + count)
      with Unix.Unix_error (error, _, _) -> Error (io "write" path error)
  in
  loop 0

let discovery_bytes endpoint capability =
  Printf.sprintf "yeokcham-local-discovery 1\nendpoint=%s\ncapability=%s\n"
    endpoint.identity capability

let publish_discovery endpoint capability =
  let path = discovery_path endpoint in
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        write_all descriptor path
          (Bytes.of_string (discovery_bytes endpoint capability)))
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Error (Endpoint_busy path)
  | Unix.Unix_error (error, _, _) -> Error (io "create discovery" path error)

let remove_if_kind path kind =
  try if (Unix.lstat path).Unix.st_kind = kind then Unix.unlink path
  with Unix.Unix_error _ -> ()

let start_listener ~root ~runtime_dir =
  let* endpoint = endpoint ~runtime_dir ~root in
  let path = socket_path endpoint in
  try
    let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> ())
      (fun () ->
        try
          Unix.bind listener (Unix.ADDR_UNIX path);
          Unix.listen listener 16;
          Mirage_crypto_rng_unix.use_default ();
          let capability = Mirage_crypto_rng.generate 32 |> hex in
          match publish_discovery endpoint capability with
          | Ok () -> Ok { endpoint; listener; capability; closed = false }
          | Error error ->
              Unix.close listener;
              remove_if_kind path Unix.S_SOCK;
              Error error
        with
        | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
            Unix.close listener;
            Error (Endpoint_busy path)
        | Unix.Unix_error (error, _, _) ->
            Unix.close listener;
            Error (io "bind local socket" path error))
  with Unix.Unix_error (error, _, _) ->
    Error (io "create local socket" path error)

let start ~root ~runtime_dir =
  let* () = check_v2_root root in
  start_listener ~root ~runtime_dir

let start_for_validated_root ~root ~runtime_dir =
  start_listener ~root ~runtime_dir

let close daemon =
  if not daemon.closed then (
    daemon.closed <- true;
    (try Unix.close daemon.listener with Unix.Unix_error _ -> ());
    remove_if_kind (socket_path daemon.endpoint) Unix.S_SOCK;
    remove_if_kind (discovery_path daemon.endpoint) Unix.S_REG)

let read_all descriptor path =
  let buffer = Bytes.create 4096 in
  let rec loop chunks total =
    if total > 4096 then Error (Protocol_invalid "message exceeds 4096 bytes")
    else
      try
        match Unix.read descriptor buffer 0 (Bytes.length buffer) with
        | 0 -> Ok (String.concat "" (List.rev chunks))
        | count ->
            loop (Bytes.sub_string buffer 0 count :: chunks) (total + count)
      with Unix.Unix_error (error, _, _) -> Error (io "read" path error)
  in
  loop [] 0

let parse_request capability = function
  | [ "yeokcham-local-request 1"; capability_line; operation_line; ""; "" ] ->
      if not (String.starts_with ~prefix:"capability=" capability_line) then
        Error (Protocol_invalid "invalid capability field")
      else
        let supplied =
          String.sub capability_line 11 (String.length capability_line - 11)
        in
        if not (is_hex supplied) then
          Error (Protocol_invalid "invalid capability field")
        else if not (String.equal supplied capability) then Error Unauthorized
        else if String.equal operation_line "operation=ping" then Ok Ping
        else if String.equal operation_line "operation=shutdown" then
          Ok Shutdown
        else Error (Protocol_invalid "invalid operation")
  | _ -> Error (Protocol_invalid "request framing")

let response result =
  if Result.is_ok result then "yeokcham-local-response 1\nstatus=ok\n"
  else if result = Error Unauthorized then
    "yeokcham-local-response 1\nstatus=unauthorized\n"
  else "yeokcham-local-response 1\nstatus=malformed\n"

let serve_once daemon =
  try
    let client, _ = Unix.accept daemon.listener in
    Fun.protect
      ~finally:(fun () -> try Unix.close client with Unix.Unix_error _ -> ())
      (fun () ->
        let result =
          read_all client (socket_path daemon.endpoint) |> fun result ->
          Result.bind result (fun bytes ->
              parse_request daemon.capability (String.split_on_char '\n' bytes))
        in
        let* () =
          write_all client
            (socket_path daemon.endpoint)
            (Bytes.of_string (response (Result.map (fun _ -> ()) result)))
        in
        match result with
        | Ok Shutdown ->
            close daemon;
            Ok Stopped
        | Ok Ping | Error _ -> Ok Continue)
  with Unix.Unix_error (error, _, _) ->
    Error (io "accept" (socket_path daemon.endpoint) error)

let serve daemon =
  let rec loop () =
    match serve_once daemon with
    | Ok Continue -> loop ()
    | Ok Stopped -> Ok ()
    | Error _ as error -> error
  in
  loop ()

let serve_with daemon ~idle_timeout ~on_idle =
  if
    classify_float idle_timeout = FP_nan
    || classify_float idle_timeout = FP_infinite
    || idle_timeout < 0.0
  then Error (Invalid_idle_timeout idle_timeout)
  else
    let rec loop () =
      if daemon.closed then Ok ()
      else
        let* () =
          on_idle () |> Result.map_error (fun detail -> Worker_error detail)
        in
        if daemon.closed then Ok ()
        else
          let* readable =
            try
              let readable, _, _ =
                Unix.select [ daemon.listener ] [] [] idle_timeout
              in
              Ok readable
            with Unix.Unix_error (error, _, _) ->
              Error
                (io "wait for local client" (socket_path daemon.endpoint) error)
          in
          match readable with
          | [] -> loop ()
          | _ -> (
              match serve_once daemon with
              | Ok Continue -> loop ()
              | Ok Stopped -> Ok ()
              | Error _ as error -> error)
    in
    loop ()

let read_discovery endpoint =
  let path = discovery_path endpoint in
  let* bytes =
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () -> read_all descriptor path)
    with Unix.Unix_error (error, _, _) ->
      Error (io "open discovery" path error)
  in
  match String.split_on_char '\n' bytes with
  | [ "yeokcham-local-discovery 1"; endpoint_line; capability_line; "" ]
    when String.equal endpoint_line ("endpoint=" ^ endpoint.identity) ->
      if not (String.starts_with ~prefix:"capability=" capability_line) then
        Error (Discovery_invalid path)
      else
        let capability =
          String.sub capability_line 11 (String.length capability_line - 11)
        in
        if is_hex capability then Ok capability
        else Error (Discovery_invalid path)
  | _ -> Error (Discovery_invalid path)

let request ~root ~runtime_dir operation =
  let* endpoint = endpoint ~runtime_dir ~root in
  let* capability = read_discovery endpoint in
  let path = socket_path endpoint in
  try
    let client = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close client)
      (fun () ->
        Unix.connect client (Unix.ADDR_UNIX path);
        let operation =
          match operation with Ping -> "ping" | Shutdown -> "shutdown"
        in
        let bytes =
          Printf.sprintf
            "yeokcham-local-request 1\ncapability=%s\noperation=%s\n\n"
            capability operation
        in
        let* () = write_all client path (Bytes.of_string bytes) in
        Unix.shutdown client Unix.SHUTDOWN_SEND;
        let* reply = read_all client path in
        if String.equal reply "yeokcham-local-response 1\nstatus=ok\n" then
          Ok ()
        else if
          String.equal reply "yeokcham-local-response 1\nstatus=unauthorized\n"
        then Error Unauthorized
        else Error (Protocol_invalid "response framing"))
  with Unix.Unix_error (error, _, _) ->
    Error (io "connect local socket" path error)

let ping ~root ~runtime_dir = request ~root ~runtime_dir Ping
let shutdown ~root ~runtime_dir = request ~root ~runtime_dir Shutdown

let recover_stale ~root ~runtime_dir =
  let* endpoint = endpoint ~runtime_dir ~root in
  let socket = socket_path endpoint and discovery = discovery_path endpoint in
  try
    let client = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close client)
      (fun () ->
        try
          Unix.connect client (Unix.ADDR_UNIX socket);
          Error (Endpoint_busy socket)
        with Unix.Unix_error ((Unix.ECONNREFUSED | Unix.ENOENT), _, _) ->
          if
            (Unix.lstat socket).Unix.st_kind <> Unix.S_SOCK
            || (Unix.lstat discovery).Unix.st_kind <> Unix.S_REG
          then Error (Discovery_invalid discovery)
          else (
            Unix.unlink socket;
            Unix.unlink discovery;
            Ok ()))
  with Unix.Unix_error (error, _, _) ->
    Error (io "recover local socket" socket error)
