module Bundle = Paengi_bundle
module Bundle_store = Paengi_bundle_store
module Object_id = Paengi_store.Stored_object_id

type partial = { partial_name : string; partial_size : int }

type complete = {
  complete_directory : string;
  complete_name : string;
  complete_size : int;
}

type entry = Partial of partial | Complete of complete
type inspection = { object_ids : Object_id.t list }

type error =
  | Directory_not_directory of string
  | Directory_io_error of {
      operation : string;
      path : string;
      message : string;
    }
  | Unsafe_entry of { path : string; detail : string }
  | File_too_large of { path : string; size : int; limit : int }
  | File_size_changed of string
  | Partial_not_importable of string
  | Name_collision_exhausted of int
  | Entropy_failure of string
  | Published_partial_retained of {
      complete_name : string;
      partial_name : string;
      detail : string;
    }
  | Bundle_error of Bundle.error
  | Bundle_store_error of Bundle_store.error

let max_file_bytes = Bundle.max_ciphertext_bytes + 128
let max_name_attempts = 16
let partial_prefix = ".paengi-bundle-v1-"
let partial_suffix = ".partial"
let complete_prefix = "paengi-bundle-v1-"
let complete_suffix = ".peng"
let token_length = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Directory_not_directory path ->
      "bundle directory is not a directory: " ^ path
  | Directory_io_error { operation; path; message } ->
      Printf.sprintf "bundle directory %s failed for %s: %s" operation path
        message
  | Unsafe_entry { path; detail } ->
      Printf.sprintf "unsafe bundle directory entry %s: %s" path detail
  | File_too_large { path; size; limit } ->
      Printf.sprintf "bundle file %s is %d bytes; limit is %d" path size limit
  | File_size_changed path -> "bundle file changed while reading: " ^ path
  | Partial_not_importable name -> "partial bundle is not importable: " ^ name
  | Name_collision_exhausted attempts ->
      Printf.sprintf "bundle filename collision after %d attempts" attempts
  | Entropy_failure detail -> "bundle directory entropy failure: " ^ detail
  | Published_partial_retained { complete_name; partial_name; detail } ->
      Printf.sprintf "published %s but retained %s: %s" complete_name
        partial_name detail
  | Bundle_error error -> Bundle.error_to_string error
  | Bundle_store_error error -> Bundle_store.error_to_string error

let io_error operation path error =
  Directory_io_error { operation; path; message = Unix.error_message error }

let entry_name = function
  | Partial value -> value.partial_name
  | Complete value -> value.complete_name

let entry_size = function
  | Partial value -> value.partial_size
  | Complete value -> value.complete_size

let complete_path value =
  Filename.concat value.complete_directory value.complete_name

let complete_of_entry = function
  | Complete value -> Ok value
  | Partial value -> Error (Partial_not_importable value.partial_name)

let inspection_object_ids value = value.object_ids

let is_name_exists = function
  | Unsafe_entry { detail = "name exists"; _ } -> true
  | Directory_not_directory _ | Directory_io_error _ | Unsafe_entry _
  | File_too_large _ | File_size_changed _ | Partial_not_importable _
  | Name_collision_exhausted _ | Entropy_failure _
  | Published_partial_retained _ | Bundle_error _ | Bundle_store_error _ ->
      false

let valid_token token =
  String.length token = token_length
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       token

let split_name ~prefix ~suffix name =
  let prefix_length = String.length prefix in
  let suffix_length = String.length suffix in
  let name_length = String.length name in
  if
    name_length = prefix_length + token_length + suffix_length
    && String.starts_with ~prefix name
    && String.ends_with ~suffix name
  then
    let token = String.sub name prefix_length token_length in
    if valid_token token then Some token else None
  else None

let classify_name name =
  match
    ( split_name ~prefix:partial_prefix ~suffix:partial_suffix name,
      split_name ~prefix:complete_prefix ~suffix:complete_suffix name )
  with
  | Some _, None -> `Partial
  | None, Some _ -> `Complete
  | None, None -> `Unknown
  | Some _, Some _ -> assert false

let ensure_directory directory =
  try
    let stat = Unix.lstat directory in
    if stat.Unix.st_kind = Unix.S_DIR then Ok ()
    else Error (Directory_not_directory directory)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "lstat" directory error)

let regular_stat path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_REG then Ok stat
    else Error (Unsafe_entry { path; detail = "entry is not a regular file" })
  with Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let descriptor directory name kind =
  let path = Filename.concat directory name in
  let* stat = regular_stat path in
  if stat.Unix.st_size > max_file_bytes then
    Error
      (File_too_large { path; size = stat.Unix.st_size; limit = max_file_bytes })
  else
    match kind with
    | `Partial ->
        Ok (Partial { partial_name = name; partial_size = stat.Unix.st_size })
    | `Complete ->
        Ok
          (Complete
             {
               complete_directory = directory;
               complete_name = name;
               complete_size = stat.Unix.st_size;
             })

let list ~directory =
  let* () = ensure_directory directory in
  try
    let names =
      Sys.readdir directory |> Array.to_list |> List.sort String.compare
    in
    let rec entries values = function
      | [] -> Ok (List.rev values)
      | name :: rest -> (
          match classify_name name with
          | `Unknown ->
              Error
                (Unsafe_entry
                   {
                     path = Filename.concat directory name;
                     detail = "entry name is not a Paengi bundle v1 name";
                   })
          | (`Partial | `Complete) as kind ->
              let* entry = descriptor directory name kind in
              entries (entry :: values) rest)
    in
    entries [] names
  with Sys_error message ->
    Error
      (Directory_io_error { operation = "readdir"; path = directory; message })

let hex_of_bytes bytes =
  let digits = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let byte = Char.code bytes.[index / 2] in
      digits.[if index mod 2 = 0 then byte lsr 4 else byte land 15])

let random_token () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Ok (Mirage_crypto_rng.generate 16 |> hex_of_bytes)
  with _ -> Error (Entropy_failure "OS CSPRNG unavailable")

let write_all descriptor bytes =
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
            (Directory_io_error
               {
                 operation = "write";
                 path = "bundle partial file";
                 message = "zero-byte write";
               })
        else loop (offset + written)
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "write" "bundle partial file" error)
  in
  loop 0

let fsync_path directory =
  try
    let descriptor = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.fsync descriptor;
        Ok ())
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "fsync" directory error)

let create_partial path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        let* () = write_all descriptor bytes in
        try
          Unix.fsync descriptor;
          Ok ()
        with Unix.Unix_error (error, _, _) ->
          Error (io_error "fsync" path error))
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) ->
      Error (Unsafe_entry { path; detail = "name exists" })
  | Unix.Unix_error (error, _, _) -> Error (io_error "create" path error)

let publish_complete ~directory ~partial_name ~complete_name =
  let partial_path = Filename.concat directory partial_name in
  let complete_path = Filename.concat directory complete_name in
  try
    Unix.link partial_path complete_path;
    let* () = fsync_path directory in
    try
      Unix.unlink partial_path;
      let* () = fsync_path directory in
      Ok ()
    with Unix.Unix_error (error, _, _) ->
      Error
        (Published_partial_retained
           { complete_name; partial_name; detail = Unix.error_message error })
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) ->
      Error (Unsafe_entry { path = complete_path; detail = "name exists" })
  | Unix.Unix_error (error, _, _) -> Error (io_error "link" complete_path error)

let export ~directory ~repository ~key ~object_ids =
  let* () = ensure_directory directory in
  let* bytes =
    Bundle_store.export repository ~key ~object_ids
    |> Result.map_error (fun error -> Bundle_store_error error)
  in
  let rec attempt remaining =
    if remaining = 0 then Error (Name_collision_exhausted max_name_attempts)
    else
      let* token = random_token () in
      let partial_name = partial_prefix ^ token ^ partial_suffix in
      let complete_name = complete_prefix ^ token ^ complete_suffix in
      let partial_path = Filename.concat directory partial_name in
      match create_partial partial_path bytes with
      | Error error when is_name_exists error -> attempt (remaining - 1)
      | Error error -> Error error
      | Ok () -> (
          match publish_complete ~directory ~partial_name ~complete_name with
          | Error error when is_name_exists error -> attempt (remaining - 1)
          | Error error -> Error error
          | Ok () ->
              let* entry = descriptor directory complete_name `Complete in
              complete_of_entry entry)
  in
  attempt max_name_attempts

let same_file initial current =
  Int.equal initial.Unix.st_dev current.Unix.st_dev
  && Int.equal initial.Unix.st_ino current.Unix.st_ino
  && Int.equal initial.Unix.st_size current.Unix.st_size

let read_complete complete =
  let path = complete_path complete in
  let* initial = regular_stat path in
  if initial.Unix.st_size > max_file_bytes then
    Error
      (File_too_large
         { path; size = initial.Unix.st_size; limit = max_file_bytes })
  else if initial.Unix.st_size <> complete.complete_size then
    Error (File_size_changed path)
  else
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let opened = Unix.fstat descriptor in
          if opened.Unix.st_kind <> Unix.S_REG || not (same_file initial opened)
          then Error (File_size_changed path)
          else
            let bytes = Bytes.create initial.Unix.st_size in
            let rec loop offset =
              if offset = initial.Unix.st_size then Ok ()
              else
                try
                  let read =
                    Unix.read descriptor bytes offset
                      (initial.Unix.st_size - offset)
                  in
                  if read = 0 then Error (File_size_changed path)
                  else loop (offset + read)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error "read" path error)
            in
            let* () = loop 0 in
            let* final = regular_stat path in
            if same_file initial final then Ok (Bytes.unsafe_to_string bytes)
            else Error (File_size_changed path))
    with Unix.Unix_error (error, _, _) -> Error (io_error "open" path error)

let inspect ~key complete =
  let* bytes = read_complete complete in
  let* bundle =
    Bundle.decode bytes |> Result.map_error (fun error -> Bundle_error error)
  in
  let* plaintext =
    Bundle.open_bundle ~repository_format:Paengi_store.repository_format ~key
      bundle
    |> Result.map_error (fun error -> Bundle_error error)
  in
  let object_ids =
    Bundle.plaintext_entries plaintext |> List.map Bundle.entry_object_id
  in
  Ok { object_ids }

let import ~repository ~key complete =
  let* bytes = read_complete complete in
  Bundle_store.import repository ~key bytes
  |> Result.map_error (fun error -> Bundle_store_error error)
