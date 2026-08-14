module Authority = Yeokcham_v2_authority
module Cutover = Yeokcham_cutover
module Epoch = Yeokcham_v2_mls_epoch
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type publication = Published | Already_published

type error =
  | Cutover_error of Cutover.error
  | Not_v2_root of Cutover.classification
  | Epoch_error of Epoch.error
  | Missing_record of string
  | Invalid_record_path of string
  | Record_collision of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string

let metadata_name = ".yeokcham"
let directory_name = "mls-epochs"
let suffix = ".cbor"
let maximum_record_bytes = 48 * 1024
let maximum_temporary_attempts = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Not_v2_root classification ->
      "MLS epoch persistence requires a V2-only root, found "
      ^ Cutover.classification_to_string classification
  | Epoch_error error -> Epoch.error_to_string error
  | Missing_record path -> "MLS epoch record is missing: " ^ path
  | Invalid_record_path path -> "invalid MLS epoch record path: " ^ path
  | Record_collision path ->
      "MLS epoch record already contains different canonical bytes: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Temporary_name_exhausted directory ->
      "MLS epoch staging namespace is exhausted: " ^ directory

let directory ~root = Filename.concat (Filename.concat root metadata_name) directory_name
let filename id = Model.Mls_epoch_id.to_hex id ^ suffix
let path ~root id = Filename.concat (directory ~root) (filename id)

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let lstat path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"lstat" ~path error)

let check_v2_root root =
  let* classification =
    Cutover.detect ~root |> Result.map_error (fun error -> Cutover_error error)
  in
  match classification with
  | Cutover.V2 -> Ok ()
  | (Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _ | Cutover.Incomplete _) as classification ->
      Error (Not_v2_root classification)

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        try Unix.fsync descriptor; Ok () with
        | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _) -> Ok ()
        | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"fsync directory" ~path error))
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _) -> Ok ()
  | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"open directory for fsync" ~path error)

let rec ensure_directory directory =
  match lstat directory with
  | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Ok (Some _) -> Error (Invalid_record_path directory)
  | Error error -> Error error
  | Ok None ->
      (try Unix.mkdir directory 0o700; fsync_directory (Filename.dirname directory) with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_directory directory
      | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"mkdir" ~path:directory error))

let valid_hex value =
  String.length value = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let valid_record_name name =
  String.length name = 69 && String.ends_with ~suffix name && valid_hex (String.sub name 0 64)

let is_temporary name =
  let marker = ".cbor.stage-" in
  if String.length name <= 1 + 64 + String.length marker || name.[0] <> '.' then false
  else
    let body = String.sub name 1 (String.length name - 1) in
    if not (valid_hex (String.sub body 0 64))
       || not (String.equal (String.sub body 64 (String.length marker)) marker)
    then false
    else
      match
        String.sub body (64 + String.length marker)
          (String.length body - 64 - String.length marker)
        |> String.split_on_char '-'
      with
      | [ process; attempt ] ->
          String.length process > 0 && String.length attempt > 0
          && String.for_all (function '0' .. '9' -> true | _ -> false) process
          && String.for_all (function '0' .. '9' -> true | _ -> false) attempt
      | _ -> false

let entries directory =
  let* stat =
    match lstat directory with
    | Ok (Some stat) -> Ok stat
    | Ok None -> Error (Missing_record directory)
    | Error error -> Error error
  in
  if stat.Unix.st_kind <> Unix.S_DIR then Error (Invalid_record_path directory)
  else
    let* names =
      try Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare) with
      | Sys_error message -> Error (Io_error { operation = "read directory"; path = directory; message })
    in
    let rec validate records = function
      | [] -> Ok (List.rev records)
      | name :: rest ->
          let record_path = Filename.concat directory name in
          if not (valid_record_name name || is_temporary name) then Error (Invalid_record_path record_path)
          else
            let* stat =
              match lstat record_path with
              | Ok (Some stat) -> Ok stat
              | Ok None -> Error (Invalid_record_path record_path)
              | Error error -> Error error
            in
            if stat.Unix.st_kind <> Unix.S_REG then Error (Invalid_record_path record_path)
            else if valid_record_name name then validate (name :: records) rest
            else validate records rest
    in
    validate [] names

let read_regular record_path =
  let* stat =
    match lstat record_path with
    | Ok (Some stat) -> Ok stat
    | Ok None -> Error (Missing_record record_path)
    | Error error -> Error error
  in
  if stat.Unix.st_kind <> Unix.S_REG || stat.Unix.st_size > maximum_record_bytes then
    Error (Invalid_record_path record_path)
  else
    try
      let descriptor = Unix.openfile record_path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let bytes = Bytes.create stat.Unix.st_size in
          let rec read offset =
            if offset = stat.Unix.st_size then Ok ()
            else
              try
                let count = Unix.read descriptor bytes offset (stat.Unix.st_size - offset) in
                if count = 0 then Error (Invalid_record_path record_path) else read (offset + count)
              with Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"read" ~path:record_path error)
          in
          let* () = read 0 in
          let extra = Bytes.create 1 in
          let* count =
            try Ok (Unix.read descriptor extra 0 1) with
            | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"read" ~path:record_path error)
          in
          if count = 0 then Ok (Bytes.unsafe_to_string bytes) else Error (Invalid_record_path record_path))
    with Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"open" ~path:record_path error)

let write_all descriptor record_path bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count = Unix.write descriptor bytes offset (Bytes.length bytes - offset) in
        if count = 0 then Error (Invalid_record_path record_path) else write (offset + count)
      with Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"write" ~path:record_path error)
  in
  write 0

let temporary_path directory final attempt =
  Filename.concat directory (Printf.sprintf ".%s.stage-%d-%d" final (Unix.getpid ()) attempt)

let create_temporary directory final bytes =
  let rec create attempt =
    if attempt = maximum_temporary_attempts then Error (Temporary_name_exhausted directory)
    else
      let temporary = temporary_path directory final attempt in
      try
        let descriptor = Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () = write_all descriptor temporary bytes in
              try Unix.fsync descriptor; Ok () with
              | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"fsync" ~path:temporary error))
        in
        match result with
        | Ok () -> Ok temporary
        | Error error ->
            (try Unix.unlink temporary with Unix.Unix_error _ -> ());
            Error error
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"create" ~path:temporary error)
  in
  create 0

let cleanup directory temporary =
  try Unix.unlink temporary; fsync_directory directory with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"unlink" ~path:temporary error)

let publish ~directory ~final ~bytes =
  match lstat final with
  | Error error -> Error error
  | Ok (Some _) ->
      let* actual = read_regular final in
      if String.equal actual bytes then Ok Already_published else Error (Record_collision final)
  | Ok None ->
      let* temporary = create_temporary directory (Filename.basename final) (Bytes.of_string bytes) in
      let publication =
        try Unix.link temporary final; fsync_directory directory |> Result.map (fun () -> Published) with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok Already_published
        | Unix.Unix_error (error, _, _) -> Error (io_error ~operation:"publish" ~path:final error)
      in
      let cleanup_result = cleanup directory temporary in
      let* publication = publication in
      let* () = cleanup_result in
      let* actual = read_regular final in
      if String.equal actual bytes then Ok publication else Error (Record_collision final)

let write ~root ~authority transition =
  let bytes = Epoch.encode transition in
  let* checked = Epoch.decode ~authority bytes |> Result.map_error (fun error -> Epoch_error error) in
  let* () = check_v2_root root in
  let store_directory = directory ~root in
  let* () = ensure_directory store_directory in
  let* _ = entries store_directory in
  publish ~directory:store_directory ~final:(path ~root (Epoch.id checked)) ~bytes

let read_all ~root ~authority =
  let* () = check_v2_root root in
  let store_directory = directory ~root in
  let* names = entries store_directory in
  let rec read records = function
    | [] -> Ok (List.rev records)
    | name :: rest ->
        let record_path = Filename.concat store_directory name in
        let* bytes = read_regular record_path in
        let* record = Epoch.decode ~authority bytes |> Result.map_error (fun error -> Epoch_error error) in
        if String.equal name (filename (Epoch.id record)) then read (record :: records) rest
        else Error (Invalid_record_path record_path)
  in
  read [] names

let load_current ~runtime ~root ~authority ~state_key ~initial_state =
  let* records = read_all ~root ~authority in
  Epoch.verify_chain ~runtime ~authority ~state_key ~initial_state records
  |> Result.map_error (fun error -> Epoch_error error)
