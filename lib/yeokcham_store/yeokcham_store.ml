module Envelope = Yeokcham_envelope
module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

module Stored_object_id = struct
  type t = string

  type parse_error =
    | Invalid_length of int
    | Invalid_hex_character of int * char

  let parse_error_to_string = function
    | Invalid_length length ->
        Printf.sprintf
          "stored object ID must contain 64 hexadecimal characters, got %d"
          length
    | Invalid_hex_character (offset, character) ->
        Printf.sprintf
          "stored object ID has invalid lowercase hexadecimal character %C at \
           %d"
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
          | _, None ->
              Error (Invalid_hex_character (offset + 1, hex.[offset + 1]))
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

module Mutable_ref = struct
  type t = { generation : int64; target : Stored_object_id.t option }

  let generation reference = reference.generation
  let target reference = reference.target
  let create ~generation ~target = { generation; target }

  let equal left right =
    Int64.equal left.generation right.generation
    && Option.equal Stored_object_id.equal left.target right.target

  let domain = "yeokcham:mutable-ref:v1\000"

  let array values =
    match Encoding.array values with
    | Ok value -> value
    | Error _ -> assert false

  let body reference =
    array
      [
        Encoding.integer 1L;
        Encoding.integer reference.generation;
        (match reference.target with
        | None -> Encoding.null
        | Some identity ->
            Encoding.bytes (Stored_object_id.to_raw_bytes identity));
      ]

  let checksum body =
    Hash.feed_string Hash.empty domain |> fun context ->
    Hash.feed_string context (Encoding.encode body)
    |> Hash.get |> Hash.to_raw_string

  let encode reference =
    let body = body reference in
    array
      [
        Encoding.integer 1L;
        Encoding.integer reference.generation;
        (match reference.target with
        | None -> Encoding.null
        | Some identity ->
            Encoding.bytes (Stored_object_id.to_raw_bytes identity));
        Encoding.bytes (checksum body);
      ]
    |> Encoding.encode

  let invalid message = Error message

  let fields name expected = function
    | Encoding.Array values when List.length values = expected -> Ok values
    | Encoding.Array _ ->
        invalid (Printf.sprintf "%s must contain %d values" name expected)
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid (name ^ " must be an array")

  let integer name = function
    | Encoding.Integer value -> Ok value
    | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid (name ^ " must be an integer")

  let parse_target = function
    | Encoding.Null -> Ok None
    | Encoding.Bytes raw -> (
        match Stored_object_id.of_raw_bytes raw with
        | Some identity -> Ok (Some identity)
        | None -> invalid "ref target must be a 32-byte stored object ID")
    | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
    | Encoding.Bool _ ->
        invalid "ref target must be null or bytes"

  let bytes name = function
    | Encoding.Bytes value -> Ok value
    | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid (name ^ " must be bytes")

  let decode input =
    let ( let* ) = Result.bind in
    let* value =
      Encoding.decode input |> Result.map_error Encoding.decode_error_to_string
    in
    let* values = fields "mutable ref" 4 value in
    match values with
    | [ version; generation; target_value; supplied_checksum ] ->
        let* version = integer "mutable ref version" version in
        if not (Int64.equal version 1L) then
          invalid
            (Printf.sprintf "unsupported mutable ref version: %Ld" version)
        else
          let* generation = integer "mutable ref generation" generation in
          if Int64.compare generation 0L < 0 then
            invalid "mutable ref generation must be non-negative"
          else
            let* target = parse_target target_value in
            let* supplied_checksum =
              bytes "mutable ref checksum" supplied_checksum
            in
            if String.length supplied_checksum <> Hash.digest_size then
              invalid "mutable ref checksum must be 32 bytes"
            else
              let reference = { generation; target } in
              let canonical = encode reference in
              if not (String.equal input canonical) then
                invalid
                  "mutable ref bytes are noncanonical or checksum is invalid"
              else Ok reference
    | _ -> assert false
end

type repository = {
  root : string;
  yeokcham : string;
  bootstrap : string;
  objects : string;
  refs : string;
  locks : string;
  journal : string;
}

type object_info = {
  id : Stored_object_id.t;
  object_type : Envelope.object_type;
  stored_bytes : int;
}

type error =
  | Root_not_directory of string
  | Repository_not_initialized of string
  | Repository_incomplete of { path : string; required : string }
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
  | Collision_or_corruption of { id : Stored_object_id.t; detail : string }
  | Unsupported_publication of { path : string; detail : string }
  | Temporary_name_exhausted of string
  | Invalid_ref_name of string
  | Corrupt_ref of { name : string; detail : string }
  | Concurrent_ref_update of {
      name : string;
      expected : Mutable_ref.t option;
      actual : Mutable_ref.t option;
    }
  | Ref_lock_held of string
  | Ref_generation_exhausted of string
  | Invalid_ref_path of string list
  | Concurrent_ref_file_update of {
      path : string;
      expected_present : bool;
      actual_present : bool;
    }

let error_to_string = function
  | Root_not_directory path ->
      Printf.sprintf "repository root is not a directory: %s" path
  | Repository_not_initialized path ->
      Printf.sprintf "repository is not initialized: %s" path
  | Repository_incomplete { path; required } ->
      Printf.sprintf "repository is incomplete: %s requires %s" path required
  | Incompatible_repository_format path ->
      Printf.sprintf "repository format is unsupported or corrupt: %s" path
  | Not_regular_file path -> Printf.sprintf "expected regular file: %s" path
  | Object_too_large { path; size; limit } ->
      Printf.sprintf "object is too large (%d > %d bytes): %s" size limit path
  | File_size_changed path ->
      Printf.sprintf "file size changed while reading: %s" path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Object_identity_mismatch { expected; actual } ->
      Printf.sprintf "object identity mismatch: expected %s, got %s"
        (Stored_object_id.to_hex expected)
        (Stored_object_id.to_hex actual)
  | Object_integrity_error error -> Envelope.decode_error_to_string error
  | Collision_or_corruption { id; detail } ->
      Printf.sprintf "existing object %s is divergent or corrupt: %s"
        (Stored_object_id.to_hex id)
        detail
  | Unsupported_publication { path; detail } ->
      Printf.sprintf "hard-link publication is unsupported for %s: %s" path
        detail
  | Temporary_name_exhausted path ->
      Printf.sprintf "could not allocate a unique temporary object path in %s"
        path
  | Invalid_ref_name name -> Printf.sprintf "invalid mutable ref name: %S" name
  | Corrupt_ref { name; detail } ->
      Printf.sprintf "mutable ref %s is corrupt: %s" name detail
  | Concurrent_ref_update { name; expected; actual } ->
      let render = function
        | None -> "missing"
        | Some reference ->
            Printf.sprintf "generation %Ld target %s"
              (Mutable_ref.generation reference)
              (match Mutable_ref.target reference with
              | None -> "null"
              | Some target -> Stored_object_id.to_hex target)
      in
      Printf.sprintf "mutable ref %s changed concurrently: expected %s, got %s"
        name (render expected) (render actual)
  | Ref_lock_held name -> Printf.sprintf "mutable ref lock is held: %s" name
  | Ref_generation_exhausted name ->
      Printf.sprintf "mutable ref generation is exhausted: %s" name
  | Invalid_ref_path components ->
      Printf.sprintf "invalid mutable ref path: %s"
        (String.concat "/" components)
  | Concurrent_ref_file_update { path; expected_present; actual_present } ->
      Printf.sprintf
        "mutable ref file %s changed concurrently: expected %s, got %s" path
        (if expected_present then "present" else "absent")
        (if actual_present then "present" else "absent")

let repository_format =
  "yeokcham-repository-format 1\n" ^ "stored-object-hash sha256\n"
  ^ "stored-object-preimage envelope-1-domain-v1\n" ^ "envelope-version 1\n"
  ^ "object-format-version 1\n"

let root_format =
  "yeokcham-repository-root 2\n" ^ "root-layout-version 3\n"
  ^ "required-directory bootstrap\n" ^ "required-directory objects\n"
  ^ "required-directory refs\n" ^ "required-directory locks\n"
  ^ "required-directory journal\n"

let max_object_bytes = 128 * 1024 * 1024
let root repository = repository.root
let object_domain = "yeokcham:object:v1\000"
let format_name = "format"
let yeokcham_name = ".yeokcham"
let bootstrap_name = "bootstrap"
let objects_name = "objects"
let refs_name = "refs"
let locks_name = "locks"
let journal_name = "journal"
let ( let* ) = Result.bind

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let lstat path =
  try Ok (Unix.lstat path)
  with Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let lstat_or_missing path =
  try Ok (Some (Unix.lstat path)) with
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
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "write" path error)
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
        | Unix.Unix_error (error, _, _) ->
            Error (io_error "fsync directory" path error))
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
                  match
                    Unix.read descriptor bytes offset
                      (stat.Unix.st_size - offset)
                  with
                  | 0 -> Error (File_size_changed path)
                  | count -> read (offset + count)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error "read" path error)
            in
            let* () = read 0 in
            let extra = Bytes.create 1 in
            let* extra_count =
              try Ok (Unix.read descriptor extra 0 1)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error "read" path error)
            in
            if extra_count = 0 then Ok (Bytes.unsafe_to_string bytes)
            else Error (File_size_changed path))
    with Unix.Unix_error (error, _, _) -> Error (io_error "open" path error)

let stored_object_id bytes =
  Hash.feed_string Hash.empty object_domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let stored_object_id_of_bytes bytes = stored_object_id bytes

let repository_paths_with_metadata ~root ~yeokcham =
  {
    root;
    yeokcham;
    bootstrap = Filename.concat yeokcham bootstrap_name;
    objects = Filename.concat yeokcham objects_name;
    refs = Filename.concat yeokcham refs_name;
    locks = Filename.concat yeokcham locks_name;
    journal = Filename.concat yeokcham journal_name;
  }

let repository_paths root =
  repository_paths_with_metadata ~root
    ~yeokcham:(Filename.concat root yeokcham_name)

let format_path repository = Filename.concat repository.yeokcham format_name

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
        match result with
        | Ok () -> Ok path
        | Error error ->
            ignore (unlink_if_present path);
            Error error
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (number + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error "create temporary" path error)
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

let write_repository_format repository =
  let path = format_path repository in
  let* temporary =
    create_temporary repository.yeokcham format_name
      (Bytes.of_string root_format)
  in
  let cleanup () =
    match finish_temporary ~directory:repository.yeokcham temporary with
    | Ok () | Error _ -> ()
  in
  match link_without_replace ~temporary ~final:path with
  | Error error ->
      cleanup ();
      Error error
  | Ok Already_exists ->
      cleanup ();
      Error (Incompatible_repository_format path)
  | Ok Published -> (
      match fsync_directory repository.yeokcham with
      | Error error ->
          cleanup ();
          Error error
      | Ok () -> finish_temporary ~directory:repository.yeokcham temporary)

let require_directory ~missing path =
  match lstat_or_missing path with
  | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Ok (Some _) -> Error (Root_not_directory path)
  | Ok None -> Error missing
  | Error error -> Error error

let validate_repository_layout repository =
  let* () = ensure_existing_directory repository.root in
  let* () =
    require_directory ~missing:(Repository_not_initialized repository.root)
      repository.yeokcham
  in
  let* () =
    require_directory
      ~missing:
        (Repository_incomplete
           { path = repository.yeokcham; required = bootstrap_name })
      repository.bootstrap
  in
  let* () =
    require_directory
      ~missing:
        (Repository_incomplete
           { path = repository.yeokcham; required = objects_name })
      repository.objects
  in
  let* () =
    require_directory
      ~missing:
        (Repository_incomplete
           { path = repository.yeokcham; required = refs_name })
      repository.refs
  in
  let* () =
    require_directory
      ~missing:
        (Repository_incomplete
           { path = repository.yeokcham; required = locks_name })
      repository.locks
  in
  require_directory
    ~missing:
      (Repository_incomplete
         { path = repository.yeokcham; required = journal_name })
    repository.journal

let validate_repository_format repository =
  let path = format_path repository in
  match lstat_or_missing path with
  | Ok None ->
      Error
        (Repository_incomplete
           { path = repository.yeokcham; required = format_name })
  | Ok (Some _) ->
      let* bytes = read_regular_file path in
      if String.equal bytes root_format then Ok ()
      else Error (Incompatible_repository_format path)
  | Error error -> Error error

let staging_path root attempt =
  Filename.concat root
    (Printf.sprintf ".yeokcham-v2-init-%d-%d" (Unix.getpid ()) attempt)

let create_staging_root root =
  let rec attempt number =
    if number = 128 then Error (Temporary_name_exhausted root)
    else
      let path = staging_path root number in
      try
        Unix.mkdir path 0o700;
        Ok path
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (number + 1)
      | Unix.Unix_error (error, _, _) -> Error (io_error "mkdir" path error)
  in
  attempt 0

let remove_staging_root repository =
  ignore (unlink_if_present (format_path repository));
  List.iter
    (fun path -> try Unix.rmdir path with Unix.Unix_error _ -> ())
    [
      repository.bootstrap;
      repository.objects;
      repository.refs;
      repository.locks;
      repository.journal;
    ];
  try Unix.rmdir repository.yeokcham with Unix.Unix_error _ -> ()

let create_staged_layout repository =
  let* () = ensure_directory repository.bootstrap in
  let* () = ensure_directory repository.objects in
  let* () = ensure_directory repository.refs in
  let* () = ensure_directory repository.locks in
  let* () = ensure_directory repository.journal in
  let* () = write_repository_format repository in
  let* () = fsync_directory repository.bootstrap in
  let* () = fsync_directory repository.objects in
  let* () = fsync_directory repository.refs in
  let* () = fsync_directory repository.locks in
  let* () = fsync_directory repository.journal in
  fsync_directory repository.yeokcham

let publish_staged_root ~repository ~staging =
  match lstat_or_missing repository.yeokcham with
  | Error error -> Error error
  | Ok (Some _) -> Error (Repository_not_initialized repository.root)
  | Ok None -> (
      try
        Unix.rename staging.yeokcham repository.yeokcham;
        fsync_directory repository.root
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "publish repository root" repository.yeokcham error))

let init ~root =
  let repository = repository_paths root in
  let* () = ensure_existing_directory root in
  match lstat_or_missing repository.yeokcham with
  | Error error -> Error error
  | Ok (Some _) ->
      let* () = validate_repository_layout repository in
      let* () = validate_repository_format repository in
      Ok repository
  | Ok None -> (
      let* staging_path = create_staging_root root in
      let staging =
        repository_paths_with_metadata ~root ~yeokcham:staging_path
      in
      let result =
        let* () = create_staged_layout staging in
        publish_staged_root ~repository ~staging
      in
      match result with
      | Ok () -> Ok repository
      | Error error ->
          remove_staging_root staging;
          Error error)

let open_repository ~root =
  let repository = repository_paths root in
  let* () = validate_repository_layout repository in
  let* () = validate_repository_format repository in
  Ok repository

let object_path repository id =
  let hex = Stored_object_id.to_hex id in
  Filename.concat repository.objects
    (Filename.concat (String.sub hex 0 2)
       (Filename.concat (String.sub hex 2 2) (String.sub hex 4 60)))

let object_directory repository id =
  Filename.dirname (object_path repository id)

let ensure_object_shard repository id =
  let hex = Stored_object_id.to_hex id in
  let* () =
    ensure_directory (Filename.concat repository.objects (String.sub hex 0 2))
  in
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

let canonical_object_name value length =
  String.length value = length
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let list_objects repository =
  let read_directory directory =
    try Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
    with Sys_error message ->
      Error
        (Io_error
           { operation = "read object directory"; path = directory; message })
  in
  let* shards = read_directory repository.objects in
  let rec read_objects reversed = function
    | [] -> Ok (List.rev reversed)
    | shard :: rest ->
        if not (canonical_object_name shard 2) then
          Error
            (Io_error
               {
                 operation = "validate object directory";
                 path = Filename.concat repository.objects shard;
                 message =
                   "object shard name is not two lowercase hexadecimal \
                    characters";
               })
        else
          let directory = Filename.concat repository.objects shard in
          let* stat = lstat directory in
          if stat.Unix.st_kind <> Unix.S_DIR then
            Error (Root_not_directory directory)
          else
            let* prefixes = read_directory directory in
            let rec read_prefixes reversed = function
              | [] -> read_objects reversed rest
              | prefix :: remaining ->
                  if not (canonical_object_name prefix 2) then
                    Error
                      (Io_error
                         {
                           operation = "validate object directory";
                           path = Filename.concat directory prefix;
                           message =
                             "object prefix is not two lowercase hexadecimal \
                              characters";
                         })
                  else
                    let prefix_directory = Filename.concat directory prefix in
                    let* prefix_stat = lstat prefix_directory in
                    if prefix_stat.Unix.st_kind <> Unix.S_DIR then
                      Error (Root_not_directory prefix_directory)
                    else
                      let* names = read_directory prefix_directory in
                      let rec read_entries reversed = function
                        | [] -> read_prefixes reversed remaining
                        | name :: tail ->
                            if String.starts_with ~prefix:"." name then
                              read_entries reversed tail
                            else if not (canonical_object_name name 60) then
                              Error
                                (Io_error
                                   {
                                     operation = "validate object filename";
                                     path =
                                       Filename.concat prefix_directory name;
                                     message =
                                       "object name is not 60 lowercase \
                                        hexadecimal characters";
                                   })
                            else
                              let hex = shard ^ prefix ^ name in
                              let* id =
                                Stored_object_id.of_hex hex
                                |> Result.map_error (fun error ->
                                    Io_error
                                      {
                                        operation = "decode object filename";
                                        path =
                                          Filename.concat prefix_directory name;
                                        message =
                                          Stored_object_id.parse_error_to_string
                                            error;
                                      })
                              in
                              let path =
                                Filename.concat prefix_directory name
                              in
                              let* stat = lstat path in
                              if stat.Unix.st_kind <> Unix.S_REG then
                                Error (Not_regular_file path)
                              else
                                let* object_ = get repository id in
                                read_entries
                                  ({
                                     id;
                                     object_type = Envelope.object_type object_;
                                     stored_bytes = stat.Unix.st_size;
                                   }
                                  :: reversed)
                                  tail
                      in
                      read_entries reversed names
            in
            read_prefixes reversed prefixes
  in
  read_objects [] shards

let existing_matches repository id expected =
  let path = object_path repository id in
  match read_regular_file path with
  | Error error ->
      Error (Collision_or_corruption { id; detail = error_to_string error })
  | Ok actual -> (
      let actual_id = stored_object_id_of_bytes actual in
      if not (Stored_object_id.equal id actual_id) then
        Error
          (Collision_or_corruption
             {
               id;
               detail =
                 error_to_string
                   (Object_identity_mismatch
                      { expected = id; actual = actual_id });
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
                 {
                   id;
                   detail = "verified object bytes differ from proposed bytes";
                 }))

let id_of_envelope envelope =
  Envelope.encode envelope |> stored_object_id_of_bytes

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
    let id = id_of_envelope envelope in
    let* () = ensure_object_shard repository id in
    let directory = object_directory repository id in
    let final = object_path repository id in
    let* temporary =
      create_temporary directory (Filename.basename final)
        (Bytes.of_string bytes)
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

let valid_ref_name name =
  (not (String.is_empty name))
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let checked_ref_name name =
  if valid_ref_name name then Ok () else Error (Invalid_ref_name name)

let ref_path repository name = Filename.concat repository.refs name

let ref_lock_path repository name =
  Filename.concat repository.locks (name ^ ".lock")

let read_ref repository ~name =
  let* () = checked_ref_name name in
  let path = ref_path repository name in
  match lstat_or_missing path with
  | Ok None -> Ok None
  | Ok (Some _) ->
      let* bytes =
        read_regular_file path
        |> Result.map_error (fun error ->
            Corrupt_ref { name; detail = error_to_string error })
      in
      Mutable_ref.decode bytes
      |> Result.map (fun reference -> Some reference)
      |> Result.map_error (fun detail -> Corrupt_ref { name; detail })
  | Error error -> Error error

let acquire_ref_lock repository name =
  let* () = checked_ref_name name in
  let path = ref_lock_path repository name in
  let contents =
    Printf.sprintf "yeokcham-mutable-ref-lock-v1\npid=%d\n" (Unix.getpid ())
  in
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let result =
      match write_all descriptor path (Bytes.of_string contents) with
      | Error error -> Error error
      | Ok () -> fsync_file descriptor path
    in
    let close_result = close_file descriptor path in
    let result =
      match result with Error _ as error -> error | Ok () -> close_result
    in
    match result with
    | Error error ->
        ignore (unlink_if_present path);
        Error error
    | Ok () -> fsync_directory repository.locks |> Result.map (fun () -> path)
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Error (Ref_lock_held name)
  | Unix.Unix_error (error, _, _) ->
      Error (io_error "create mutable ref lock" path error)

let release_ref_lock repository path =
  let* () = unlink_if_present path in
  fsync_directory repository.locks

let with_ref_lock repository name action =
  let* lock_path = acquire_ref_lock repository name in
  let result = action () in
  match release_ref_lock repository lock_path with
  | Ok () -> result
  | Error release_error -> (
      match result with Ok _ -> Error release_error | Error _ -> result)

let with_lock repository ~name ~on_error action =
  match checked_ref_name name with
  | Error error -> Error (on_error error)
  | Ok () -> (
      match acquire_ref_lock repository name with
      | Error error -> Error (on_error error)
      | Ok lock_path -> (
          let result = action () in
          match release_ref_lock repository lock_path with
          | Ok () -> result
          | Error error -> (
              match result with
              | Ok _ -> Error (on_error error)
              | Error _ -> result)))

let rename_ref_temporary ~temporary ~final =
  try
    Unix.rename temporary final;
    Ok ()
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "rename mutable ref" final error)

let compare_and_swap_ref repository ~name ~expected ~target =
  let* () = checked_ref_name name in
  with_ref_lock repository name (fun () ->
      let* actual = read_ref repository ~name in
      if not (Option.equal Mutable_ref.equal expected actual) then
        Error (Concurrent_ref_update { name; expected; actual })
      else
        let generation =
          match actual with
          | None -> Ok 0L
          | Some current ->
              let current_generation = Mutable_ref.generation current in
              if Int64.equal current_generation Int64.max_int then
                Error (Ref_generation_exhausted name)
              else Ok (Int64.succ current_generation)
        in
        let* generation = generation in
        let next = Mutable_ref.create ~generation ~target in
        let bytes = Mutable_ref.encode next |> Bytes.of_string in
        let final = ref_path repository name in
        let* temporary =
          create_temporary repository.refs (Filename.basename final) bytes
        in
        let publication = rename_ref_temporary ~temporary ~final in
        match publication with
        | Error error ->
            ignore (unlink_if_present temporary);
            Error error
        | Ok () ->
            fsync_directory repository.refs |> Result.map (fun () -> next))

module Ref_file = struct
  let valid_component component = valid_ref_name component

  let checked_components components =
    if components = [] || not (List.for_all valid_component components) then
      Error (Invalid_ref_path components)
    else Ok ()

  let path repository components =
    List.fold_left Filename.concat repository.refs components

  let ensure_parent_directory repository components =
    match List.rev components with
    | [] -> Error (Invalid_ref_path components)
    | _file :: reversed_directories ->
        List.rev reversed_directories
        |> List.fold_left
             (fun result component ->
               let* directory = result in
               let next = Filename.concat directory component in
               let* () = ensure_directory next in
               Ok next)
             (Ok repository.refs)
        |> Result.map (fun _ -> ())

  let read repository ~components =
    let* () = checked_components components in
    let file = path repository components in
    match lstat_or_missing file with
    | Ok None -> Ok None
    | Ok (Some _) -> read_regular_file file |> Result.map Option.some
    | Error error -> Error error

  let compare_and_swap repository ~components ~expected ~replacement =
    let* () = checked_components components in
    let file = path repository components in
    let* actual = read repository ~components in
    if not (Option.equal String.equal expected actual) then
      Error
        (Concurrent_ref_file_update
           {
             path = file;
             expected_present = Option.is_some expected;
             actual_present = Option.is_some actual;
           })
    else
      let directory = Filename.dirname file in
      let* () = ensure_parent_directory repository components in
      let* temporary =
        create_temporary directory (Filename.basename file)
          (Bytes.of_string replacement)
      in
      match rename_ref_temporary ~temporary ~final:file with
      | Error error ->
          ignore (unlink_if_present temporary);
          Error error
      | Ok () -> fsync_directory directory
end
