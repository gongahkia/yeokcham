module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Store = Yeokcham_store
module V2_envelope = Yeokcham_v2_envelope
module V2_restore_journal = Yeokcham_v2_restore_journal
module V2_transaction = Yeokcham_v2_transaction

type classification =
  | Empty
  | V2
  | Legacy
  | Mixed_or_unknown of string
  | Incomplete of string

type node_kind = Directory | File

type entry = {
  kind : node_kind;
  path : string list;
  mode : int;
  size : int64;
  digest : string;
}

type manifest = { entries : entry list }

type archive_plan = {
  root : string;
  destination : string;
  manifest_destination : string;
  pending_manifest : string;
  manifest : manifest;
}

type archive_result = { archive_path : string; manifest_path : string }

type archive_outcome =
  | Archived of archive_result
  | Already_archived of archive_result

type reset_outcome = Reset | Already_reset

type error =
  | Root_not_directory of string
  | Io_error of { operation : string; path : string; message : string }
  | Unsafe_archive_name of string
  | Not_legacy of classification
  | Archive_already_exists of string
  | Manifest_already_exists of string
  | Pending_manifest_mismatch of string
  | Archive_incomplete of string
  | Archive_manifest_invalid of { path : string; detail : string }
  | Archive_verification_failed of { path : string; detail : string }
  | Confirmation_required
  | V2_initialization_error of Store.error

let ( let* ) = Result.bind
let metadata_name = ".yeokcham"
let format_name = "format"
let bootstrap_name = "bootstrap"
let recovery_name = "recovery"
let objects_name = "objects"
let refs_name = "refs"
let locks_name = "locks"
let journal_name = "journal"
let quarantine_name = "quarantine"
let reclamation_name = "reclamation"
let reclamation_lock_name = "cache-reclamation.lock"
let manifest_suffix = ".legacy-archive-manifest-v1"
let pending_suffix = ".legacy-archive-manifest-v1.pending"
let max_manifest_entries = 100_000
let max_path_components = 128
let max_component_bytes = 255
let max_manifest_bytes = 64 * 1024 * 1024

let classification_to_string = function
  | Empty -> "empty"
  | V2 -> "v2"
  | Legacy -> "legacy"
  | Mixed_or_unknown detail -> "mixed or unknown: " ^ detail
  | Incomplete detail -> "incomplete: " ^ detail

let error_to_string = function
  | Root_not_directory path ->
      Printf.sprintf "repository root is not a directory: %s" path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Unsafe_archive_name name -> Printf.sprintf "unsafe archive name: %S" name
  | Not_legacy classification ->
      Printf.sprintf "archive requires a validated legacy repository, found %s"
        (classification_to_string classification)
  | Archive_already_exists path ->
      Printf.sprintf "archive already exists: %s" path
  | Manifest_already_exists path ->
      Printf.sprintf "archive manifest already exists: %s" path
  | Pending_manifest_mismatch path ->
      Printf.sprintf
        "pending archive manifest does not match this archive plan: %s" path
  | Archive_incomplete path ->
      Printf.sprintf "archive is incomplete and requires explicit recovery: %s"
        path
  | Archive_manifest_invalid { path; detail } ->
      Printf.sprintf "archive manifest is invalid at %s: %s" path detail
  | Archive_verification_failed { path; detail } ->
      Printf.sprintf "archive verification failed at %s: %s" path detail
  | Confirmation_required -> "reset requires --confirm-v2-reset"
  | V2_initialization_error error -> Store.error_to_string error

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let lstat_or_missing path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let lstat path =
  match lstat_or_missing path with
  | Ok (Some stat) -> Ok stat
  | Ok None ->
      Error
        (Io_error
           {
             operation = "lstat";
             path;
             message = "path disappeared during inspection";
           })
  | Error error -> Error error

let ensure_directory path =
  let* stat = lstat path in
  if stat.Unix.st_kind = Unix.S_DIR then Ok ()
  else Error (Root_not_directory path)

let same_node left right =
  left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
  && left.Unix.st_kind = right.Unix.st_kind

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        try
          Unix.fsync descriptor;
          Ok ()
        with
        | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _)
          ->
            Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error (io_error "fsync directory" path error))
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _) ->
      Ok ()
  | Unix.Unix_error (error, _, _) ->
      Error (io_error "open directory for fsync" path error)

let read_directory path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
  with Sys_error message ->
    Error (Io_error { operation = "read directory"; path; message })

let valid_component component =
  (not (String.is_empty component))
  && (not (String.equal component "."))
  && (not (String.equal component ".."))
  && (not (String.contains component '/'))
  && (not (String.contains component '\000'))
  && String.length component <= max_component_bytes

let path_key path = String.concat "\000" path

let compare_entry left right =
  String.compare (path_key left.path) (path_key right.path)

let read_regular_file ~limit path =
  let* initial = lstat path in
  if initial.Unix.st_kind <> Unix.S_REG then
    Error
      (Archive_verification_failed { path; detail = "expected a regular file" })
  else if initial.Unix.st_size > limit then
    Error
      (Archive_verification_failed
         {
           path;
           detail = Printf.sprintf "file exceeds %d-byte inspection limit" limit;
         })
  else
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close descriptor with Unix.Unix_error _ -> ())
        (fun () ->
          let opened = Unix.fstat descriptor in
          if opened.Unix.st_kind <> Unix.S_REG || not (same_node initial opened)
          then
            Error
              (Archive_verification_failed
                 { path; detail = "file changed while opening" })
          else
            let bytes = Bytes.create opened.Unix.st_size in
            let rec loop offset =
              if offset = opened.Unix.st_size then Ok ()
              else
                try
                  match
                    Unix.read descriptor bytes offset
                      (opened.Unix.st_size - offset)
                  with
                  | 0 ->
                      Error
                        (Archive_verification_failed
                           { path; detail = "file shortened while reading" })
                  | count -> loop (offset + count)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error "read" path error)
            in
            let* () = loop 0 in
            let extra = Bytes.create 1 in
            let* extra_count =
              try Ok (Unix.read descriptor extra 0 1)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error "read" path error)
            in
            let* final = lstat path in
            if
              extra_count <> 0
              || (not (same_node opened final))
              || final.Unix.st_size <> opened.Unix.st_size
              || final.Unix.st_perm <> opened.Unix.st_perm
            then
              Error
                (Archive_verification_failed
                   { path; detail = "file changed while reading" })
            else Ok (Bytes.unsafe_to_string bytes))
    with Unix.Unix_error (error, _, _) -> Error (io_error "open" path error)

let digest_regular_file path initial =
  if initial.Unix.st_kind <> Unix.S_REG then
    Error
      (Archive_verification_failed { path; detail = "expected a regular file" })
  else
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close descriptor with Unix.Unix_error _ -> ())
        (fun () ->
          let opened = Unix.fstat descriptor in
          if opened.Unix.st_kind <> Unix.S_REG || not (same_node initial opened)
          then
            Error
              (Archive_verification_failed
                 { path; detail = "file changed while opening" })
          else
            let buffer = Bytes.create 65_536 in
            let rec loop remaining context =
              if remaining = 0 then Ok context
              else
                try
                  let requested = min remaining (Bytes.length buffer) in
                  match Unix.read descriptor buffer 0 requested with
                  | 0 ->
                      Error
                        (Archive_verification_failed
                           { path; detail = "file shortened while hashing" })
                  | count ->
                      loop (remaining - count)
                        (Hash.feed_bytes context ~off:0 ~len:count buffer)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error "read" path error)
            in
            let* context = loop opened.Unix.st_size Hash.empty in
            let extra = Bytes.create 1 in
            let* extra_count =
              try Ok (Unix.read descriptor extra 0 1)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error "read" path error)
            in
            let* final = lstat path in
            if
              extra_count <> 0
              || (not (same_node opened final))
              || final.Unix.st_size <> opened.Unix.st_size
              || final.Unix.st_perm <> opened.Unix.st_perm
            then
              Error
                (Archive_verification_failed
                   { path; detail = "file changed while hashing" })
            else Ok (Hash.get context |> Hash.to_raw_string))
    with Unix.Unix_error (error, _, _) -> Error (io_error "open" path error)

let inventory_tree root =
  let rec visit path components entries =
    let* stat = lstat path in
    match stat.Unix.st_kind with
    | Unix.S_LNK ->
        Error
          (Archive_verification_failed
             { path; detail = "symbolic links are not accepted for cutover" })
    | Unix.S_DIR ->
        if List.length components > max_path_components then
          Error
            (Archive_verification_failed
               { path; detail = "path nesting is too deep" })
        else
          let* names = read_directory path in
          let* entries =
            List.fold_left
              (fun result name ->
                let* entries = result in
                if not (valid_component name) then
                  Error
                    (Archive_verification_failed
                       {
                         path = Filename.concat path name;
                         detail = "unsafe path component";
                       })
                else
                  visit
                    (Filename.concat path name)
                    (components @ [ name ]) entries)
              (Ok entries) names
          in
          let* final = lstat path in
          if
            (not (same_node stat final))
            || stat.Unix.st_perm <> final.Unix.st_perm
          then
            Error
              (Archive_verification_failed
                 { path; detail = "directory changed while inspecting" })
          else if components = [] then Ok entries
          else
            Ok
              ({
                 kind = Directory;
                 path = components;
                 mode = stat.Unix.st_perm land 0o7777;
                 size = 0L;
                 digest = "";
               }
              :: entries)
    | Unix.S_REG ->
        let* digest = digest_regular_file path stat in
        Ok
          ({
             kind = File;
             path = components;
             mode = stat.Unix.st_perm land 0o7777;
             size = Int64.of_int stat.Unix.st_size;
             digest;
           }
          :: entries)
    | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
        Error
          (Archive_verification_failed
             {
               path;
               detail = "only regular files and directories are accepted";
             })
  in
  let* entries = visit root [] [] in
  let entries = List.sort compare_entry entries in
  if List.length entries > max_manifest_entries then
    Error
      (Archive_verification_failed
         { path = root; detail = "tree has too many entries" })
  else Ok { entries }

let expect_array name count = function
  | Encoding.Array values when List.length values = count -> Ok values
  | Encoding.Array _ ->
      Error (Printf.sprintf "%s has the wrong field count" name)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Printf.sprintf "%s must be an array" name)

let expect_any_array name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Printf.sprintf "%s must be an array" name)

let expect_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (name ^ " must be an integer")

let expect_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (name ^ " must be bytes")

let array values =
  match Encoding.array values with
  | Ok value -> Ok value
  | Error error -> Error (Encoding.construction_error_to_string error)

let entry_value entry =
  let* path = array (List.map Encoding.bytes entry.path) in
  let kind = match entry.kind with Directory -> 0L | File -> 1L in
  array
    [
      Encoding.integer kind;
      path;
      Encoding.integer (Int64.of_int entry.mode);
      Encoding.integer entry.size;
      Encoding.bytes entry.digest;
    ]

let manifest_value manifest =
  let rec values reversed = function
    | [] -> Ok (List.rev reversed)
    | entry :: rest ->
        let* value = entry_value entry in
        values (value :: reversed) rest
  in
  let* entries = values [] manifest.entries in
  let* entries = array entries in
  array [ Encoding.integer 1L; entries ]

let manifest_encode manifest =
  match manifest_value manifest with
  | Ok value -> Encoding.encode value
  | Error message -> invalid_arg ("invalid archive manifest: " ^ message)

let validate_entry entry =
  if entry.path = [] || List.length entry.path > max_path_components then
    Error "manifest entry has an invalid path depth"
  else if not (List.for_all valid_component entry.path) then
    Error "manifest entry has an unsafe path component"
  else if entry.mode < 0 || entry.mode > 0o7777 then
    Error "manifest entry has an invalid mode"
  else if Int64.compare entry.size 0L < 0 then
    Error "manifest entry has a negative size"
  else
    match entry.kind with
    | Directory
      when (not (Int64.equal entry.size 0L))
           || not (String.is_empty entry.digest) ->
        Error "manifest directory entry has file metadata"
    | File when String.length entry.digest <> Hash.digest_size ->
        Error "manifest file digest must be 32 bytes"
    | Directory | File -> Ok entry

let decode_entry value =
  let* fields = expect_array "manifest entry" 5 value in
  match fields with
  | [ kind; path; mode; size; digest ] ->
      let* kind = expect_integer "manifest entry kind" kind in
      let* path = expect_any_array "manifest entry path" path in
      let rec components reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* component = expect_bytes "manifest path component" value in
            components (component :: reversed) rest
      in
      let* path = components [] path in
      let* mode = expect_integer "manifest entry mode" mode in
      let* size = expect_integer "manifest entry size" size in
      let* digest = expect_bytes "manifest entry digest" digest in
      let* kind =
        match kind with
        | 0L -> Ok Directory
        | 1L -> Ok File
        | _ -> Error "manifest entry has an unknown kind"
      in
      let* mode =
        if Int64.compare mode (Int64.of_int max_int) > 0 then
          Error "manifest entry mode is out of range"
        else Ok (Int64.to_int mode)
      in
      validate_entry { kind; path; mode; size; digest }
  | _ -> assert false

let manifest_decode bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error Encoding.decode_error_to_string
  in
  let* fields = expect_array "archive manifest" 2 value in
  match fields with
  | [ version; entries ] -> (
      let* version = expect_integer "archive manifest version" version in
      if not (Int64.equal version 1L) then
        Error "unsupported archive manifest version"
      else
        match entries with
        | Encoding.Array values ->
            if List.length values > max_manifest_entries then
              Error "archive manifest has too many entries"
            else
              let rec decode reversed = function
                | [] -> Ok (List.rev reversed)
                | value :: rest ->
                    let* entry = decode_entry value in
                    decode (entry :: reversed) rest
              in
              let* entries = decode [] values in
              let sorted = List.sort compare_entry entries in
              if entries <> sorted then
                Error "archive manifest entries are not strictly ordered"
              else
                let rec distinct = function
                  | [] | [ _ ] -> true
                  | left :: (right :: _ as rest) ->
                      (not
                         (String.equal (path_key left.path)
                            (path_key right.path)))
                      && distinct rest
                in
                if not (distinct entries) then
                  Error "archive manifest has duplicate paths"
                else
                  let manifest = { entries } in
                  if String.equal (manifest_encode manifest) bytes then
                    Ok manifest
                  else Error "archive manifest bytes are noncanonical"
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
            Error "archive manifest entries must be an array")
  | _ -> assert false

let read_manifest path =
  let* bytes = read_regular_file ~limit:max_manifest_bytes path in
  manifest_decode bytes
  |> Result.map_error (fun detail -> Archive_manifest_invalid { path; detail })

let same_manifest left right = left = right

let has_exact_names directory expected =
  let* names = read_directory directory in
  if names = expected then Ok ()
  else
    Error
      (Archive_verification_failed
         {
           path = directory;
           detail =
             "unexpected or missing root entries: " ^ String.concat "," names;
         })

let is_hex_name value length =
  String.length value = length
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let validate_v1_object_file path hex =
  let* expected =
    Store.Stored_object_id.of_hex hex
    |> Result.map_error (fun error ->
        Archive_verification_failed
          { path; detail = Store.Stored_object_id.parse_error_to_string error })
  in
  let* bytes = read_regular_file ~limit:Store.max_object_bytes path in
  let* envelope =
    Envelope.decode bytes
    |> Result.map_error (fun error ->
        Archive_verification_failed
          { path; detail = Envelope.decode_error_to_string error })
  in
  let actual = Store.id_of_envelope envelope in
  if Store.Stored_object_id.equal expected actual then Ok ()
  else
    Error
      (Archive_verification_failed
         { path; detail = "object name does not match canonical bytes" })

let validate_v1_objects objects =
  let* shards = read_directory objects in
  let rec validate_leaves shard prefix = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat prefix name in
        let* stat = lstat path in
        if String.starts_with ~prefix:"." name && stat.Unix.st_kind = Unix.S_REG
        then validate_leaves shard prefix rest
        else if stat.Unix.st_kind <> Unix.S_REG || not (is_hex_name name 60)
        then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V1 object name" })
        else
          let* () =
            validate_v1_object_file path
              (shard ^ Filename.basename prefix ^ name)
          in
          validate_leaves shard prefix rest
  in
  let rec validate_prefixes shard = function
    | [] -> Ok ()
    | prefix :: rest ->
        let path = Filename.concat (Filename.concat objects shard) prefix in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_DIR || not (is_hex_name prefix 2) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V1 object prefix" })
        else
          let* names = read_directory path in
          let* () = validate_leaves shard path names in
          validate_prefixes shard rest
  in
  let rec validate_shards = function
    | [] -> Ok ()
    | shard :: rest ->
        let path = Filename.concat objects shard in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_DIR || not (is_hex_name shard 2) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V1 object shard" })
        else
          let* prefixes = read_directory path in
          let* () = validate_prefixes shard prefixes in
          validate_shards rest
  in
  validate_shards shards

let validate_v2_object_file path =
  let* bytes =
    read_regular_file ~limit:(V2_envelope.max_ciphertext_bytes + 128) path
  in
  V2_envelope.decode bytes
  |> Result.map_error (fun error ->
      Archive_verification_failed
        { path; detail = V2_envelope.error_to_string error })
  |> Result.map (fun _ -> ())

let decimal_name name =
  String.length name > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) name

let is_v2_object_temporary_filename name =
  match String.split_on_char '.' name with
  | [ ""; object_name; staging ] when is_hex_name object_name 60 -> (
      match String.split_on_char '-' staging with
      | [ ("ledger" | "object"); pid; attempt ] ->
          decimal_name pid && decimal_name attempt
      | _ -> false)
  | _ -> false

let lstat_temporary_if_present path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let validate_v2_objects objects =
  let rec validate_leaves prefix = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat prefix name in
        if is_v2_object_temporary_filename name then
          let* stat = lstat_temporary_if_present path in
          match stat with
          | None -> validate_leaves prefix rest
          | Some stat when stat.Unix.st_kind = Unix.S_REG ->
              validate_leaves prefix rest
          | Some _ ->
              Error
                (Archive_verification_failed
                   {
                     path;
                     detail = "V2 object temporary is not a regular file";
                   })
        else
          let* stat = lstat path in
          if stat.Unix.st_kind <> Unix.S_REG || not (is_hex_name name 60) then
            Error
              (Archive_verification_failed
                 { path; detail = "invalid V2 opaque object name" })
          else
            let* () = validate_v2_object_file path in
            validate_leaves prefix rest
  in
  let rec validate_prefixes shard = function
    | [] -> Ok ()
    | prefix :: rest ->
        let path = Filename.concat (Filename.concat objects shard) prefix in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_DIR || not (is_hex_name prefix 2) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V2 opaque object prefix" })
        else
          let* names = read_directory path in
          let* () = validate_leaves path names in
          validate_prefixes shard rest
  in
  let rec validate_shards = function
    | [] -> Ok ()
    | shard :: rest ->
        let path = Filename.concat objects shard in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_DIR || not (is_hex_name shard 2) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V2 opaque object shard" })
        else
          let* prefixes = read_directory path in
          let* () = validate_prefixes shard prefixes in
          validate_shards rest
  in
  let* shards = read_directory objects in
  validate_shards shards

let validate_v2_quarantine quarantine =
  let rec validate_candidates directory = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat directory name in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_REG || not (is_hex_name name 64) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V2 quarantine candidate" })
        else
          let* () = validate_v2_object_file path in
          validate_candidates directory rest
  in
  let rec validate_generations = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat quarantine name in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_DIR || not (is_hex_name name 64) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V2 quarantine generation" })
        else
          let* candidates = read_directory path in
          let* () = validate_candidates path candidates in
          validate_generations rest
  in
  let* generations = read_directory quarantine in
  validate_generations generations

let is_v2_reclamation_temporary_filename name =
  match String.split_on_char '.' name with
  | [ ""; plan_id; staging ] when is_hex_name plan_id 64 -> (
      match String.split_on_char '-' staging with
      | [ "manifest"; pid; attempt ] -> decimal_name pid && decimal_name attempt
      | _ -> false)
  | _ -> false

let validate_v2_reclamation reclamation =
  let rec validate_entries directory = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat directory name in
        if is_v2_reclamation_temporary_filename name then
          let* stat = lstat_temporary_if_present path in
          match stat with
          | None -> validate_entries directory rest
          | Some stat ->
              if stat.Unix.st_kind = Unix.S_REG then
                validate_entries directory rest
              else
                Error
                  (Archive_verification_failed
                     {
                       path;
                       detail =
                         "V2 reclamation manifest temporary is not a regular \
                          file";
                     })
        else if not (String.equal name "manifest.cbor") then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V2 reclamation plan entry" })
        else
          let* stat = lstat path in
          if stat.Unix.st_kind = Unix.S_REG then validate_entries directory rest
          else
            Error
              (Archive_verification_failed
                 {
                   path;
                   detail = "V2 reclamation manifest is not a regular file";
                 })
  in
  let rec validate_plans = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat reclamation name in
        let* stat = lstat path in
        if stat.Unix.st_kind <> Unix.S_DIR || not (is_hex_name name 64) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V2 reclamation plan directory" })
        else
          let* entries = read_directory path in
          let* () = validate_entries path entries in
          validate_plans rest
  in
  let* plans = read_directory reclamation in
  validate_plans plans

let validate_v2_locks locks =
  let* names = read_directory locks in
  match names with
  | [] -> Ok ()
  | [ name ] when String.equal name reclamation_lock_name ->
      let path = Filename.concat locks name in
      let* stat = lstat path in
      if stat.Unix.st_kind = Unix.S_REG then Ok ()
      else
        Error
          (Archive_verification_failed
             { path; detail = "V2 reclamation lock is not a regular file" })
  | _ ->
      Error
        (Archive_verification_failed
           { path = locks; detail = "V2 root contains unknown lock state" })

type v2_journal_entry =
  | Prepared of V2_transaction.Transaction_id.t * V2_transaction.prepare
  | Committed of V2_transaction.Transaction_id.t * V2_transaction.commit
  | Restore of V2_restore_journal.t

let validate_v2_journal_entry journal name =
  let path = Filename.concat journal name in
  if V2_restore_journal.is_journal_filename name then
    let* journal_file =
      V2_restore_journal.parse_filename name
      |> Result.map_error (fun error ->
          Archive_verification_failed
            { path; detail = V2_restore_journal.error_to_string error })
    in
    let* bytes =
      read_regular_file ~limit:V2_restore_journal.max_record_bytes path
    in
    let* record =
      V2_restore_journal.decode bytes
      |> Result.map_error (fun error ->
          Archive_verification_failed
            { path; detail = V2_restore_journal.error_to_string error })
    in
    if
      V2_restore_journal.Model.Transaction_id.equal
        (V2_restore_journal.journal_file_operation_id journal_file)
        (V2_restore_journal.operation_id record)
      && Int64.equal
           (V2_restore_journal.journal_file_generation journal_file)
           (V2_restore_journal.generation record)
    then Ok (Restore record)
    else
      Error
        (Archive_verification_failed
           {
             path;
             detail = "V2 restore journal identity does not match its filename";
           })
  else
    let* journal_file =
      V2_transaction.parse_journal_filename name
      |> Result.map_error (fun error ->
          Archive_verification_failed
            { path; detail = V2_transaction.error_to_string error })
    in
    match journal_file with
    | V2_transaction.Prepare_file transaction_id ->
        let* bytes =
          read_regular_file ~limit:V2_transaction.max_prepare_bytes path
        in
        let* prepare =
          V2_transaction.decode_prepare bytes
          |> Result.map_error (fun error ->
              Archive_verification_failed
                { path; detail = V2_transaction.error_to_string error })
        in
        if
          V2_transaction.Transaction_id.equal transaction_id
            (V2_transaction.prepare_transaction_id prepare)
        then Ok (Prepared (transaction_id, prepare))
        else
          Error
            (Archive_verification_failed
               {
                 path;
                 detail =
                   "V2 transaction prepare ID does not match its filename";
               })
    | V2_transaction.Commit_file transaction_id ->
        let* bytes =
          read_regular_file ~limit:V2_transaction.max_commit_bytes path
        in
        let* commit =
          V2_transaction.decode_commit bytes
          |> Result.map_error (fun error ->
              Archive_verification_failed
                { path; detail = V2_transaction.error_to_string error })
        in
        if
          V2_transaction.Transaction_id.equal transaction_id
            (V2_transaction.commit_transaction_id commit)
        then Ok (Committed (transaction_id, commit))
        else
          Error
            (Archive_verification_failed
               {
                 path;
                 detail = "V2 transaction commit ID does not match its filename";
               })

let validate_v2_journal journal =
  let* names = read_directory journal in
  let rec read_entries result = function
    | [] -> Ok (List.rev result)
    | name :: rest
      when V2_transaction.is_temporary_journal_filename name
           || V2_restore_journal.is_temporary_journal_filename name -> (
        let path = Filename.concat journal name in
        let* stat = lstat_temporary_if_present path in
        match stat with
        | None -> read_entries result rest
        | Some stat ->
            if stat.Unix.st_kind <> Unix.S_REG then
              Error
                (Archive_verification_failed
                   {
                     path;
                     detail = "V2 journal temporary is not a regular file";
                   })
            else read_entries result rest)
    | name :: rest ->
        let* entry = validate_v2_journal_entry journal name in
        read_entries (entry :: result) rest
  in
  let* entries = read_entries [] names in
  let prepares =
    List.filter_map
      (function
        | Prepared (transaction_id, prepare) -> Some (transaction_id, prepare)
        | Committed _ | Restore _ -> None)
      entries
  in
  let rec validate_commits = function
    | [] -> Ok ()
    | (Prepared _ | Restore _) :: rest -> validate_commits rest
    | Committed (transaction_id, commit) :: rest ->
        let prepare =
          List.find_opt
            (fun (candidate, _) ->
              V2_transaction.Transaction_id.equal candidate transaction_id)
            prepares
        in
        let* () =
          match prepare with
          | None ->
              Error
                (Archive_verification_failed
                   {
                     path =
                       Filename.concat journal
                         (V2_transaction.commit_filename transaction_id);
                     detail = "V2 transaction commit has no matching prepare";
                   })
          | Some (_, prepare) ->
              V2_transaction.validate_commit ~prepare commit
              |> Result.map_error (fun error ->
                  Archive_verification_failed
                    {
                      path =
                        Filename.concat journal
                          (V2_transaction.commit_filename transaction_id);
                      detail = V2_transaction.error_to_string error;
                    })
        in
        validate_commits rest
  in
  let* () = validate_commits entries in
  let restores =
    List.filter_map
      ((function Restore record -> Some record | _ -> None) [@warning "-4"])
      entries
    |> List.sort (fun left right ->
        let operation =
          V2_restore_journal.Model.Transaction_id.compare
            (V2_restore_journal.operation_id left)
            (V2_restore_journal.operation_id right)
        in
        if operation <> 0 then operation
        else
          Int64.compare
            (V2_restore_journal.generation left)
            (V2_restore_journal.generation right))
  in
  let validate_restore_chain records =
    match records with
    | [] -> Ok ()
    | first :: _ ->
        V2_restore_journal.validate_chain records
        |> Result.map_error (fun error ->
            Archive_verification_failed
              {
                path =
                  Filename.concat journal (V2_restore_journal.filename first);
                detail = V2_restore_journal.error_to_string error;
              })
  in
  let rec validate_restores current = function
    | [] -> (
        match current with
        | [] -> Ok ()
        | _ -> validate_restore_chain (List.rev current))
    | record :: rest -> (
        match current with
        | previous :: _
          when V2_restore_journal.Model.Transaction_id.equal
                 (V2_restore_journal.operation_id previous)
                 (V2_restore_journal.operation_id record) ->
            validate_restores (record :: current) rest
        | [] -> validate_restores [ record ] rest
        | _ ->
            let* () = validate_restore_chain (List.rev current) in
            validate_restores [ record ] rest)
  in
  validate_restores [] restores

let validate_v1_direct_refs refs =
  let* names = read_directory refs in
  let rec validate = function
    | [] -> Ok ()
    | name :: rest ->
        let path = Filename.concat refs name in
        let* stat = lstat path in
        if not (valid_component name) then
          Error
            (Archive_verification_failed
               { path; detail = "invalid V1 ref name" })
        else if stat.Unix.st_kind = Unix.S_DIR then validate rest
        else if stat.Unix.st_kind <> Unix.S_REG then
          Error
            (Archive_verification_failed
               { path; detail = "V1 ref is not a regular file" })
        else if String.equal name "scratch-head" then
          let* bytes = read_regular_file ~limit:max_manifest_bytes path in
          match Store.Mutable_ref.decode bytes with
          | Ok _ -> validate rest
          | Error detail -> Error (Archive_verification_failed { path; detail })
        else validate rest
  in
  validate names

let validate_legacy_tree metadata =
  let expected =
    [ format_name; locks_name; objects_name; refs_name ]
    |> List.sort String.compare
  in
  let* () = has_exact_names metadata expected in
  let* format =
    read_regular_file ~limit:4096 (Filename.concat metadata format_name)
  in
  if not (String.equal format Store.repository_format) then
    Error
      (Archive_verification_failed
         {
           path = Filename.concat metadata format_name;
           detail = "not the V1 repository format";
         })
  else
    let* () = ensure_directory (Filename.concat metadata objects_name) in
    let* () = ensure_directory (Filename.concat metadata refs_name) in
    let* () = ensure_directory (Filename.concat metadata locks_name) in
    let* () = validate_v1_objects (Filename.concat metadata objects_name) in
    validate_v1_direct_refs (Filename.concat metadata refs_name)

let directory_is_empty path =
  let* names = read_directory path in
  Ok (names = [])

let v2_layout metadata =
  let required =
    [
      bootstrap_name;
      format_name;
      journal_name;
      locks_name;
      objects_name;
      refs_name;
    ]
    |> List.sort String.compare
  in
  let allowed =
    List.sort String.compare
      (recovery_name :: quarantine_name :: reclamation_name :: required)
  in
  let* names = read_directory metadata in
  let missing = List.filter (fun name -> not (List.mem name names)) required in
  let unexpected =
    List.filter (fun name -> not (List.mem name allowed)) names
  in
  let* () =
    if missing = [] && unexpected = [] then Ok ()
    else
      Error
        (Archive_verification_failed
           {
             path = metadata;
             detail =
               "unexpected or missing root entries: " ^ String.concat "," names;
           })
  in
  let* format =
    read_regular_file ~limit:4096 (Filename.concat metadata format_name)
  in
  if not (String.equal format Store.root_format) then
    Error
      (Archive_verification_failed
         {
           path = Filename.concat metadata format_name;
           detail = "not the V2 root format";
         })
  else
    let* () = ensure_directory (Filename.concat metadata bootstrap_name) in
    let* () = ensure_directory (Filename.concat metadata objects_name) in
    let* () = ensure_directory (Filename.concat metadata refs_name) in
    let locks = Filename.concat metadata locks_name in
    let* () = ensure_directory locks in
    let* () = validate_v2_locks locks in
    let* () = ensure_directory (Filename.concat metadata journal_name) in
    let quarantine = Filename.concat metadata quarantine_name in
    let* () =
      match lstat_or_missing quarantine with
      | Error error -> Error error
      | Ok None -> Ok ()
      | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR ->
          validate_v2_quarantine quarantine
      | Ok (Some _) ->
          Error
            (Archive_verification_failed
               {
                 path = quarantine;
                 detail = "V2 quarantine is not a directory";
               })
    in
    let reclamation = Filename.concat metadata reclamation_name in
    match lstat_or_missing reclamation with
    | Error error -> Error error
    | Ok None -> Ok ()
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR ->
        validate_v2_reclamation reclamation
    | Ok (Some _) ->
        Error
          (Archive_verification_failed
             {
               path = reclamation;
               detail = "V2 reclamation is not a directory";
             })

let has_v1_artifacts metadata =
  let objects = Filename.concat metadata objects_name in
  let refs = Filename.concat metadata refs_name in
  let locks = Filename.concat metadata locks_name in
  let journal = Filename.concat metadata journal_name in
  let* objects_empty = directory_is_empty objects in
  let* refs_empty = directory_is_empty refs in
  let* () = validate_v2_locks locks in
  let* () = validate_v2_journal journal in
  if objects_empty && refs_empty then Ok false
  else if refs_empty then
    let* () = validate_v2_objects objects in
    Ok false
  else
    let* () = validate_v1_objects objects in
    let* () = validate_v1_direct_refs refs in
    Ok true

let validate_archivable_legacy_tree metadata =
  let* format =
    read_regular_file ~limit:4096 (Filename.concat metadata format_name)
  in
  if String.equal format Store.repository_format then
    validate_legacy_tree metadata
  else if String.equal format Store.root_format then
    let* () = v2_layout metadata in
    let* contains_v1 = has_v1_artifacts metadata in
    if contains_v1 then Ok ()
    else
      Error
        (Archive_verification_failed
           { path = metadata; detail = "V2 root contains no legacy V1 state" })
  else
    Error
      (Archive_verification_failed
         {
           path = Filename.concat metadata format_name;
           detail = "unknown archive format";
         })

let detect ~root =
  let* () = ensure_directory root in
  let metadata = Filename.concat root metadata_name in
  match lstat_or_missing metadata with
  | Error error -> Error error
  | Ok None -> Ok Empty
  | Ok (Some stat) when stat.Unix.st_kind <> Unix.S_DIR ->
      Ok (Mixed_or_unknown "metadata root is not a directory")
  | Ok (Some _) -> (
      let* names = read_directory metadata in
      if not (List.mem format_name names) then
        Ok (Incomplete "metadata root has no format record")
      else
        match
          read_regular_file ~limit:4096 (Filename.concat metadata format_name)
        with
        | Error error -> Ok (Mixed_or_unknown (error_to_string error))
        | Ok format when String.equal format Store.repository_format -> (
            match validate_legacy_tree metadata with
            | Error error -> Ok (Mixed_or_unknown (error_to_string error))
            | Ok () -> (
                match inventory_tree metadata with
                | Ok _ -> Ok Legacy
                | Error error -> Ok (Mixed_or_unknown (error_to_string error))))
        | Ok format when String.equal format Store.root_format -> (
            let expected =
              [
                bootstrap_name;
                format_name;
                journal_name;
                locks_name;
                objects_name;
                refs_name;
              ]
              |> List.sort String.compare
            in
            let missing =
              List.filter (fun name -> not (List.mem name names)) expected
            in
            if missing <> [] then
              Ok
                (Incomplete ("V2 root is missing " ^ String.concat "," missing))
            else
              match v2_layout metadata with
              | Error error -> Ok (Mixed_or_unknown (error_to_string error))
              | Ok () -> (
                  match has_v1_artifacts metadata with
                  | Ok true -> Ok Legacy
                  | Ok false -> Ok V2
                  | Error error -> Ok (Mixed_or_unknown (error_to_string error))
                  ))
        | Ok _ ->
            Ok (Mixed_or_unknown "metadata root has an unknown format record"))

let safe_archive_name name =
  let allowed = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  String.length name > 0
  && String.length name <= 128
  && name.[0] <> '.'
  && String.for_all allowed name

let archive_paths ~root ~archive_name =
  let archive_path = Filename.concat root archive_name in
  (archive_path, archive_path ^ manifest_suffix, archive_path ^ pending_suffix)

let require_missing path make_error =
  match lstat_or_missing path with
  | Ok None -> Ok ()
  | Ok (Some _) -> Error (make_error path)
  | Error error -> Error error

let plan_archive ~root ~archive_name =
  if not (safe_archive_name archive_name) then
    Error (Unsafe_archive_name archive_name)
  else
    let* classification = detect ~root in
    match classification with
    | Legacy ->
        let metadata = Filename.concat root metadata_name in
        let* manifest = inventory_tree metadata in
        let archive_path, manifest_path, pending_path =
          archive_paths ~root ~archive_name
        in
        let* () =
          require_missing archive_path (fun path -> Archive_already_exists path)
        in
        let* () =
          require_missing manifest_path (fun path ->
              Manifest_already_exists path)
        in
        let* () =
          require_missing pending_path (fun path ->
              Pending_manifest_mismatch path)
        in
        Ok
          {
            root;
            destination = archive_path;
            manifest_destination = manifest_path;
            pending_manifest = pending_path;
            manifest;
          }
    | (Empty | V2 | Mixed_or_unknown _ | Incomplete _) as other ->
        Error (Not_legacy other)

let write_all descriptor path bytes =
  let rec loop offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        match
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        with
        | 0 ->
            Error
              (Io_error
                 { operation = "write"; path; message = "write returned zero" })
        | count -> loop (offset + count)
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "write" path error)
  in
  loop 0

let write_exclusive path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        let* () = write_all descriptor path (Bytes.of_string bytes) in
        try
          Unix.fsync descriptor;
          Ok ()
        with Unix.Unix_error (error, _, _) ->
          Error (io_error "fsync" path error))
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Error (Manifest_already_exists path)
  | Unix.Unix_error (error, _, _) ->
      Error (io_error "create manifest" path error)

let remove_if_present path =
  try
    Unix.unlink path;
    Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (error, _, _) -> Error (io_error "unlink" path error)

let prepare_pending plan =
  let bytes = manifest_encode plan.manifest in
  match lstat_or_missing plan.pending_manifest with
  | Error error -> Error error
  | Ok None ->
      let* () = write_exclusive plan.pending_manifest bytes in
      fsync_directory plan.root
  | Ok (Some _) ->
      let* manifest = read_manifest plan.pending_manifest in
      if same_manifest manifest plan.manifest then Ok ()
      else Error (Pending_manifest_mismatch plan.pending_manifest)

let publish_manifest ~root ~pending_path ~manifest_path =
  match lstat_or_missing manifest_path with
  | Error error -> Error error
  | Ok (Some _) -> Error (Manifest_already_exists manifest_path)
  | Ok None -> (
      try
        Unix.link pending_path manifest_path;
        let* () = fsync_directory root in
        let* () = remove_if_present pending_path in
        fsync_directory root
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "publish archive manifest" manifest_path error))

let archive_result plan =
  { archive_path = plan.destination; manifest_path = plan.manifest_destination }

let execute_archive plan =
  let metadata = Filename.concat plan.root metadata_name in
  let* () =
    require_missing plan.destination (fun path -> Archive_already_exists path)
  in
  let* () =
    require_missing plan.manifest_destination (fun path ->
        Manifest_already_exists path)
  in
  let* () = prepare_pending plan in
  let* classification = detect ~root:plan.root in
  let* () =
    match classification with
    | Legacy -> Ok ()
    | (Empty | V2 | Mixed_or_unknown _ | Incomplete _) as other ->
        Error (Not_legacy other)
  in
  let* current = inventory_tree metadata in
  if not (same_manifest current plan.manifest) then
    Error
      (Archive_verification_failed
         {
           path = metadata;
           detail = "legacy tree changed after archive preflight";
         })
  else
    try
      Unix.rename metadata plan.destination;
      let* () = fsync_directory plan.root in
      let* archived = inventory_tree plan.destination in
      if not (same_manifest archived plan.manifest) then
        Error
          (Archive_verification_failed
             {
               path = plan.destination;
               detail = "relocated archive does not match preflight manifest";
             })
      else
        let* () =
          publish_manifest ~root:plan.root ~pending_path:plan.pending_manifest
            ~manifest_path:plan.manifest_destination
        in
        Ok (Archived (archive_result plan))
    with Unix.Unix_error (error, _, _) ->
      Error (io_error "rename legacy repository" metadata error)

let verify_existing_archive ~root ~archive_name =
  let archive_path, manifest_path, pending_path =
    archive_paths ~root ~archive_name
  in
  let* archive_stat = lstat archive_path in
  if archive_stat.Unix.st_kind <> Unix.S_DIR then
    Error (Archive_incomplete archive_path)
  else
    let* () = validate_archivable_legacy_tree archive_path in
    let* actual = inventory_tree archive_path in
    match lstat_or_missing manifest_path with
    | Error error -> Error error
    | Ok (Some _) ->
        let* expected = read_manifest manifest_path in
        if same_manifest expected actual then
          let* () = remove_if_present pending_path in
          let* () = fsync_directory root in
          Ok (Already_archived { archive_path; manifest_path })
        else
          Error
            (Archive_verification_failed
               {
                 path = archive_path;
                 detail = "archive differs from its manifest";
               })
    | Ok None -> (
        match lstat_or_missing pending_path with
        | Error error -> Error error
        | Ok None -> Error (Archive_incomplete archive_path)
        | Ok (Some _) ->
            let* expected = read_manifest pending_path in
            if not (same_manifest expected actual) then
              Error
                (Archive_verification_failed
                   {
                     path = archive_path;
                     detail = "archive differs from pending manifest";
                   })
            else
              let* () = publish_manifest ~root ~pending_path ~manifest_path in
              Ok (Archived { archive_path; manifest_path }))

let archive ~root ~archive_name =
  if not (safe_archive_name archive_name) then
    Error (Unsafe_archive_name archive_name)
  else
    let* classification = detect ~root in
    match classification with
    | Legacy ->
        let* plan = plan_archive ~root ~archive_name in
        execute_archive plan
    | Empty -> verify_existing_archive ~root ~archive_name
    | (V2 | Mixed_or_unknown _ | Incomplete _) as other ->
        Error (Not_legacy other)

let verified_archive ~root ~archive_name =
  let archive_path, manifest_path, _ = archive_paths ~root ~archive_name in
  let* archive_stat = lstat archive_path in
  if archive_stat.Unix.st_kind <> Unix.S_DIR then
    Error (Archive_incomplete archive_path)
  else
    let* () = validate_archivable_legacy_tree archive_path in
    let* actual = inventory_tree archive_path in
    let* expected = read_manifest manifest_path in
    if same_manifest actual expected then Ok ()
    else
      Error
        (Archive_verification_failed
           { path = archive_path; detail = "archive differs from its manifest" })

let reset ~root ~archive_name ~confirm =
  if not confirm then Error Confirmation_required
  else if not (safe_archive_name archive_name) then
    Error (Unsafe_archive_name archive_name)
  else
    let* () = ensure_directory root in
    let* () = verified_archive ~root ~archive_name in
    let* classification = detect ~root in
    match classification with
    | Empty ->
        Store.init ~root
        |> Result.map (fun _ -> Reset)
        |> Result.map_error (fun error -> V2_initialization_error error)
    | V2 -> Ok Already_reset
    | Legacy | Mixed_or_unknown _ | Incomplete _ ->
        Error (Not_legacy classification)
