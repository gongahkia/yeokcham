module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Cutover = Yeokcham_cutover
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Runtime = Yeokcham_v2_mls_runtime

type initialization = Initialized | Already_initialized

type error =
  | Cutover_error of Cutover.error
  | Not_v2_root of Cutover.classification
  | Bootstrap_store_error of Bootstrap_store.error
  | Bootstrap_error of Bootstrap.error
  | Bootstrap_mismatch
  | Group_error of Group.error
  | Missing_group_state of string
  | Invalid_group_path of string
  | Unexpected_group_entry of string
  | Group_already_initialized of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string
  | Entropy_failure

let filename = "group-state-v1.cbor"
let metadata_name = ".yeokcham"
let directory_name = "mls-group"
let max_temporary_attempts = 32
let max_file_bytes = Envelope.max_ciphertext_bytes + 256
let ( let* ) = Result.bind

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Not_v2_root classification ->
      "V2 MLS group persistence requires a V2-only root, found "
      ^ Cutover.classification_to_string classification
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Bootstrap_mismatch ->
      "injected bootstrap differs from the canonical repository bootstrap"
  | Group_error error -> Group.error_to_string error
  | Missing_group_state path -> "MLS group state is missing: " ^ path
  | Invalid_group_path path -> "invalid MLS group state path: " ^ path
  | Unexpected_group_entry path ->
      "unexpected MLS group directory entry: " ^ path
  | Group_already_initialized path ->
      "MLS group state already contains different canonical state: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Temporary_name_exhausted directory ->
      "MLS group staging namespace is exhausted: " ^ directory
  | Entropy_failure -> "OS CSPRNG unavailable while encrypting MLS group state"

let group_directory ~root =
  Filename.concat (Filename.concat root metadata_name) directory_name

let group_path ~root = Filename.concat (group_directory ~root) filename

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let lstat path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

let check_v2_root root =
  let* classification =
    Cutover.detect ~root |> Result.map_error (fun error -> Cutover_error error)
  in
  match classification with
  | Cutover.V2 -> Ok ()
  | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
    | Cutover.Incomplete _ ) as classification ->
      Error (Not_v2_root classification)

let is_decimal value =
  String.length value > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) value

let is_temporary_filename name =
  let prefix = "." ^ filename ^ ".bootstrap-" in
  let prefix_length = String.length prefix in
  if
    String.length name <= prefix_length || not (String.starts_with ~prefix name)
  then false
  else
    match
      String.sub name prefix_length (String.length name - prefix_length)
      |> String.split_on_char '-'
    with
    | [ process; attempt ] -> is_decimal process && is_decimal attempt
    | _ -> false

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.fsync descriptor;
        Ok ())
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"fsync" ~path error)

let rec ensure_group_directory ~root =
  let directory = group_directory ~root in
  match lstat directory with
  | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok directory
  | Ok (Some _) -> Error (Invalid_group_path directory)
  | Error error -> Error error
  | Ok None -> (
      try
        Unix.mkdir directory 0o700;
        let* () = fsync_directory (Filename.dirname directory) in
        Ok directory
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_group_directory ~root
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"mkdir" ~path:directory error))

let group_directory_entries ~root =
  let directory = group_directory ~root in
  let* stat =
    match lstat directory with
    | Ok (Some stat) -> Ok stat
    | Ok None -> Error (Missing_group_state (group_path ~root))
    | Error error -> Error error
  in
  if stat.Unix.st_kind <> Unix.S_DIR then Error (Invalid_group_path directory)
  else
    let* names =
      try Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
      with Sys_error message ->
        Error
          (Io_error { operation = "read directory"; path = directory; message })
    in
    let rec validate = function
      | [] -> Ok ()
      | name :: rest ->
          let path = Filename.concat directory name in
          if not (String.equal name filename || is_temporary_filename name) then
            Error (Unexpected_group_entry path)
          else
            let* stat =
              match lstat path with
              | Ok (Some stat) -> Ok stat
              | Ok None -> Error (Invalid_group_path path)
              | Error error -> Error error
            in
            if stat.Unix.st_kind <> Unix.S_REG then
              Error (Invalid_group_path path)
            else validate rest
    in
    validate names

let read_regular_file path =
  let* stat =
    match lstat path with
    | Ok (Some stat) -> Ok stat
    | Ok None -> Error (Missing_group_state path)
    | Error error -> Error error
  in
  if stat.Unix.st_kind <> Unix.S_REG || stat.Unix.st_size > max_file_bytes then
    Error (Invalid_group_path path)
  else
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let bytes = Bytes.create stat.Unix.st_size in
          let rec read offset =
            if offset = stat.Unix.st_size then Ok ()
            else
              try
                let count =
                  Unix.read descriptor bytes offset (stat.Unix.st_size - offset)
                in
                if count = 0 then Error (Invalid_group_path path)
                else read (offset + count)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"read" ~path error)
          in
          let* () = read 0 in
          let extra = Bytes.create 1 in
          let* extra_count =
            try Ok (Unix.read descriptor extra 0 1)
            with Unix.Unix_error (error, _, _) ->
              Error (io_error ~operation:"read" ~path error)
          in
          if extra_count = 0 then Ok (Bytes.unsafe_to_string bytes)
          else Error (Invalid_group_path path))
    with Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"open" ~path error)

let write_all descriptor path bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if count = 0 then Error (Invalid_group_path path)
        else write (offset + count)
      with Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"write" ~path error)
  in
  write 0

let temporary_path directory attempt =
  Filename.concat directory
    (Printf.sprintf ".%s.bootstrap-%d-%d" filename (Unix.getpid ()) attempt)

let create_temporary directory bytes =
  let rec create attempt =
    if attempt = max_temporary_attempts then
      Error (Temporary_name_exhausted directory)
    else
      let path = temporary_path directory attempt in
      try
        let descriptor =
          Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () = write_all descriptor path bytes in
              try
                Unix.fsync descriptor;
                Ok ()
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"fsync" ~path error))
        in
        match result with
        | Ok () -> Ok path
        | Error error ->
            (try Unix.unlink path with Unix.Unix_error _ -> ());
            Error error
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"create" ~path error)
  in
  create 0

let cleanup_temporary ~directory path =
  try
    Unix.unlink path;
    fsync_directory directory
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"unlink" ~path error)

let checked_bootstrap ~root repository =
  let bootstrap = Bootstrap_store.bootstrap repository in
  let capability = Bootstrap_store.capability repository in
  let* () =
    Bootstrap.validate_capability ~capability bootstrap
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* durable =
    Bootstrap_store.read_bootstrap ~root
    |> Result.map_error (fun error -> Bootstrap_store_error error)
  in
  if String.equal (Bootstrap.encode durable) (Bootstrap.encode bootstrap) then
    Ok repository
  else Error Bootstrap_mismatch

let check_group_binding bootstrap state =
  if
    not
      (Yeokcham_v2_model.Repository_id.equal
         (Group.repository_id state)
         (Bootstrap.repository_id bootstrap))
  then
    Error (Group_error (Group.Group_binding_mismatch "bootstrap repository ID"))
  else if
    not
      (Yeokcham_v2_model.Device_id.equal (Group.device_id state)
         (Bootstrap.device_id bootstrap))
  then Error (Group_error (Group.Group_binding_mismatch "bootstrap device ID"))
  else Ok ()

let generate_nonce () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.generate 12
    |> Envelope.nonce_of_bytes
    |> Result.map_error (fun _ -> Entropy_failure)
  with _ -> Error Entropy_failure

let open_bytes ~runtime ~bootstrap bytes =
  let* envelope =
    Envelope.decode bytes
    |> Result.map_error (fun error -> Group_error (Group.Envelope_error error))
  in
  let* state =
    Group.open_state
      ~key:(Bootstrap.envelope_key (Bootstrap_store.capability bootstrap))
      envelope
    |> Result.map_error (fun error -> Group_error error)
  in
  let* () = check_group_binding (Bootstrap_store.bootstrap bootstrap) state in
  Group.verify ~runtime state
  |> Result.map_error (fun error -> Group_error error)
  |> Result.map (fun () -> state)

let read ~runtime ~root ~bootstrap =
  let* () = check_v2_root root in
  let* bootstrap = checked_bootstrap ~root bootstrap in
  let* () = group_directory_entries ~root in
  let* bytes = read_regular_file (group_path ~root) in
  open_bytes ~runtime ~bootstrap bytes

let initialize ~runtime ~root ~bootstrap state =
  let* () = check_v2_root root in
  let* bootstrap = checked_bootstrap ~root bootstrap in
  let* () = check_group_binding (Bootstrap_store.bootstrap bootstrap) state in
  let* () =
    Group.verify ~runtime state
    |> Result.map_error (fun error -> Group_error error)
  in
  let* directory = ensure_group_directory ~root in
  let* () = group_directory_entries ~root |> Result.map (fun () -> ()) in
  let final = group_path ~root in
  match lstat final with
  | Error error -> Error error
  | Ok (Some _) ->
      let* actual = read_regular_file final in
      let* actual = open_bytes ~runtime ~bootstrap actual in
      if String.equal (Group.encode actual) (Group.encode state) then
        Ok Already_initialized
      else Error (Group_already_initialized final)
  | Ok None -> (
      let* nonce = generate_nonce () in
      let* envelope =
        Group.seal_state
          ~key:(Bootstrap.envelope_key (Bootstrap_store.capability bootstrap))
          ~nonce state
        |> Result.map_error (fun error -> Group_error error)
      in
      let expected = Envelope.encode envelope in
      let* temporary = create_temporary directory (Bytes.of_string expected) in
      let publication =
        try
          Unix.link temporary final;
          fsync_directory directory |> Result.map (fun () -> `Published)
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok `Already_present
        | Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"publish" ~path:final error)
      in
      let cleanup = cleanup_temporary ~directory temporary in
      match publication with
      | Error error ->
          ignore cleanup;
          Error error
      | Ok publication ->
          let* () = cleanup in
          let* actual = read_regular_file final in
          let* actual = open_bytes ~runtime ~bootstrap actual in
          if String.equal (Group.encode actual) (Group.encode state) then
            Ok
              (match publication with
              | `Published -> Initialized
              | `Already_present -> Already_initialized)
          else Error (Group_already_initialized final))
