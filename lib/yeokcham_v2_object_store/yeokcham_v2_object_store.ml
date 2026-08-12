module Address = Yeokcham_v2_address
module Cutover = Yeokcham_cutover
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object

type repository = {
  root : string;
  objects : string;
  repository_id : Model.Repository_id.t;
  address_key : Address.key;
  encryption_key : Envelope.key;
}

type publication =
  | Published of Model.Opaque_object_ref.t
  | Already_published of Model.Opaque_object_ref.t

type quarantine_outcome = Quarantined of int64 | Already_quarantined of int64
type prune_outcome = Pruned of int64 | Already_pruned

type error =
  | Cutover_error of Cutover.error
  | Not_v2_root of Cutover.classification
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_object_path of string
  | Envelope_error of Envelope.error
  | Address_error of Address.error
  | Object_error of Object.error
  | Object_collision of Model.Opaque_object_ref.t
  | Invalid_quarantine_generation of string
  | Quarantine_target_collision of Model.Opaque_object_ref.t
  | Quarantine_candidate_missing of Model.Opaque_object_ref.t
  | Quarantine_candidate_in_other_generation of Model.Opaque_object_ref.t
  | Quarantine_source_still_present of Model.Opaque_object_ref.t
  | Unexpected_object_kind of {
      object_ref : Model.Opaque_object_ref.t;
      expected : Object.kind;
      actual : Object.kind;
    }

let max_object_bytes = Envelope.max_ciphertext_bytes + 128
let max_temporary_attempts = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Not_v2_root classification ->
      "V2 object storage requires a V2-only root, found "
      ^ Cutover.classification_to_string classification
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Invalid_object_path path -> "invalid V2 opaque object path: " ^ path
  | Envelope_error error -> Envelope.error_to_string error
  | Address_error error -> Address.error_to_string error
  | Object_error error -> Object.error_to_string error
  | Object_collision object_ref ->
      "opaque object address already contains different bytes: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Invalid_quarantine_generation generation ->
      "invalid V2 quarantine generation: " ^ generation
  | Quarantine_target_collision object_ref ->
      "V2 quarantine target has different bytes for object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Quarantine_candidate_missing object_ref ->
      "V2 quarantine candidate is absent from its source and active \
       quarantine: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Quarantine_candidate_in_other_generation object_ref ->
      "V2 quarantine candidate appears in a different generation: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Quarantine_source_still_present object_ref ->
      "V2 prune refuses a candidate still present in the live object store: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Unexpected_object_kind { object_ref; expected; actual } ->
      let kind = function
        | Object.Ledger_event -> "ledger event"
        | Object.Scratch_snapshot -> "scratch snapshot"
        | Object.Scratch_protection -> "scratch protection"
        | Object.Scratch_generation -> "scratch generation"
        | Object.Capsule -> "capsule"
        | Object.Capsule_revision -> "capsule revision"
        | Object.Workspace -> "workspace"
        | Object.Workspace_revision -> "workspace revision"
        | Object.Workspace_attempt -> "workspace attempt"
        | Object.Conflict -> "workspace conflict"
        | Object.Resolution -> "workspace resolution"
        | Object.Validation_evidence -> "validation evidence"
        | Object.Release -> "release"
      in
      Printf.sprintf "V2 object %s has kind %s, expected %s"
        (Model.Opaque_object_ref.to_hex object_ref)
        (kind actual) (kind expected)

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

let open_repository ~root ~repository_id ~address_key ~encryption_key =
  let* () = check_v2_root root in
  Ok
    {
      root;
      objects = Filename.concat root ".yeokcham/objects";
      repository_id;
      address_key;
      encryption_key;
    }

let repository_id repository = repository.repository_id

let object_path repository object_ref =
  let hex = Model.Opaque_object_ref.to_hex object_ref in
  Filename.concat repository.objects
    (Filename.concat (String.sub hex 0 2)
       (Filename.concat (String.sub hex 2 2) (String.sub hex 4 60)))

let stored_bytes repository ~object_ref =
  let* () = check_v2_root repository.root in
  let path = object_path repository object_ref in
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then Error (Invalid_object_path path)
    else Ok (Int64.of_int stat.Unix.st_size)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"lstat" ~path error)

let lowercase_hex name expected_length =
  String.length name = expected_length
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       name

let read_directory path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
  with Sys_error message ->
    Error (Io_error { operation = "read directory"; path; message })

let stat_kind path =
  try Ok (Unix.lstat path).Unix.st_kind
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"lstat" ~path error)

let temporary_stat_kind_if_present path =
  try Ok (Some (Unix.lstat path).Unix.st_kind) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

let list_object_refs repository =
  let* () = check_v2_root repository.root in
  let rec scan_leaves first_shard second_shard result = function
    | [] -> Ok result
    | name :: rest ->
        let path = Filename.concat second_shard name in
        if Cutover.is_v2_object_temporary_filename name then
          let* kind = temporary_stat_kind_if_present path in
          match kind with
          | None -> scan_leaves first_shard second_shard result rest
          | Some kind ->
              if kind = Unix.S_REG then
                scan_leaves first_shard second_shard result rest
              else Error (Invalid_object_path path)
        else
          let* kind = stat_kind path in
          if
            kind <> Unix.S_REG
            || (not (lowercase_hex name 60))
            || (not (lowercase_hex (Filename.basename first_shard) 2))
            || not (lowercase_hex (Filename.basename second_shard) 2)
          then Error (Invalid_object_path path)
          else
            let encoded = first_shard ^ Filename.basename second_shard ^ name in
            let* object_ref =
              Model.Opaque_object_ref.of_hex encoded
              |> Result.map_error (fun _ -> Invalid_object_path path)
            in
            scan_leaves first_shard second_shard (object_ref :: result) rest
  in
  let rec scan_second_shards first_shard result = function
    | [] -> Ok result
    | name :: rest ->
        let path = Filename.concat first_shard name in
        let* kind = stat_kind path in
        if kind <> Unix.S_DIR || not (lowercase_hex name 2) then
          Error (Invalid_object_path path)
        else
          let* leaves = read_directory path in
          let* result =
            scan_leaves (Filename.basename first_shard) path result leaves
          in
          scan_second_shards first_shard result rest
  in
  let rec scan_first_shards result = function
    | [] -> Ok (List.sort Model.Opaque_object_ref.compare result)
    | name :: rest ->
        let path = Filename.concat repository.objects name in
        let* kind = stat_kind path in
        if kind <> Unix.S_DIR || not (lowercase_hex name 2) then
          Error (Invalid_object_path path)
        else
          let* second_shards = read_directory path in
          let* result = scan_second_shards path result second_shards in
          scan_first_shards result rest
  in
  let* first_shards = read_directory repository.objects in
  scan_first_shards [] first_shards

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        try
          Unix.fsync descriptor;
          Ok ()
        with
        | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _)
          ->
            Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"fsync" ~path error))
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"fsync" ~path error)

let rec ensure_directory path =
  let* () =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR -> Ok ()
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Error (Invalid_object_path path)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> (
        try
          Unix.mkdir path 0o700;
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_directory path
        | Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"mkdir" ~path error))
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"lstat" ~path error)
  in
  fsync_directory (Filename.dirname path)

let ensure_object_shard repository object_ref =
  let path = object_path repository object_ref in
  let first = Filename.dirname (Filename.dirname path) in
  let second = Filename.dirname path in
  let* () = ensure_directory first in
  ensure_directory second

let write_all descriptor bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let written =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if written = 0 then Error "write returned zero bytes"
        else write (offset + written)
      with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  write 0

let temporary_path directory final attempt =
  Filename.concat directory
    (Printf.sprintf ".%s.object-%d-%d" (Filename.basename final)
       (Unix.getpid ()) attempt)

let create_temporary directory final bytes =
  let rec create attempt =
    if attempt = max_temporary_attempts then
      Error
        (Io_error
           {
             operation = "create temporary object";
             path = directory;
             message = "temporary name space exhausted";
           })
    else
      let path = temporary_path directory final attempt in
      try
        let descriptor =
          Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () =
                write_all descriptor (Bytes.unsafe_of_string bytes)
                |> Result.map_error (fun message ->
                    Io_error { operation = "write"; path; message })
              in
              try
                Unix.fsync descriptor;
                Ok path
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"fsync" ~path error))
        in
        match result with
        | Ok _ -> result
        | Error _ ->
            (try Unix.unlink path with Unix.Unix_error _ -> ());
            result
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"create" ~path error)
  in
  create 0

let read_regular_file path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then Error (Invalid_object_path path)
    else if stat.Unix.st_size > max_object_bytes then
      Error
        (Io_error
           {
             operation = "read";
             path;
             message = "object exceeds the V2 envelope size limit";
           })
    else
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let bytes = Bytes.create stat.Unix.st_size in
          let rec read offset =
            if offset = Bytes.length bytes then
              Ok (Bytes.unsafe_to_string bytes)
            else
              try
                let count =
                  Unix.read descriptor bytes offset (Bytes.length bytes - offset)
                in
                if count = 0 then
                  Error
                    (Io_error
                       {
                         operation = "read";
                         path;
                         message = "object changed while being read";
                       })
                else read (offset + count)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"read" ~path error)
          in
          read 0)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"lstat" ~path error)

let verified_envelope repository envelope =
  let object_ref =
    Address.derive ~repository_id:repository.repository_id
      ~key:repository.address_key ~envelope
  in
  let* plaintext =
    Envelope.open_envelope ~key:repository.encryption_key envelope
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* object_ =
    Object.decode plaintext
    |> Result.map_error (fun error -> Object_error error)
  in
  Ok (object_ref, object_)

let validate_envelope repository ~envelope =
  let* () = check_v2_root repository.root in
  verified_envelope repository envelope

let publish repository ~envelope =
  let* () = check_v2_root repository.root in
  let* object_ref, _ = verified_envelope repository envelope in
  let* () = ensure_object_shard repository object_ref in
  let final = object_path repository object_ref in
  let directory = Filename.dirname final in
  let bytes = Envelope.encode envelope in
  let* temporary = create_temporary directory final bytes in
  let linked =
    try
      Unix.link temporary final;
      Ok true
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok false
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"link" ~path:final error)
  in
  let cleanup () = try Unix.unlink temporary with Unix.Unix_error _ -> () in
  match linked with
  | Error error ->
      cleanup ();
      Error error
  | Ok true ->
      let* () = fsync_directory directory in
      cleanup ();
      let* () = fsync_directory directory in
      Ok (Published object_ref)
  | Ok false ->
      cleanup ();
      let* existing = read_regular_file final in
      if String.equal existing bytes then Ok (Already_published object_ref)
      else Error (Object_collision object_ref)

let load repository ~object_ref =
  let* () = check_v2_root repository.root in
  let path = object_path repository object_ref in
  let* bytes = read_regular_file path in
  let* envelope =
    Envelope.decode bytes
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* () =
    Address.verify ~repository_id:repository.repository_id
      ~key:repository.address_key ~address:object_ref ~envelope
    |> Result.map_error (fun error -> Address_error error)
  in
  let* actual_ref, object_ = verified_envelope repository envelope in
  if Model.Opaque_object_ref.equal object_ref actual_ref then Ok object_
  else Error (Object_collision object_ref)

let quarantine_root repository =
  Filename.concat repository.root ".yeokcham/quarantine"

let quarantine_path repository ~generation ~object_ref =
  if not (lowercase_hex generation 64) then
    Error (Invalid_quarantine_generation generation)
  else
    Ok
      (Filename.concat
         (Filename.concat (quarantine_root repository) generation)
         (Model.Opaque_object_ref.to_hex object_ref))

let ensure_quarantine_directory repository ~generation ~object_ref =
  let* destination = quarantine_path repository ~generation ~object_ref in
  let* () = ensure_directory (quarantine_root repository) in
  let* () = ensure_directory (Filename.dirname destination) in
  Ok destination

let file_if_present path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_REG then Ok true
    else Error (Invalid_object_path path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

let verified_candidate repository ~path ~object_ref ~expected_kind =
  let* bytes = read_regular_file path in
  let* envelope =
    Envelope.decode bytes
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* () =
    Address.verify ~repository_id:repository.repository_id
      ~key:repository.address_key ~address:object_ref ~envelope
    |> Result.map_error (fun error -> Address_error error)
  in
  let* actual_ref, object_ = verified_envelope repository envelope in
  if not (Model.Opaque_object_ref.equal object_ref actual_ref) then
    Error (Object_collision object_ref)
  else
    let actual = Object.kind object_ in
    if actual <> expected_kind then
      Error
        (Unexpected_object_kind { object_ref; expected = expected_kind; actual })
    else Ok (bytes, Int64.of_int (String.length bytes))

let candidate_if_present repository ~path ~object_ref ~expected_kind =
  let* present = file_if_present path in
  if present then
    verified_candidate repository ~path ~object_ref ~expected_kind
    |> Result.map (fun candidate -> Some candidate)
  else Ok None

let foreign_quarantine_candidate repository ~generation ~object_ref =
  let root = quarantine_root repository in
  let* entries =
    try
      match (Unix.lstat root).Unix.st_kind with
      | Unix.S_DIR -> read_directory root
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Error (Invalid_object_path root)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"lstat" ~path:root error)
  in
  let candidate = Model.Opaque_object_ref.to_hex object_ref in
  let rec inspect = function
    | [] -> Ok false
    | entry :: rest -> (
        let directory = Filename.concat root entry in
        if not (lowercase_hex entry 64) then
          Error (Invalid_object_path directory)
        else if String.equal entry generation then inspect rest
        else
          let* () =
            try
              if (Unix.lstat directory).Unix.st_kind = Unix.S_DIR then Ok ()
              else Error (Invalid_object_path directory)
            with Unix.Unix_error (error, _, _) ->
              Error (io_error ~operation:"lstat" ~path:directory error)
          in
          let path = Filename.concat directory candidate in
          try
            match (Unix.lstat path).Unix.st_kind with
            | Unix.S_REG -> Ok true
            | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
            | Unix.S_SOCK ->
                Error (Invalid_object_path path)
          with
          | Unix.Unix_error (Unix.ENOENT, _, _) -> inspect rest
          | Unix.Unix_error (error, _, _) ->
              Error (io_error ~operation:"lstat" ~path error))
  in
  inspect entries

let quarantine repository ~generation ~object_ref ~expected_kind =
  let* () = check_v2_root repository.root in
  let* destination =
    ensure_quarantine_directory repository ~generation ~object_ref
  in
  let source = object_path repository object_ref in
  let source_directory = Filename.dirname source in
  let destination_directory = Filename.dirname destination in
  let rec move retries =
    let* source_candidate =
      candidate_if_present repository ~path:source ~object_ref ~expected_kind
    in
    let* destination_candidate =
      candidate_if_present repository ~path:destination ~object_ref
        ~expected_kind
    in
    match (source_candidate, destination_candidate) with
    | Some (_source_bytes, source_size), None -> (
        try
          Unix.link source destination;
          let* () = fsync_directory destination_directory in
          let* () =
            try
              Unix.unlink source;
              Ok ()
            with Unix.Unix_error (error, _, _) ->
              Error (io_error ~operation:"unlink" ~path:source error)
          in
          let* () = fsync_directory source_directory in
          Ok (Quarantined source_size)
        with
        | Unix.Unix_error ((Unix.EEXIST | Unix.ENOENT), _, _) when retries > 0
          ->
            move (retries - 1)
        | Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"link" ~path:destination error))
    | Some (source_bytes, source_size), Some (destination_bytes, _) ->
        if not (String.equal source_bytes destination_bytes) then
          Error (Quarantine_target_collision object_ref)
        else
          let* () = fsync_directory destination_directory in
          let* () =
            try
              Unix.unlink source;
              Ok ()
            with Unix.Unix_error (error, _, _) ->
              Error (io_error ~operation:"unlink" ~path:source error)
          in
          let* () = fsync_directory source_directory in
          Ok (Already_quarantined source_size)
    | None, Some (_, destination_size) ->
        Ok (Already_quarantined destination_size)
    | None, None ->
        let* foreign =
          foreign_quarantine_candidate repository ~generation ~object_ref
        in
        if foreign then
          Error (Quarantine_candidate_in_other_generation object_ref)
        else Error (Quarantine_candidate_missing object_ref)
  in
  move 1

let prune_quarantine repository ~generation ~object_ref ~expected_kind =
  let* () = check_v2_root repository.root in
  let* destination = quarantine_path repository ~generation ~object_ref in
  let source = object_path repository object_ref in
  let destination_directory = Filename.dirname destination in
  let* source_candidate =
    candidate_if_present repository ~path:source ~object_ref ~expected_kind
  in
  let* destination_candidate =
    candidate_if_present repository ~path:destination ~object_ref ~expected_kind
  in
  match (source_candidate, destination_candidate) with
  | Some _, None | Some _, Some _ ->
      Error (Quarantine_source_still_present object_ref)
  | None, Some (_, size) ->
      let* () =
        try
          Unix.unlink destination;
          Ok ()
        with Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"unlink" ~path:destination error)
      in
      let* () = fsync_directory destination_directory in
      Ok (Pruned size)
  | None, None ->
      let* foreign =
        foreign_quarantine_candidate repository ~generation ~object_ref
      in
      if foreign then
        Error (Quarantine_candidate_in_other_generation object_ref)
      else Ok Already_pruned
