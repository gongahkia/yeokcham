module Local_daemon = Yeokcham_local_daemon
module Peer_sync = Yeokcham_peer_sync
module Relay = Yeokcham_peer_sync_relay
module Ssh = Yeokcham_peer_sync_ssh
module Store = Yeokcham_store

type transport =
  | Local of {
      source_root : string;
      source_key : string;
      head : Yeokcham_id.Peer_sync_node_id.t;
    }
  | Relay of { relay : string }
  | Ssh of {
      known_hosts : string;
      ssh_config : string option;
      head : Yeokcham_id.Peer_sync_node_id.t;
    }

type configuration = {
  root : string;
  runtime_dir : string;
  contact_id : Yeokcham_id.Peer_contact_id.t;
  identity_id : Yeokcham_id.Peer_id.t;
  tracking_name : string;
  transport : transport;
}

type poll_status =
  | Waiting
  | No_current_update
  | Tracking_advanced
  | Tracking_already_current
  | Tracking_diverged
  | Failed
  | Stopped

type status = {
  status_kind : poll_status;
  status_attempts : int;
  status_detail : string;
  status_next_retry_at : float option;
}

type daemon = {
  configuration : configuration;
  local : Local_daemon.daemon;
  endpoint : Local_daemon.endpoint;
  destination : Store.repository;
  contact : Peer_sync.contact;
  identity : Peer_sync.identity;
  mutable status : status;
  mutable closed : bool;
}

type error =
  | Invalid_configuration of string
  | Private_key_error of string
  | Local_daemon_error of Local_daemon.error
  | Peer_error of Peer_sync.error
  | Relay_error of Relay.error
  | Ssh_error of Ssh.error
  | Store_error of Store.error
  | Status_error of string
  | Io_error of string

let max_retry_delay_seconds = 60.0
let initial_retry_delay_seconds = 1.0
let max_status_bytes = 2048
let max_status_detail_bytes = 512
let ( let* ) = Result.bind
let status_kind status = status.status_kind
let status_attempts status = status.status_attempts
let status_detail status = status.status_detail
let status_next_retry_at status = status.status_next_retry_at

let error_to_string = function
  | Invalid_configuration detail ->
      "invalid peer daemon configuration: " ^ detail
  | Private_key_error detail -> "invalid peer daemon private key: " ^ detail
  | Local_daemon_error error -> Local_daemon.error_to_string error
  | Peer_error error -> Peer_sync.error_to_string error
  | Relay_error error -> Relay.error_to_string error
  | Ssh_error error -> Ssh.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Status_error detail -> "invalid peer daemon status: " ^ detail
  | Io_error detail -> "peer daemon I/O error: " ^ detail

let valid_tracking_name name =
  (not (String.is_empty name))
  && String.length name <= 128
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
         | _ -> false)
       name

let valid_absolute_path path =
  (not (String.is_empty path))
  && (not (Filename.is_relative path))
  && String.length path <= 4096
  && not (String.contains path '\000')

let make_configuration ~root ~runtime_dir ~contact ~identity ~tracking_name
    ~transport =
  if not (valid_absolute_path root) then
    Error (Invalid_configuration "repository root must be absolute and bounded")
  else if not (valid_absolute_path runtime_dir) then
    Error
      (Invalid_configuration "runtime directory must be absolute and bounded")
  else if not (valid_tracking_name tracking_name) then
    Error (Invalid_configuration "tracking name is invalid")
  else
    let* () =
      match transport with
      | Local { source_root; source_key; _ } ->
          if not (valid_absolute_path source_root) then
            Error (Invalid_configuration "local source root must be absolute")
          else if not (valid_absolute_path source_key) then
            Error (Invalid_configuration "local source key must be absolute")
          else Ok ()
      | Relay { relay } ->
          if valid_absolute_path relay then Ok ()
          else Error (Invalid_configuration "relay directory must be absolute")
      | Ssh { known_hosts; ssh_config; _ } -> (
          if not (valid_absolute_path known_hosts) then
            Error (Invalid_configuration "known-hosts path must be absolute")
          else
            match ssh_config with
            | None -> Ok ()
            | Some path when valid_absolute_path path -> Ok ()
            | Some _ ->
                Error (Invalid_configuration "SSH config path must be absolute")
          )
    in
    Ok
      {
        root;
        runtime_dir;
        contact_id = contact;
        identity_id = identity;
        tracking_name;
        transport;
      }

let endpoint ~root ~runtime_dir =
  Local_daemon.endpoint ~root ~runtime_dir
  |> Result.map_error (fun error -> Local_daemon_error error)

let status_path ~root ~runtime_dir =
  let* endpoint = endpoint ~root ~runtime_dir in
  let discovery = Local_daemon.discovery_path endpoint in
  let suffix = ".discovery" in
  if not (String.ends_with ~suffix discovery) then
    Error (Status_error "local daemon discovery path has an unexpected suffix")
  else
    Ok
      (String.sub discovery 0 (String.length discovery - String.length suffix)
      ^ ".peer-sync-status")

let io operation path error =
  Io_error
    (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error))

let sanitise_detail detail =
  let detail =
    String.map
      (function '\n' | '\r' | '\000' -> ' ' | character -> character)
      detail
  in
  if String.length detail <= max_status_detail_bytes then detail
  else String.sub detail 0 max_status_detail_bytes

let status_name = function
  | Waiting -> "waiting"
  | No_current_update -> "no-current-update"
  | Tracking_advanced -> "tracking-advanced"
  | Tracking_already_current -> "tracking-already-current"
  | Tracking_diverged -> "tracking-diverged"
  | Failed -> "failed"
  | Stopped -> "stopped"

let poll_status_to_string = status_name

let status_of_name = function
  | "waiting" -> Some Waiting
  | "no-current-update" -> Some No_current_update
  | "tracking-advanced" -> Some Tracking_advanced
  | "tracking-already-current" -> Some Tracking_already_current
  | "tracking-diverged" -> Some Tracking_diverged
  | "failed" -> Some Failed
  | "stopped" -> Some Stopped
  | _ -> None

let status_bytes status =
  let retry =
    match status.status_next_retry_at with
    | None -> "none"
    | Some value -> Printf.sprintf "%.6f" value
  in
  Printf.sprintf
    "yeokcham-peer-daemon-status 1\n\
     state=%s\n\
     attempts=%d\n\
     next-retry=%s\n\
     detail=%s\n"
    (status_name status.status_kind)
    status.status_attempts retry
    (sanitise_detail status.status_detail)

let secure_regular_file path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then
      Error (Status_error "not a regular file")
    else if stat.Unix.st_uid <> Unix.getuid () then
      Error (Status_error "not owned by current user")
    else if stat.Unix.st_perm land 0o077 <> 0 then
      Error (Status_error "readable by group or other")
    else if stat.Unix.st_size > max_status_bytes then
      Error (Status_error "exceeds size bound")
    else Ok stat
  with Unix.Unix_error (error, _, _) -> Error (io "lstat status" path error)

let read_status_bytes path =
  let* before = secure_regular_file path in
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        let after = Unix.fstat descriptor in
        if
          after.Unix.st_kind <> Unix.S_REG
          || before.Unix.st_dev <> after.Unix.st_dev
          || before.Unix.st_ino <> after.Unix.st_ino
        then Error (Status_error "changed while opening")
        else
          let bytes = Bytes.create after.Unix.st_size in
          let rec read offset =
            if offset = after.Unix.st_size then Ok ()
            else
              try
                match
                  Unix.read descriptor bytes offset (after.Unix.st_size - offset)
                with
                | 0 -> Error (Status_error "ended before stated size")
                | count -> read (offset + count)
              with Unix.Unix_error (error, _, _) ->
                Error (io "read status" path error)
          in
          let* () = read 0 in
          let extra = Bytes.create 1 in
          let* count =
            try Ok (Unix.read descriptor extra 0 1)
            with Unix.Unix_error (error, _, _) ->
              Error (io "read status" path error)
          in
          if count = 0 then Ok (Bytes.unsafe_to_string bytes)
          else Error (Status_error "grew while reading"))
  with Unix.Unix_error (error, _, _) -> Error (io "open status" path error)

let parse_status bytes =
  match String.split_on_char '\n' bytes with
  | [
   "yeokcham-peer-daemon-status 1";
   state_line;
   attempts_line;
   retry_line;
   detail_line;
   "";
  ] -> (
      let value prefix line =
        if String.starts_with ~prefix line then
          Some
            (String.sub line (String.length prefix)
               (String.length line - String.length prefix))
        else None
      in
      match
        ( value "state=" state_line,
          value "attempts=" attempts_line,
          value "next-retry=" retry_line,
          value "detail=" detail_line )
      with
      | Some state, Some attempts, Some retry, Some detail -> (
          match (status_of_name state, int_of_string_opt attempts) with
          | Some status_kind, Some status_attempts when status_attempts >= 0
            -> (
              let status_next_retry_at =
                if String.equal retry "none" then Some None
                else
                  match float_of_string_opt retry with
                  | Some value
                    when classify_float value <> FP_nan
                         && classify_float value <> FP_infinite ->
                      Some (Some value)
                  | None | Some _ -> None
              in
              match status_next_retry_at with
              | None -> Error (Status_error "invalid next-retry value")
              | Some status_next_retry_at ->
                  Ok
                    {
                      status_kind;
                      status_attempts;
                      status_detail = detail;
                      status_next_retry_at;
                    })
          | None, _ -> Error (Status_error "invalid state")
          | _, None | _, Some _ -> Error (Status_error "invalid attempt count"))
      | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None ->
          Error (Status_error "missing status field"))
  | _ -> Error (Status_error "invalid status framing")

let read_status ~root ~runtime_dir =
  let* path = status_path ~root ~runtime_dir in
  let* bytes = read_status_bytes path in
  parse_status bytes

let write_all descriptor path bytes =
  let rec write offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if count = 0 then Error (Io_error ("zero-byte write to " ^ path))
        else write (offset + count)
      with Unix.Unix_error (error, _, _) ->
        Error (io "write status" path error)
  in
  write 0

let write_status path status =
  let directory = Filename.dirname path in
  let bytes = status_bytes status in
  let rec create_temporary attempt =
    if attempt = 64 then
      Error (Status_error "unable to allocate a private status temporary")
    else
      let temporary =
        Filename.concat directory
          (Printf.sprintf ".%s.tmp-%d-%d" (Filename.basename path)
             (Unix.getpid ()) attempt)
      in
      try
        Ok
          ( temporary,
            Unix.openfile temporary
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
              0o600 )
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create_temporary (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io "create status temporary" temporary error)
  in
  let* temporary, descriptor = create_temporary 0 in
  try
    let result =
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let* () = write_all descriptor temporary bytes in
          try
            Unix.fsync descriptor;
            Ok ()
          with Unix.Unix_error (error, _, _) ->
            Error (io "fsync status" temporary error))
    in
    match result with
    | Error _ as error ->
        (try Unix.unlink temporary with Unix.Unix_error _ -> ());
        error
    | Ok () ->
        Unix.rename temporary path;
        Ok ()
  with Unix.Unix_error (error, _, _) -> Error (io "publish status" path error)

let update_status daemon status =
  let* path =
    status_path ~root:daemon.configuration.root
      ~runtime_dir:daemon.configuration.runtime_dir
  in
  let* () = write_status path status in
  daemon.status <- status;
  Ok ()

let private_key path =
  if not (valid_absolute_path path) then
    Error (Private_key_error "path must be absolute")
  else
    try
      let before = Unix.lstat path in
      if before.Unix.st_kind <> Unix.S_REG then
        Error (Private_key_error "not a regular file")
      else if before.Unix.st_uid <> Unix.getuid () then
        Error (Private_key_error "not owned by current user")
      else if before.Unix.st_perm land 0o077 <> 0 then
        Error (Private_key_error "readable by group or other")
      else if before.Unix.st_size <> 32 then
        Error (Private_key_error "must contain exactly 32 bytes")
      else
        let descriptor =
          Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
        in
        Fun.protect
          ~finally:(fun () -> Unix.close descriptor)
          (fun () ->
            let after = Unix.fstat descriptor in
            if
              after.Unix.st_kind <> Unix.S_REG
              || before.Unix.st_dev <> after.Unix.st_dev
              || before.Unix.st_ino <> after.Unix.st_ino
            then Error (Private_key_error "changed while opening")
            else
              let bytes = Bytes.create 32 in
              let rec read offset =
                if offset = 32 then Ok ()
                else
                  try
                    match Unix.read descriptor bytes offset (32 - offset) with
                    | 0 -> Error (Private_key_error "ended before 32 bytes")
                    | count -> read (offset + count)
                  with Unix.Unix_error (error, _, _) ->
                    Error (io "read private key" path error)
              in
              let* () = read 0 in
              Mirage_crypto_ec.Ed25519.priv_of_octets
                (Bytes.unsafe_to_string bytes)
              |> Result.map_error (fun _ ->
                  Private_key_error "invalid Ed25519 private key"))
    with Unix.Unix_error (error, _, _) ->
      Error (io "open private key" path error)

let nonce () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Ok (Mirage_crypto_rng.generate Peer_sync.nonce_bytes)
  with _ -> Error (Private_key_error "OS CSPRNG is unavailable")

let local_transcript ~tracking_name ~head =
  "yeokcham:peer-sync:daemon-local:v1\000" ^ tracking_name ^ "\000"
  ^ Yeokcham_id.Peer_sync_node_id.to_bytes head

let direct_status = function
  | Peer_sync.Tracking_advanced _ -> Tracking_advanced
  | Peer_sync.Tracking_already_current _ -> Tracking_already_current
  | Peer_sync.Tracking_diverged _ -> Tracking_diverged

let configured_local_endpoint contact source_root =
  List.exists
    (function
      | Peer_sync.Local_path root -> String.equal root source_root
      | Peer_sync.Ssh _ | Peer_sync.Relay _ -> false)
    (Peer_sync.contact_endpoints contact)

let configured_relay_endpoint contact relay =
  List.exists
    (function
      | Peer_sync.Relay configured -> String.equal configured relay
      | Peer_sync.Local_path _ | Peer_sync.Ssh _ -> false)
    (Peer_sync.contact_endpoints contact)

let poll_local daemon ~source_root ~source_key ~head =
  if not (configured_local_endpoint daemon.contact source_root) then
    Error
      (Invalid_configuration
         "local source is not configured on the pinned contact")
  else
    let* source =
      Store.open_repository ~root:source_root
      |> Result.map_error (fun error -> Store_error error)
    in
    let* source_key = private_key source_key in
    let* nonce = nonce () in
    Peer_sync.sync_local ~source ~destination:daemon.destination
      ~contact:daemon.contact ~destination_identity:daemon.identity
      ~source_private_key:source_key ~nonce
      ~transcript:
        (local_transcript ~tracking_name:daemon.configuration.tracking_name
           ~head)
      ~tracking_name:daemon.configuration.tracking_name ~head ()
    |> Result.map (fun (_, decision) -> direct_status decision)
    |> Result.map_error (fun error -> Peer_error error)

let poll_ssh daemon ~known_hosts ~ssh_config ~head =
  let* nonce = nonce () in
  Ssh.sync_ssh ~destination:daemon.destination ~contact:daemon.contact
    ~destination_identity:daemon.identity ~known_hosts ?ssh_config ~nonce
    ~tracking_name:daemon.configuration.tracking_name ~head ()
  |> Result.map (fun (_, decision) -> direct_status decision)
  |> Result.map_error (fun error -> Ssh_error error)

let poll_relay daemon ~relay =
  if not (configured_relay_endpoint daemon.contact relay) then
    Error
      (Invalid_configuration "relay is not configured on the pinned contact")
  else
    let* advertisements =
      Relay.list_advertisements ~relay
        ~now:(Int64.of_float (Unix.gettimeofday ()))
      |> Result.map_error (fun error -> Relay_error error)
    in
    let advertisement =
      List.find_opt
        (fun advertisement ->
          Peer_sync.identity_equal
            (Relay.advertisement_sender advertisement)
            (Peer_sync.contact_identity daemon.contact)
          && Yeokcham_id.Peer_id.equal
               (Relay.advertisement_destination advertisement)
               (Peer_sync.peer_id daemon.identity)
          && String.equal
               (Relay.advertisement_tracking_name advertisement)
               daemon.configuration.tracking_name)
        advertisements
    in
    match advertisement with
    | None -> Ok No_current_update
    | Some advertisement -> (
        match
          Relay.import_advertisement ~destination:daemon.destination
            ~contact:daemon.contact ~destination_identity:daemon.identity ~relay
            ~tracking_name:daemon.configuration.tracking_name
            ~now:(Int64.of_float (Unix.gettimeofday ()))
            ~advertisement
        with
        | Ok decision -> Ok (direct_status decision)
        | Error error when Relay.is_replay_error error -> Ok No_current_update
        | Error error -> Error (Relay_error error))

let record_failure daemon error =
  let attempts = daemon.status.status_attempts + 1 in
  let delay =
    min max_retry_delay_seconds
      (initial_retry_delay_seconds
      *. (2.0 ** float_of_int (min 6 (attempts - 1))))
  in
  update_status daemon
    {
      status_kind = Failed;
      status_attempts = attempts;
      status_detail = sanitise_detail (error_to_string error);
      status_next_retry_at = Some (Unix.gettimeofday () +. delay);
    }

let poll_once daemon =
  if daemon.closed then Error (Invalid_configuration "daemon is closed")
  else
    let result =
      match daemon.configuration.transport with
      | Local { source_root; source_key; head } ->
          poll_local daemon ~source_root ~source_key ~head
      | Relay { relay } -> poll_relay daemon ~relay
      | Ssh { known_hosts; ssh_config; head } ->
          poll_ssh daemon ~known_hosts ~ssh_config ~head
    in
    match result with
    | Ok kind ->
        let* () =
          update_status daemon
            {
              status_kind = kind;
              status_attempts = 0;
              status_detail = "";
              status_next_retry_at = None;
            }
        in
        Ok kind
    | Error error ->
        let* () = record_failure daemon error in
        Error error

let start configuration =
  let* destination =
    Store.open_repository ~root:configuration.root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* contact =
    Peer_sync.load_contact destination configuration.contact_id
    |> Result.map_error (fun error -> Peer_error error)
  in
  let* identity =
    Peer_sync.load_identity destination configuration.identity_id
    |> Result.map_error (fun error -> Peer_error error)
  in
  let* endpoint =
    endpoint ~root:configuration.root ~runtime_dir:configuration.runtime_dir
  in
  let* local =
    Local_daemon.start_for_validated_root ~root:configuration.root
      ~runtime_dir:configuration.runtime_dir
    |> Result.map_error (fun error -> Local_daemon_error error)
  in
  let daemon =
    {
      configuration;
      local;
      endpoint;
      destination;
      contact;
      identity;
      status =
        {
          status_kind = Waiting;
          status_attempts = 0;
          status_detail = "";
          status_next_retry_at = None;
        };
      closed = false;
    }
  in
  match update_status daemon daemon.status with
  | Ok () -> Ok daemon
  | Error error ->
      Local_daemon.close local;
      Error error

let endpoint daemon = daemon.endpoint

let close daemon =
  if not daemon.closed then (
    daemon.closed <- true;
    Local_daemon.close daemon.local;
    ignore
      (update_status daemon
         {
           status_kind = Stopped;
           status_attempts = daemon.status.status_attempts;
           status_detail = "";
           status_next_retry_at = None;
         }))

let run daemon ~idle_timeout =
  if
    classify_float idle_timeout = FP_nan
    || classify_float idle_timeout = FP_infinite
    || idle_timeout <= 0.0
  then Error (Invalid_configuration "idle timeout must be positive and finite")
  else
    let on_idle () =
      if daemon.closed then Ok ()
      else
        match daemon.status.status_next_retry_at with
        | Some deadline when Unix.gettimeofday () < deadline -> Ok ()
        | None | Some _ -> (
            match poll_once daemon with Ok _ | Error _ -> Ok ())
    in
    let result =
      Local_daemon.serve_with daemon.local ~idle_timeout ~on_idle
      |> Result.map_error (fun error -> Local_daemon_error error)
    in
    match result with
    | Ok () ->
        close daemon;
        Ok ()
    | Error error ->
        ignore (record_failure daemon error);
        daemon.closed <- true;
        Local_daemon.close daemon.local;
        Error error

let ping ~root ~runtime_dir =
  Local_daemon.ping ~root ~runtime_dir
  |> Result.map_error (fun error -> Local_daemon_error error)

let shutdown ~root ~runtime_dir =
  Local_daemon.shutdown ~root ~runtime_dir
  |> Result.map_error (fun error -> Local_daemon_error error)

let recover_stale ~root ~runtime_dir =
  let* () =
    Local_daemon.recover_stale ~root ~runtime_dir
    |> Result.map_error (fun error -> Local_daemon_error error)
  in
  let* path = status_path ~root ~runtime_dir in
  try
    if (Unix.lstat path).Unix.st_kind = Unix.S_REG then Unix.unlink path;
    Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (error, _, _) -> Error (io "remove stale status" path error)
