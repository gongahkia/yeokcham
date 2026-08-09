module Bootstrap = Yeokcham_v2_bootstrap
module Cutover = Yeokcham_cutover

type repository = { bootstrap : Bootstrap.t; capability : Bootstrap.capability }
type initialization = Initialized | Already_initialized

type error =
  | Cutover_error of Cutover.error
  | Not_v2_root of Cutover.classification
  | Bootstrap_error of Bootstrap.error
  | Missing_bootstrap of string
  | Invalid_bootstrap_path of string
  | Unexpected_bootstrap_entry of string
  | Bootstrap_already_initialized of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string

let filename = "local-bootstrap-v2.cbor"
let metadata_name = ".yeokcham"
let directory_name = "bootstrap"
let max_temporary_attempts = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Not_v2_root classification ->
      "V2 local bootstrap requires a V2-only root, found "
      ^ Cutover.classification_to_string classification
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Missing_bootstrap path -> "local bootstrap is missing: " ^ path
  | Invalid_bootstrap_path path -> "invalid local bootstrap path: " ^ path
  | Unexpected_bootstrap_entry path ->
      "unexpected local bootstrap directory entry: " ^ path
  | Bootstrap_already_initialized path ->
      "local bootstrap already contains different canonical bytes: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Temporary_name_exhausted directory ->
      "local bootstrap staging namespace is exhausted: " ^ directory

let bootstrap_directory ~root =
  Filename.concat (Filename.concat root metadata_name) directory_name

let bootstrap_path ~root = Filename.concat (bootstrap_directory ~root) filename

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let check_v2_root root =
  let* classification =
    Cutover.detect ~root |> Result.map_error (fun error -> Cutover_error error)
  in
  match classification with
  | Cutover.V2 -> Ok ()
  | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
    | Cutover.Incomplete _ ) as classification ->
      Error (Not_v2_root classification)

let lstat path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

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

let bootstrap_directory_entries ~root =
  let directory = bootstrap_directory ~root in
  let* stat =
    match lstat directory with
    | Ok (Some stat) -> Ok stat
    | Ok None -> Error (Invalid_bootstrap_path directory)
    | Error error -> Error error
  in
  if stat.Unix.st_kind <> Unix.S_DIR then
    Error (Invalid_bootstrap_path directory)
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
            Error (Unexpected_bootstrap_entry path)
          else
            let* stat =
              match lstat path with
              | Ok (Some stat) -> Ok stat
              | Ok None -> Error (Invalid_bootstrap_path path)
              | Error error -> Error error
            in
            if stat.Unix.st_kind <> Unix.S_REG then
              Error (Invalid_bootstrap_path path)
            else validate rest
    in
    let* () = validate names in
    Ok directory

let read_regular_file path =
  let* stat =
    match lstat path with
    | Ok (Some stat) -> Ok stat
    | Ok None -> Error (Missing_bootstrap path)
    | Error error -> Error error
  in
  if stat.Unix.st_kind <> Unix.S_REG then Error (Invalid_bootstrap_path path)
  else if stat.Unix.st_size > Bootstrap.max_bootstrap_bytes then
    Error (Invalid_bootstrap_path path)
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
                if count = 0 then Error (Invalid_bootstrap_path path)
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
          else Error (Invalid_bootstrap_path path))
    with Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"open" ~path error)

let read_bootstrap ~root =
  let* () = check_v2_root root in
  let* () = bootstrap_directory_entries ~root |> Result.map (fun _ -> ()) in
  let path = bootstrap_path ~root in
  let* bytes = read_regular_file path in
  Bootstrap.decode bytes
  |> Result.map_error (fun error -> Bootstrap_error error)

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

let write_all descriptor path bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if count = 0 then Error (Invalid_bootstrap_path path)
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

let initialize ~root bootstrap =
  let* () = check_v2_root root in
  let* directory = bootstrap_directory_entries ~root in
  let final = bootstrap_path ~root in
  let expected = Bootstrap.encode bootstrap in
  match lstat final with
  | Error error -> Error error
  | Ok (Some _) ->
      let* actual = read_regular_file final in
      if String.equal actual expected then Ok Already_initialized
      else Error (Bootstrap_already_initialized final)
  | Ok None -> (
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
          if String.equal actual expected then
            Ok
              (match publication with
              | `Published -> Initialized
              | `Already_present -> Already_initialized)
          else Error (Bootstrap_already_initialized final))

let open_repository ~root ~capability =
  let* bootstrap = read_bootstrap ~root in
  let* () =
    Bootstrap.validate_capability ~capability bootstrap
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  Ok { bootstrap; capability }

let bootstrap repository = repository.bootstrap
let capability repository = repository.capability
