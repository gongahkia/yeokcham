module Store = Yeokcham_store
module Envelope = Yeokcham_envelope
module Transport = Yeokcham_v1_transport

type repository = { root : string }
type kind = Object | Manifest | Publication | Bootstrap

type error =
  | Invalid_repository of string
  | Invalid_identifier of string
  | Invalid_cursor of string
  | Invalid_limit of int
  | Invalid_object of string
  | Already_exists_with_different_bytes of string
  | Missing of string
  | Io_error of { path : string; operation : string; message : string }

let max_body_bytes = 64 * 1024 * 1024
let max_page_size = 128
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_repository value -> "invalid V1 relay repository ID: " ^ value
  | Invalid_identifier value -> "invalid V1 relay object ID: " ^ value
  | Invalid_cursor value -> "invalid V1 relay continuation cursor: " ^ value
  | Invalid_limit value ->
      Printf.sprintf "invalid V1 relay page limit: %d" value
  | Invalid_object detail -> "invalid V1 relay immutable bytes: " ^ detail
  | Already_exists_with_different_bytes id ->
      "V1 relay immutable ID already has different bytes: " ^ id
  | Missing id -> "V1 relay immutable ID is absent: " ^ id
  | Io_error { path; operation; message } ->
      Printf.sprintf "V1 relay %s %s: %s" operation path message

let[@warning "-4"] is_missing = function Missing _ -> true | _ -> false

let[@warning "-4"] is_immutable_conflict = function
  | Already_exists_with_different_bytes _ -> true
  | _ -> false

let valid_hex value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let check_project project =
  if valid_hex project then Ok () else Error (Invalid_repository project)

let check_id id = if valid_hex id then Ok () else Error (Invalid_identifier id)

let kind_name = function
  | Object -> "objects"
  | Manifest -> "manifests"
  | Publication -> "publications"
  | Bootstrap -> "bootstraps"

let project_path repository project = Filename.concat repository.root project

let kind_path repository project kind =
  Filename.concat (project_path repository project) (kind_name kind)

let item_path repository project kind id =
  Filename.concat (kind_path repository project kind) id

let mkdir path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })

let open_repository ~root =
  if Sys.file_exists root then
    try
      if (Unix.lstat root).Unix.st_kind = Unix.S_DIR then Ok { root }
      else
        Error
          (Io_error
             { path = root; operation = "open"; message = "not a directory" })
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Io_error { path = root; operation; message = Unix.error_message error })
  else
    let* () = mkdir root in
    Ok { root }

let read_limited path =
  try
    let info = Unix.lstat path in
    if info.Unix.st_kind <> Unix.S_REG then
      Error (Invalid_object "stored relay entry is not a regular file")
    else if info.Unix.st_size > max_body_bytes then
      Error (Invalid_object "stored relay entry exceeds body limit")
    else In_channel.with_open_bin path In_channel.input_all |> Result.ok
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error (Missing (Filename.basename path))
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })
  | Sys_error message -> Error (Io_error { path; operation = "read"; message })

let validate_bytes kind id bytes =
  if String.length bytes > max_body_bytes then
    Error (Invalid_object "request body exceeds relay limit")
  else
    match kind with
    | Manifest | Publication | Bootstrap ->
        if String.equal (Transport.sha256 bytes) id then Ok ()
        else Error (Invalid_object "route ID does not match SHA-256 bytes")
    | Object ->
        let* object_ =
          Envelope.decode bytes
          |> Result.map_error (fun error ->
              Invalid_object (Envelope.decode_error_to_string error))
        in
        if not (String.equal bytes (Envelope.encode object_)) then
          Error (Invalid_object "object bytes are not canonical")
        else
          let actual =
            Store.id_of_envelope object_ |> Store.Stored_object_id.to_hex
          in
          if String.equal actual id then Ok ()
          else Error (Invalid_object "route ID does not match object identity")

let ensure_kind_path repository project kind =
  let* () = mkdir (project_path repository project) in
  mkdir (kind_path repository project kind)

let write_exclusive path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let rec write offset =
      if offset = String.length bytes then Ok ()
      else
        try
          let count =
            Unix.write_substring descriptor bytes offset
              (String.length bytes - offset)
          in
          if count = 0 then
            Error
              (Io_error
                 { path; operation = "write"; message = "write returned zero" })
          else write (offset + count)
        with Unix.Unix_error (error, operation, _) ->
          Error
            (Io_error { path; operation; message = Unix.error_message error })
    in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () -> write 0)
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })

let create repository ~project ~kind ~id ~bytes =
  let* () = check_project project in
  let* () = check_id id in
  let* () = validate_bytes kind id bytes in
  let* () = ensure_kind_path repository project kind in
  let path = item_path repository project kind id in
  let compare_existing () =
    match read_limited path with
    | Ok existing when String.equal existing bytes -> Ok ()
    | Ok _ -> Error (Already_exists_with_different_bytes id)
    | Error error -> Error error
  in
  if Sys.file_exists path then compare_existing ()
  else
    match write_exclusive path bytes with
    | Ok () -> Ok ()
    | Error error ->
        if Sys.file_exists path then compare_existing () else Error error

let get repository ~project ~kind ~id =
  let* () = check_project project in
  let* () = check_id id in
  let path = item_path repository project kind id in
  let* bytes = read_limited path in
  let* () = validate_bytes kind id bytes in
  Ok bytes

let list_publications repository ~project ~cursor ~limit =
  let* () = check_project project in
  if limit <= 0 || limit > max_page_size then Error (Invalid_limit limit)
  else
    let* () =
      match cursor with
      | None -> Ok ()
      | Some cursor ->
          if valid_hex cursor then Ok () else Error (Invalid_cursor cursor)
    in
    let directory = kind_path repository project Publication in
    let names =
      try Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
      with Sys_error _ -> Ok []
    in
    let* names = names in
    let* () =
      List.fold_left
        (fun result id ->
          let* () = result in
          if valid_hex id then Ok ()
          else
            Error
              (Invalid_object "relay publication directory contains unsafe name"))
        (Ok ()) names
    in
    let after_cursor =
      match cursor with
      | None -> names
      | Some cursor ->
          List.filter (fun id -> String.compare id cursor > 0) names
    in
    let rec take remaining reversed = function
      | [] -> List.rev reversed
      | _ when remaining = 0 -> List.rev reversed
      | id :: rest -> take (remaining - 1) (id :: reversed) rest
    in
    let selected = take limit [] after_cursor in
    let next =
      if List.length after_cursor > List.length selected then
        match List.rev selected with [] -> None | id :: _ -> Some id
      else None
    in
    Ok (selected, next)

let relay_error_to_string = error_to_string

module V2 = struct
  module Transfer = Transport.V2

  type cleanup = { expired_sessions : int; reclaimed_bytes : int }

  type error =
    | Invalid_expiry
    | Invalid_quota
    | Invalid_session_id of string
    | Session_missing of string
    | Session_binding_mismatch
    | Duplicate_segment_mismatch
    | Corrupt_session of string
    | Session_io_error of {
        path : string;
        operation : string;
        message : string;
      }
    | Transfer_error of Transfer.error
    | Relay_error of string
    | Entropy_failure

  let default_expiry_seconds = 900L
  let max_expiry_seconds = 86_400L
  let default_project_quota_bytes = 256 * 1024 * 1024
  let max_project_quota_bytes = 512 * 1024 * 1024
  let metadata_suffix = ".cbor"
  let raw_suffix = ".raw"
  let session_directory_name = ".v2-transfer-sessions"
  let max_metadata_bytes = 1024 * 1024
  let ( let* ) = Result.bind

  let error_to_string = function
    | Invalid_expiry -> "invalid V2 relay session expiry"
    | Invalid_quota -> "invalid V2 relay project temporary-byte quota"
    | Invalid_session_id value -> "invalid V2 relay session ID: " ^ value
    | Session_missing value -> "V2 relay session is absent: " ^ value
    | Session_binding_mismatch ->
        "V2 relay session does not match project, credential, or upload scope"
    | Duplicate_segment_mismatch ->
        "V2 relay duplicate segment bytes do not match the received range"
    | Corrupt_session detail -> "corrupt V2 relay session: " ^ detail
    | Session_io_error { path; operation; message } ->
        Printf.sprintf "V2 relay session %s %s: %s" operation path message
    | Transfer_error error -> Transfer.error_to_string error
    | Relay_error detail -> "V2 relay immutable publication failed: " ^ detail
    | Entropy_failure -> "V2 relay session ID CSPRNG is unavailable"

  let[@warning "-4"] is_session_missing = function
    | Session_missing _ -> true
    | _ -> false

  let io_error path operation error =
    Session_io_error { path; operation; message = Unix.error_message error }

  let session_root repository =
    Filename.concat repository.root session_directory_name

  let project_directory repository project =
    Filename.concat (session_root repository) project

  let metadata_path repository project session_id =
    Filename.concat
      (project_directory repository project)
      (session_id ^ metadata_suffix)

  let raw_path repository project session_id =
    Filename.concat
      (project_directory repository project)
      (session_id ^ raw_suffix)

  let ensure_directory path =
    if Sys.file_exists path then
      try
        if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then Ok ()
        else
          Error
            (Session_io_error
               { path; operation = "open"; message = "not a directory" })
      with Unix.Unix_error (error, operation, _) ->
        Error (io_error path operation error)
    else
      try
        Unix.mkdir path 0o700;
        Ok ()
      with Unix.Unix_error (error, operation, _) ->
        Error (io_error path operation error)

  let ensure_project_directory repository project =
    let* () = ensure_directory (session_root repository) in
    ensure_directory (project_directory repository project)

  let write_all descriptor path bytes =
    let rec loop offset =
      if offset = String.length bytes then Ok ()
      else
        try
          let written =
            Unix.write_substring descriptor bytes offset
              (String.length bytes - offset)
          in
          if written = 0 then
            Error
              (Session_io_error
                 { path; operation = "write"; message = "write returned zero" })
          else loop (offset + written)
        with Unix.Unix_error (error, operation, _) ->
          Error (io_error path operation error)
    in
    loop 0

  let fsync descriptor path =
    try
      Unix.fsync descriptor;
      Ok ()
    with Unix.Unix_error (error, operation, _) ->
      Error (io_error path operation error)

  let fsync_directory path =
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close descriptor with Unix.Unix_error _ -> ())
        (fun () -> fsync descriptor path)
    with Unix.Unix_error (error, operation, _) ->
      Error (io_error path operation error)

  let write_metadata_new path bytes =
    try
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      let result =
        Fun.protect
          ~finally:(fun () ->
            try Unix.close descriptor with Unix.Unix_error _ -> ())
          (fun () ->
            let* () = write_all descriptor path bytes in
            fsync descriptor path)
      in
      let* () = result in
      fsync_directory (Filename.dirname path)
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) ->
        Error (Corrupt_session ("session metadata already exists: " ^ path))
    | Unix.Unix_error (error, operation, _) ->
        Error (io_error path operation error)

  let write_metadata path bytes =
    let directory = Filename.dirname path in
    let temporary =
      Filename.temp_file ~temp_dir:directory ".v2-session-" ".tmp"
    in
    try
      let descriptor =
        Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      let result =
        Fun.protect
          ~finally:(fun () ->
            try Unix.close descriptor with Unix.Unix_error _ -> ())
          (fun () ->
            let* () = write_all descriptor temporary bytes in
            fsync descriptor temporary)
      in
      match result with
      | Error error ->
          (try Unix.unlink temporary with Unix.Unix_error _ -> ());
          Error error
      | Ok () ->
          Unix.rename temporary path;
          fsync_directory directory
    with Unix.Unix_error (error, operation, _) ->
      (try Unix.unlink temporary with Unix.Unix_error _ -> ());
      Error (io_error path operation error)

  let create_raw path raw_size =
    try
      let descriptor =
        Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      let result =
        Fun.protect
          ~finally:(fun () ->
            try Unix.close descriptor with Unix.Unix_error _ -> ())
          (fun () ->
            try
              Unix.ftruncate descriptor raw_size;
              fsync descriptor path
            with Unix.Unix_error (error, operation, _) ->
              Error (io_error path operation error))
      in
      let* () = result in
      fsync_directory (Filename.dirname path)
    with Unix.Unix_error (error, operation, _) ->
      Error (io_error path operation error)

  let read_file_limited path limit =
    try
      let info = Unix.lstat path in
      if info.Unix.st_kind <> Unix.S_REG then
        Error (Corrupt_session (path ^ " is not a regular file"))
      else if info.Unix.st_size > limit then
        Error (Corrupt_session (path ^ " exceeds its size bound"))
      else In_channel.with_open_bin path In_channel.input_all |> Result.ok
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
        Error (Session_missing (Filename.basename path))
    | Unix.Unix_error (error, operation, _) ->
        Error (io_error path operation error)
    | Sys_error message ->
        Error (Session_io_error { path; operation = "read"; message })

  let check_session_id value =
    if valid_hex value then Ok () else Error (Invalid_session_id value)

  let decode_session bytes =
    Transfer.decode_session bytes
    |> Result.map_error (fun error ->
        Corrupt_session (Transfer.error_to_string error))

  let check_raw_size path expected =
    try
      let info = Unix.lstat path in
      if info.Unix.st_kind <> Unix.S_REG then
        Error (Corrupt_session (path ^ " is not a regular file"))
      else if info.Unix.st_size <> expected then
        Error (Corrupt_session "temporary raw file has the wrong size")
      else Ok ()
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
        Error (Session_missing (Filename.basename path))
    | Unix.Unix_error (error, operation, _) ->
        Error (io_error path operation error)

  let load_session repository ~project ~session_id =
    let* () =
      check_project project
      |> Result.map_error (fun error ->
          Relay_error (relay_error_to_string error))
    in
    let* () = check_session_id session_id in
    let metadata = metadata_path repository project session_id in
    let* bytes = read_file_limited metadata max_metadata_bytes in
    let* session = decode_session bytes in
    if
      (not (String.equal (Transfer.session_id session) session_id))
      || not
           (String.equal
              (Transfer.offer_project (Transfer.session_offer session))
              project)
    then Error (Corrupt_session "metadata path and session binding disagree")
    else
      let raw = raw_path repository project session_id in
      let* () =
        check_raw_size raw
          (Transfer.offer_raw_size (Transfer.session_offer session))
      in
      Ok session

  let list_project_ids repository project =
    let directory = project_directory repository project in
    if not (Sys.file_exists directory) then Ok []
    else
      try
        if (Unix.lstat directory).Unix.st_kind <> Unix.S_DIR then
          Error (Corrupt_session (directory ^ " is not a directory"))
        else
          let ids =
            Sys.readdir directory |> Array.to_list
            |> List.filter_map (fun name ->
                if String.ends_with ~suffix:metadata_suffix name then
                  let id =
                    String.sub name 0
                      (String.length name - String.length metadata_suffix)
                  in
                  Some id
                else None)
            |> List.sort String.compare
          in
          Ok ids
      with Unix.Unix_error (error, operation, _) ->
        Error (io_error directory operation error)

  let remove_if_present path =
    try
      Unix.unlink path;
      Ok ()
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
    | Unix.Unix_error (error, operation, _) ->
        Error (io_error path operation error)

  let remove_session repository ~project ~session_id =
    let directory = project_directory repository project in
    let* () = remove_if_present (metadata_path repository project session_id) in
    let* () = remove_if_present (raw_path repository project session_id) in
    fsync_directory directory

  let session_is_expired ~now session =
    Int64.compare now (Transfer.session_expires_at session) >= 0

  let inspect_project repository ~now ~project =
    let* ids = list_project_ids repository project in
    let rec loop sessions expired reclaimed = function
      | [] ->
          Ok
            ( List.rev sessions,
              { expired_sessions = expired; reclaimed_bytes = reclaimed } )
      | session_id :: rest ->
          let* () = check_session_id session_id in
          let* session = load_session repository ~project ~session_id in
          let size = Transfer.offer_raw_size (Transfer.session_offer session) in
          if session_is_expired ~now session then
            let* () = remove_session repository ~project ~session_id in
            loop sessions (expired + 1) (reclaimed + size) rest
          else loop (session :: sessions) expired reclaimed rest
    in
    loop [] 0 0 ids

  let random_session_id () =
    try
      Mirage_crypto_rng_unix.use_default ();
      Ok (Transport.sha256 (Mirage_crypto_rng.generate 32))
    with _ -> Error Entropy_failure

  let valid_expiry value =
    Int64.compare value 0L > 0 && Int64.compare value max_expiry_seconds <= 0

  let valid_quota value = value > 0 && value <= max_project_quota_bytes

  let start_upload repository ~now ~project ~object_id ~raw_size ~credential_id
      ~expires_in ~project_quota_bytes =
    let* () =
      check_project project
      |> Result.map_error (fun error ->
          Relay_error (relay_error_to_string error))
    in
    if not (valid_expiry expires_in) then Error Invalid_expiry
    else if not (valid_quota project_quota_bytes) then Error Invalid_quota
    else
      let* offer =
        Transfer.object_offer ~project ~object_id ~raw_size
        |> Result.map_error (fun error -> Transfer_error error)
      in
      let* () = ensure_project_directory repository project in
      let* active, _ = inspect_project repository ~now ~project in
      let active_bytes =
        List.fold_left
          (fun total session ->
            total + Transfer.offer_raw_size (Transfer.session_offer session))
          0 active
      in
      if raw_size > project_quota_bytes - active_bytes then
        Error (Transfer_error Transfer.Quota_exceeded)
      else
        let credential_session_count =
          List.length
            (List.filter
               (fun session ->
                 String.equal
                   (Transfer.session_credential_id session)
                   credential_id)
               active)
        in
        let* expires_at =
          let value = Int64.add now expires_in in
          if Int64.compare value now <= 0 then Error Invalid_expiry
          else Ok value
        in
        let rec create attempts =
          if attempts = 0 then Error Entropy_failure
          else
            let* id = random_session_id () in
            let* session =
              Transfer.session ~id ~offer ~credential_id ~scope:Transfer.Upload
                ~expires_at ~quota_bytes:project_quota_bytes
                ~credential_session_count
              |> Result.map_error (fun error -> Transfer_error error)
            in
            let metadata = metadata_path repository project id in
            let raw = raw_path repository project id in
            if Sys.file_exists metadata || Sys.file_exists raw then
              create (attempts - 1)
            else
              let* () = create_raw raw raw_size in
              let result =
                Transfer.encode_session session
                |> Result.map_error (fun error -> Transfer_error error)
                |> fun result ->
                Result.bind result (write_metadata_new metadata)
              in
              match result with
              | Ok () -> Ok session
              | Error error ->
                  let* () = remove_if_present raw in
                  Error error
        in
        create 4

  let check_binding ~now ~project ~credential_id session =
    if session_is_expired ~now session then
      Error (Transfer_error Transfer.Session_expired)
    else if
      (not
         (String.equal
            (Transfer.offer_project (Transfer.session_offer session))
            project))
      || (not
            (String.equal
               (Transfer.session_credential_id session)
               credential_id))
      || Transfer.session_scope session <> Transfer.Upload
    then Error Session_binding_mismatch
    else Ok ()

  let resume_upload repository ~now ~project ~session_id ~credential_id =
    let* session = load_session repository ~project ~session_id in
    let* () = check_binding ~now ~project ~credential_id session in
    Ok session

  let find_range session ~offset ~length =
    List.find_opt
      (fun range ->
        Transfer.range_offset range = offset
        && Transfer.range_length range = length)
      (Transfer.session_ranges session)

  let range_received session range =
    Transfer.session_progress session
    |> Transfer.progress_ranges
    |> List.exists (fun received ->
        Transfer.range_offset received = Transfer.range_offset range
        && Transfer.range_length received = Transfer.range_length range)

  let read_range path ~offset ~length =
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close descriptor with Unix.Unix_error _ -> ())
        (fun () ->
          ignore
            (Unix.LargeFile.lseek descriptor (Int64.of_int offset) Unix.SEEK_SET);
          let bytes = Bytes.create length in
          let rec loop position =
            if position = length then Ok (Bytes.unsafe_to_string bytes)
            else
              match Unix.read descriptor bytes position (length - position) with
              | 0 -> Error (Corrupt_session "temporary raw file is truncated")
              | count -> loop (position + count)
          in
          loop 0)
    with Unix.Unix_error (error, operation, _) ->
      Error (io_error path operation error)

  let write_range path ~offset bytes =
    try
      let descriptor = Unix.openfile path [ Unix.O_RDWR ] 0 in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close descriptor with Unix.Unix_error _ -> ())
        (fun () ->
          ignore
            (Unix.LargeFile.lseek descriptor (Int64.of_int offset) Unix.SEEK_SET);
          let* () = write_all descriptor path bytes in
          fsync descriptor path)
    with Unix.Unix_error (error, operation, _) ->
      Error (io_error path operation error)

  let receive_upload_segment repository ~now ~project ~session_id ~credential_id
      ~offset ~length ~raw_sha256 ~bytes =
    let* session =
      resume_upload repository ~now ~project ~session_id ~credential_id
    in
    if length < 0 || String.length bytes <> length then
      Error (Transfer_error Transfer.Range_failure)
    else if not (String.equal raw_sha256 (Transport.sha256 bytes)) then
      Error (Transfer_error Transfer.Identity_failure)
    else
      match find_range session ~offset ~length with
      | None -> Error (Transfer_error Transfer.Range_failure)
      | Some range ->
          let* segment =
            Transfer.segment ~range ~raw_sha256
            |> Result.map_error (fun error -> Transfer_error error)
          in
          let raw = raw_path repository project session_id in
          if range_received session range then
            let* existing = read_range raw ~offset ~length in
            if String.equal existing bytes then
              Ok (Transfer.session_progress session)
            else Error Duplicate_segment_mismatch
          else
            let* () = write_range raw ~offset bytes in
            let* updated =
              Transfer.receive_segment ~now ~session segment
              |> Result.map_error (fun error -> Transfer_error error)
            in
            let* encoded =
              Transfer.encode_session updated
              |> Result.map_error (fun error -> Transfer_error error)
            in
            let* () =
              write_metadata
                (metadata_path repository project session_id)
                encoded
            in
            Ok (Transfer.session_progress updated)

  let complete_upload repository ~now ~project ~session_id ~credential_id =
    let* session =
      resume_upload repository ~now ~project ~session_id ~credential_id
    in
    let* () =
      Transfer.completion_eligible ~now session
      |> Result.map_error (fun error -> Transfer_error error)
    in
    let raw = raw_path repository project session_id in
    let* bytes = read_file_limited raw Transfer.max_raw_object_bytes in
    let offer = Transfer.session_offer session in
    if String.length bytes <> Transfer.offer_raw_size offer then
      Error (Corrupt_session "temporary raw file has the wrong size")
    else
      let* () =
        create repository ~project ~kind:Object
          ~id:(Transfer.offer_object_id offer)
          ~bytes
        |> Result.map_error (fun error ->
            Relay_error (relay_error_to_string error))
      in
      remove_session repository ~project ~session_id

  let cleanup_expired repository ~now =
    let root = session_root repository in
    if not (Sys.file_exists root) then
      Ok { expired_sessions = 0; reclaimed_bytes = 0 }
    else
      try
        if (Unix.lstat root).Unix.st_kind <> Unix.S_DIR then
          Error (Corrupt_session (root ^ " is not a directory"))
        else
          let projects =
            Sys.readdir root |> Array.to_list |> List.sort String.compare
          in
          let rec loop expired reclaimed = function
            | [] ->
                Ok { expired_sessions = expired; reclaimed_bytes = reclaimed }
            | project :: rest ->
                let* () =
                  if valid_hex project then Ok ()
                  else
                    Error
                      (Corrupt_session "session root contains an unsafe project")
                in
                let* _, cleaned = inspect_project repository ~now ~project in
                loop
                  (expired + cleaned.expired_sessions)
                  (reclaimed + cleaned.reclaimed_bytes)
                  rest
          in
          loop 0 0 projects
      with Unix.Unix_error (error, operation, _) ->
        Error (io_error root operation error)
end
