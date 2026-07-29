module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256

module Stored_object_id = struct
  type t = string

  type parse_error =
    | Invalid_length of int
    | Invalid_hex_character of int * char

  let parse_error_to_string = function
    | Invalid_length length ->
        Printf.sprintf "stored object ID must contain 64 hexadecimal characters, got %d"
          length
    | Invalid_hex_character (offset, character) ->
        Printf.sprintf "stored object ID has invalid lowercase hexadecimal character %C at %d"
          character offset

  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (10 + Char.code character - Char.code 'a')
    | _ -> None

  let of_raw_bytes bytes = if String.length bytes = 32 then Some bytes else None
  let to_raw_bytes identity = identity

  let of_hex hex =
    if String.length hex <> 64 then Error (Invalid_length (String.length hex))
    else
      let raw = Bytes.create 32 in
      let rec decode offset =
        if offset = 64 then Ok (Bytes.unsafe_to_string raw)
        else
          match (nibble hex.[offset], nibble hex.[offset + 1]) with
          | Some high, Some low ->
              Bytes.set raw (offset / 2) (Char.chr ((high lsl 4) lor low));
              decode (offset + 2)
          | None, _ -> Error (Invalid_hex_character (offset, hex.[offset]))
          | _, None -> Error (Invalid_hex_character (offset + 1, hex.[offset + 1]))
      in
      decode 0

  let to_hex raw =
    let hex = "0123456789abcdef" in
    let encoded = Bytes.create 64 in
    String.iteri
      (fun index character ->
        let value = Char.code character in
        Bytes.set encoded (index * 2) hex.[value lsr 4];
        Bytes.set encoded ((index * 2) + 1) hex.[value land 0x0f])
      raw;
    Bytes.unsafe_to_string encoded

  let equal = String.equal
  let compare = String.compare
end

type repository = { root : string; paengi : string; objects : string }

type error =
  | Root_not_directory of string
  | Repository_not_initialized of string
  | Incompatible_repository_format of string
  | Not_regular_file of string
  | Object_too_large of { path : string; size : int; limit : int }
  | File_size_changed of string
  | Io_error of { operation : string; path : string; message : string }
  | Object_identity_mismatch of {
      expected : Stored_object_id.t;
      actual : Stored_object_id.t;
    }
  | Object_integrity_error of Envelope.decode_error
  | Collision_or_corruption of {
      id : Stored_object_id.t;
      detail : string;
    }
  | Unsupported_publication of { path : string; detail : string }
  | Temporary_name_exhausted of string

let error_to_string = function
  | Root_not_directory path -> Printf.sprintf "repository root is not a directory: %s" path
  | Repository_not_initialized path ->
      Printf.sprintf "repository is not initialized: %s" path
  | Incompatible_repository_format path ->
      Printf.sprintf "repository format is unsupported or corrupt: %s" path
  | Not_regular_file path -> Printf.sprintf "expected regular file: %s" path
  | Object_too_large { path; size; limit } ->
      Printf.sprintf "object is too large (%d > %d bytes): %s" size limit path
  | File_size_changed path -> Printf.sprintf "file size changed while reading: %s" path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Object_identity_mismatch { expected; actual } ->
      Printf.sprintf "object identity mismatch: expected %s, got %s"
        (Stored_object_id.to_hex expected)
        (Stored_object_id.to_hex actual)
  | Object_integrity_error error -> Envelope.decode_error_to_string error
  | Collision_or_corruption { id; detail } ->
      Printf.sprintf "existing object %s is divergent or corrupt: %s"
        (Stored_object_id.to_hex id) detail
  | Unsupported_publication { path; detail } ->
      Printf.sprintf "hard-link publication is unsupported for %s: %s" path detail
  | Temporary_name_exhausted path ->
      Printf.sprintf "could not allocate a unique temporary object path in %s" path

let repository_format =
  "paengi-repository-format 1\n"
  ^ "stored-object-hash sha256\n"
  ^ "stored-object-preimage envelope-1-domain-v1\n"
  ^ "envelope-version 1\n"
  ^ "object-format-version 1\n"

let max_object_bytes = 128 * 1024 * 1024
let object_domain = "paengi:object:v1\000"
let format_name = "format"
let paengi_name = ".paengi"
let objects_name = "objects"

let ( let* ) = Result.bind

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let lstat path =
  try Ok (Unix.lstat path)
  with Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let lstat_or_missing path =
  try Ok (Some (Unix.lstat path))
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let ensure_existing_directory path =
  match lstat_or_missing path with
  | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Ok (Some _) | Ok None -> Error (Root_not_directory path)
  | Error error -> Error error

let rec ensure_directory path =
  match lstat_or_missing path with
  | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Ok (Some _) -> Error (Root_not_directory path)
  | Ok None -> (
      try
        Unix.mkdir path 0o700;
        Ok ()
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_directory path
      | Unix.Unix_error (error, _, _) -> Error (io_error "mkdir" path error))
  | Error error -> Error error

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let close_file descriptor path =
  try
    Unix.close descriptor;
    Ok ()
  with Unix.Unix_error (error, _, _) -> Error (io_error "close" path error)

let write_all descriptor path bytes =
  let length = Bytes.length bytes in
  let rec write offset =
    if offset = length then Ok ()
    else
      try
        match Unix.write descriptor bytes offset (length - offset) with
        | 0 ->
            Error
              (Io_error
                 {
                   operation = "write";
                   path;
                   message = "write returned zero before completion";
                 })
        | written -> write (offset + written)
      with Unix.Unix_error (error, _, _) -> Error (io_error "write" path error)
  in
  write 0

let fsync_file descriptor path =
  try
    Unix.fsync descriptor;
    Ok ()
  with Unix.Unix_error (error, _, _) -> Error (io_error "fsync" path error)

let directory_fsync_is_unsupported error =
  error = Unix.EINVAL || error = Unix.ENOSYS || error = Unix.EOPNOTSUPP

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> close_noerr descriptor)
      (fun () ->
        try
          Unix.fsync descriptor;
          Ok ()
        with
        | Unix.Unix_error (error, _, _)
          when directory_fsync_is_unsupported error ->
            Ok ()
        | Unix.Unix_error (error, _, _) -> Error (io_error "fsync directory" path error))
  with Unix.Unix_error (error, _, _) ->
    if directory_fsync_is_unsupported error then Ok ()
    else Error (io_error "open directory for fsync" path error)

let unlink_if_present path =
  try
    Unix.unlink path;
    Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (error, _, _) -> Error (io_error "unlink" path error)

let read_regular_file path =
  let* initial = lstat path in
  if initial.Unix.st_kind <> Unix.S_REG then Error (Not_regular_file path)
  else
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> close_noerr descriptor)
        (fun () ->
          let stat = Unix.fstat descriptor in
          if stat.Unix.st_kind <> Unix.S_REG then Error (Not_regular_file path)
          else if stat.Unix.st_size > max_object_bytes then
            Error
              (Object_too_large
                 { path; size = stat.Unix.st_size; limit = max_object_bytes })
          else
            let bytes = Bytes.create stat.Unix.st_size in
            let rec read offset =
              if offset = stat.Unix.st_size then Ok ()
              else
                try
                  match Unix.read descriptor bytes offset (stat.Unix.st_size - offset) with
                  | 0 -> Error (File_size_changed path)
                  | count -> read (offset + count)
                with Unix.Unix_error (error, _, _) -> Error (io_error "read" path error)
            in
            let* () = read 0 in
            let extra = Bytes.create 1 in
            let* extra_count =
              try Ok (Unix.read descriptor extra 0 1)
              with Unix.Unix_error (error, _, _) -> Error (io_error "read" path error)
            in
            if extra_count = 0 then Ok (Bytes.unsafe_to_string bytes)
            else Error (File_size_changed path))
    with Unix.Unix_error (error, _, _) -> Error (io_error "open" path error)

let stored_object_id bytes =
  Hash.feed_string Hash.empty object_domain
  |> fun context -> Hash.feed_string context bytes
  |> Hash.get |> Hash.to_raw_string

let stored_object_id_of_bytes bytes = stored_object_id bytes

let repository_paths root =
  let paengi = Filename.concat root paengi_name in
  { root; paengi; objects = Filename.concat paengi objects_name }

let format_path repository = Filename.concat repository.paengi format_name

let ensure_layout repository =
  let* () = ensure_existing_directory repository.root in
  let* () = ensure_directory repository.paengi in
  ensure_directory repository.objects

let temporary_path directory final_name attempt =
  Filename.concat directory
    (Printf.sprintf ".%s.tmp-%d-%d" final_name (Unix.getpid ()) attempt)

let create_temporary directory final_name bytes =
  let rec attempt number =
    if number = 128 then Error (Temporary_name_exhausted directory)
    else
      let path = temporary_path directory final_name number in
      try
        let descriptor =
          Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        let result =
          match write_all descriptor path bytes with
          | Error error -> Error error
          | Ok () -> fsync_file descriptor path
        in
        let close_result = close_file descriptor path in
        let result =
          match result with Error error -> Error error | Ok () -> close_result
        in
        (match result with
        | Ok () -> Ok path
        | Error error ->
            ignore (unlink_if_present path);
            Error error)
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (number + 1)
      | Unix.Unix_error (error, _, _) -> Error (io_error "create temporary" path error)
  in
  attempt 0

type link_result = Published | Already_exists

let link_without_replace ~temporary ~final =
  try
    Unix.link temporary final;
    Ok Published
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok Already_exists
  | Unix.Unix_error (error, _, _) ->
      Error
        (Unsupported_publication
           { path = final; detail = Unix.error_message error })

let finish_temporary ~directory temporary =
  let* () = unlink_if_present temporary in
  fsync_directory directory

let ensure_repository_format repository =
  let path = format_path repository in
  match lstat_or_missing path with
  | Ok (Some _) ->
      let* bytes = read_regular_file path in
      if String.equal bytes repository_format then Ok ()
      else Error (Incompatible_repository_format path)
  | Ok None ->
      let* temporary = create_temporary repository.paengi format_name (Bytes.of_string repository_format) in
      let result = link_without_replace ~temporary ~final:path in
      (match result with
      | Error error -> Error error
      | Ok Published ->
          let* () = fsync_directory repository.paengi in
          finish_temporary ~directory:repository.paengi temporary
      | Ok Already_exists ->
          let* () = finish_temporary ~directory:repository.paengi temporary in
          let* bytes = read_regular_file path in
          if String.equal bytes repository_format then Ok ()
          else Error (Incompatible_repository_format path))
  | Error error -> Error error

let init ~root =
  let repository = repository_paths root in
  let* () = ensure_layout repository in
  let* () = ensure_repository_format repository in
  Ok repository

let open_repository ~root =
  let repository = repository_paths root in
  let* () = ensure_existing_directory repository.root in
  let* () =
    match lstat_or_missing repository.paengi with
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
    | Ok (Some _) | Ok None | Error _ -> Error (Repository_not_initialized root)
  in
  let* () =
    match lstat_or_missing repository.objects with
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
    | Ok (Some _) | Ok None | Error _ -> Error (Repository_not_initialized root)
  in
  let* () = ensure_repository_format repository in
  Ok repository

let object_path repository id =
  let hex = Stored_object_id.to_hex id in
  Filename.concat repository.objects
    (Filename.concat (String.sub hex 0 2)
       (Filename.concat (String.sub hex 2 2) (String.sub hex 4 60)))

let object_directory repository id = Filename.dirname (object_path repository id)

let ensure_object_shard repository id =
  let hex = Stored_object_id.to_hex id in
  let* () = ensure_directory (Filename.concat repository.objects (String.sub hex 0 2)) in
  ensure_directory (object_directory repository id)

let get repository id =
  let path = object_path repository id in
  let* bytes = read_regular_file path in
  let actual = stored_object_id_of_bytes bytes in
  if not (Stored_object_id.equal id actual) then
    Error (Object_identity_mismatch { expected = id; actual })
  else
    Envelope.decode bytes
    |> Result.map_error (fun error -> Object_integrity_error error)

let existing_matches repository id expected =
  let path = object_path repository id in
  match read_regular_file path with
  | Error error ->
      Error
        (Collision_or_corruption { id; detail = error_to_string error })
  | Ok actual ->
      let actual_id = stored_object_id_of_bytes actual in
      if not (Stored_object_id.equal id actual_id) then
        Error
          (Collision_or_corruption
             {
               id;
               detail =
                 error_to_string
                   (Object_identity_mismatch { expected = id; actual = actual_id });
             })
      else
        match Envelope.decode actual with
        | Error error ->
            Error
              (Collision_or_corruption
                 { id; detail = Envelope.decode_error_to_string error })
        | Ok _ when String.equal expected actual -> Ok ()
        | Ok _ ->
            Error
              (Collision_or_corruption
                 { id; detail = "verified object bytes differ from proposed bytes" })

let put repository envelope =
  let bytes = Envelope.encode envelope in
  if String.length bytes > max_object_bytes then
    Error
      (Object_too_large
         {
           path = "canonical Envelope-1 object";
           size = String.length bytes;
           limit = max_object_bytes;
         })
  else
    let id = stored_object_id_of_bytes bytes in
    let* () = ensure_object_shard repository id in
    let directory = object_directory repository id in
    let final = object_path repository id in
    let* temporary =
      create_temporary directory (Filename.basename final) (Bytes.of_string bytes)
    in
    let link_result = link_without_replace ~temporary ~final in
    match link_result with
    | Error error -> Error error
    | Ok Published ->
        let* () = fsync_directory directory in
        let* () = finish_temporary ~directory temporary in
        Ok id
    | Ok Already_exists ->
        let* () = finish_temporary ~directory temporary in
        let* () = existing_matches repository id bytes in
        Ok id
