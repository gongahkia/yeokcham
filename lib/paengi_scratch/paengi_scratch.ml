module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Snapshot = Paengi_snapshot
module Store = Paengi_store

type path = string list
type source = Explicit | Scan

let compare_path = List.compare String.compare

type retention_reason =
  | User_pinned
  | Capsule_boundary of Paengi_id.Capsule_id.t
  | Release_boundary of Paengi_id.Release_id.t
  | Validation_passed of Paengi_id.Validation_id.t
  | Periodic_retention
  | Recent_window
  | Conflict_reference of Paengi_id.Conflict_id.t

type entry =
  | Directory
  | File of { mode : Snapshot.file_mode; content : Snapshot.Content.id }

type operation =
  | Create of { path : path; entry : entry }
  | Delete of { path : path; prior : entry }
  | Modify_content of {
      path : path;
      expected : Snapshot.Content.id;
      replacement : Snapshot.Content.id;
    }
  | Change_mode of {
      path : path;
      expected : Snapshot.file_mode;
      replacement : Snapshot.file_mode;
    }
  | Move of { source : path; destination : path; prior : entry }

module Event_id = struct
  type t = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal = Store.Stored_object_id.equal
end

module Checkpoint_id = struct
  type t = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal = Store.Stored_object_id.equal
end

module Retention_change_id = struct
  type t = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal = Store.Stored_object_id.equal
end

module Generation_id = struct
  type t = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal = Store.Stored_object_id.equal
end

module Cleanup_manifest_id = struct
  type t = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal = Store.Stored_object_id.equal
end

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Encoding_error of Encoding.construction_error
  | Envelope_error of Envelope.creation_error
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Invalid_path of path
  | Duplicate_path of path
  | Missing_parent of path
  | Parent_not_directory of path
  | Path_not_found of path
  | Path_already_exists of path
  | Expected_entry_mismatch of path
  | Expected_content_mismatch of path
  | Expected_mode_mismatch of path
  | Nonempty_directory of path
  | Move_into_descendant of { source : path; destination : path }
  | Invalid_object_id_length of int
  | Invalid_identity_length of int
  | Invalid_mode of int64
  | Invalid_source of int64
  | Invalid_retention_action of int64
  | Invalid_retention_reason of int64
  | Noncanonical_schema
  | Invalid_checkpoint_structure
  | Scratch_head_missing
  | Scratch_head_is_null
  | Scratch_already_initialized
  | Scratch_generation_is_null
  | Generation_corrupt of string
  | Checkpoint_not_retained of Checkpoint_id.t
  | Generation_alias_target_invalid of {
      logical : Checkpoint_id.t;
      detail : string;
    }
  | Generation_alias_snapshot_mismatch of Checkpoint_id.t
  | Retention_cycle of Retention_change_id.t
  | Checkpoint_cycle of Checkpoint_id.t
  | Checkpoint_event_mismatch of Checkpoint_id.t
  | Replay_mismatch of Checkpoint_id.t
  | Invalid_timeline_limit of int
  | Restore_destination_not_directory of string
  | Restore_external_change of {
      expected : Snapshot.Snapshot.id;
      actual : Snapshot.Snapshot.id;
    }
  | Restore_apply_error of {
      safety_checkpoint : Checkpoint_id.t option;
      path : string;
      operation : string;
      message : string;
    }
  | Restore_verification_mismatch of {
      expected : Snapshot.Snapshot.id;
      actual : Snapshot.Snapshot.id;
    }

let path_to_string path = String.concat "/" path

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected object type %d, got object type %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)
  | Invalid_schema message ->
      Printf.sprintf "invalid scratch schema: %s" message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported scratch schema version: %Ld" version
  | Invalid_path path ->
      Printf.sprintf "invalid scratch path: %s" (path_to_string path)
  | Duplicate_path path ->
      Printf.sprintf "duplicate scratch path: %s" (path_to_string path)
  | Missing_parent path ->
      Printf.sprintf "missing parent: %s" (path_to_string path)
  | Parent_not_directory path ->
      Printf.sprintf "parent is not a directory: %s" (path_to_string path)
  | Path_not_found path ->
      Printf.sprintf "path not found: %s" (path_to_string path)
  | Path_already_exists path ->
      Printf.sprintf "path already exists: %s" (path_to_string path)
  | Expected_entry_mismatch path ->
      Printf.sprintf "entry precondition failed: %s" (path_to_string path)
  | Expected_content_mismatch path ->
      Printf.sprintf "content precondition failed: %s" (path_to_string path)
  | Expected_mode_mismatch path ->
      Printf.sprintf "mode precondition failed: %s" (path_to_string path)
  | Nonempty_directory path ->
      Printf.sprintf "directory is not empty: %s" (path_to_string path)
  | Move_into_descendant { source; destination } ->
      Printf.sprintf "cannot move %s into %s" (path_to_string source)
        (path_to_string destination)
  | Invalid_object_id_length length ->
      Printf.sprintf "stored object ID must be 32 bytes, got %d" length
  | Invalid_identity_length length ->
      Printf.sprintf "retention identity must be 32 bytes, got %d" length
  | Invalid_mode mode -> Printf.sprintf "invalid scratch mode: %Ld" mode
  | Invalid_source source ->
      Printf.sprintf "invalid observation source: %Ld" source
  | Invalid_retention_action action ->
      Printf.sprintf "invalid retention action: %Ld" action
  | Invalid_retention_reason reason ->
      Printf.sprintf "invalid retention reason: %Ld" reason
  | Noncanonical_schema -> "scratch schema bytes are noncanonical"
  | Invalid_checkpoint_structure ->
      "initial checkpoints have neither parent nor event; non-initial \
       checkpoints have both"
  | Scratch_head_missing -> "scratch history is not initialized"
  | Scratch_head_is_null -> "scratch-head ref has an invalid null target"
  | Scratch_already_initialized -> "scratch history is already initialized"
  | Scratch_generation_is_null ->
      "scratch-generation ref has an invalid null target"
  | Generation_corrupt detail ->
      "active scratch generation is corrupt: " ^ detail
  | Checkpoint_not_retained identity ->
      Printf.sprintf "checkpoint is not retained: %s"
        (Store.Stored_object_id.to_hex
           (Checkpoint_id.stored_object_id identity))
  | Generation_alias_target_invalid { logical; detail } ->
      Printf.sprintf "generation alias target for %s is invalid: %s"
        (Store.Stored_object_id.to_hex (Checkpoint_id.stored_object_id logical))
        detail
  | Generation_alias_snapshot_mismatch logical ->
      Printf.sprintf "generation alias snapshot mismatch for %s"
        (Store.Stored_object_id.to_hex (Checkpoint_id.stored_object_id logical))
  | Retention_cycle identity ->
      Printf.sprintf "retention chain cycle at %s"
        (Store.Stored_object_id.to_hex
           (Retention_change_id.stored_object_id identity))
  | Checkpoint_cycle identity ->
      Printf.sprintf "checkpoint chain cycle at %s"
        (Store.Stored_object_id.to_hex
           (Checkpoint_id.stored_object_id identity))
  | Checkpoint_event_mismatch identity ->
      Printf.sprintf "checkpoint/event disagreement at %s"
        (Store.Stored_object_id.to_hex
           (Checkpoint_id.stored_object_id identity))
  | Replay_mismatch identity ->
      Printf.sprintf "scratch replay disagrees with checkpoint %s"
        (Store.Stored_object_id.to_hex
           (Checkpoint_id.stored_object_id identity))
  | Invalid_timeline_limit limit ->
      Printf.sprintf "timeline limit must be non-negative, got %d" limit
  | Restore_destination_not_directory path ->
      Printf.sprintf "restore destination is not a directory: %s" path
  | Restore_external_change { expected; actual } ->
      Printf.sprintf
        "restore plan is stale: expected current snapshot %s, got %s"
        (Store.Stored_object_id.to_hex
           (Snapshot.Snapshot.stored_object_id expected))
        (Store.Stored_object_id.to_hex
           (Snapshot.Snapshot.stored_object_id actual))
  | Restore_apply_error { safety_checkpoint; path; operation; message } ->
      Printf.sprintf "%s failed for %s: %s%s" operation path message
        (match safety_checkpoint with
        | None -> ""
        | Some checkpoint ->
            Printf.sprintf "; safety checkpoint: %s"
              (Store.Stored_object_id.to_hex
                 (Checkpoint_id.stored_object_id checkpoint)))
  | Restore_verification_mismatch { expected; actual } ->
      Printf.sprintf "restore verification failed: expected snapshot %s, got %s"
        (Store.Stored_object_id.to_hex
           (Snapshot.Snapshot.stored_object_id expected))
        (Store.Stored_object_id.to_hex
           (Snapshot.Snapshot.stored_object_id actual))

let retention_reason_to_string = function
  | User_pinned -> "user pinned"
  | Capsule_boundary identity ->
      Printf.sprintf "capsule boundary: %s"
        (Paengi_id.Capsule_id.short_hex identity)
  | Release_boundary identity ->
      Printf.sprintf "release boundary: %s"
        (Paengi_id.Release_id.short_hex identity)
  | Validation_passed identity ->
      Printf.sprintf "validation passed: %s"
        (Paengi_id.Validation_id.short_hex identity)
  | Periodic_retention -> "periodic retention"
  | Recent_window -> "recent window"
  | Conflict_reference identity ->
      Printf.sprintf "conflict reference: %s"
        (Paengi_id.Conflict_id.short_hex identity)

let ( let* ) = Result.bind

let value_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_schema (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be bytes"))

let raw_object_id value =
  let* raw = bytes "stored object ID" value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None -> Error (Invalid_object_id_length (String.length raw))

let optional_object_id value =
  match value with
  | Encoding.Null -> Ok None
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ ->
      raw_object_id value |> Result.map Option.some

let valid_component component =
  (not (String.is_empty component))
  && (not (String.equal component "."))
  && (not (String.equal component ".."))
  && (not (String.contains component '/'))
  && not (String.contains component '\000')

let valid_path = function
  | [] -> false
  | components -> List.for_all valid_component components

let path_value path = List.map Encoding.bytes path |> value_array

let decode_path value =
  let* components = array_values "path" value in
  let rec decode reversed = function
    | [] ->
        let path = List.rev reversed in
        if valid_path path then Ok path else Error (Invalid_path path)
    | value :: rest ->
        let* component = bytes "path component" value in
        decode (component :: reversed) rest
  in
  decode [] components

let mode_value = function
  | Snapshot.Regular -> Encoding.integer 0L
  | Snapshot.Executable -> Encoding.integer 1L
  | Snapshot.Symlink -> Encoding.integer 2L

let mode_of_value value =
  let* value = integer "file mode" value in
  match value with
  | 0L -> Ok Snapshot.Regular
  | 1L -> Ok Snapshot.Executable
  | 2L -> Ok Snapshot.Symlink
  | _ -> Error (Invalid_mode value)

let entry_equal left right =
  match (left, right) with
  | Directory, Directory -> true
  | File left, File right ->
      left.mode = right.mode
      && Snapshot.Content.equal_id left.content right.content
  | Directory, File _ | File _, Directory -> false

let entry_kind_equal left right =
  match (left, right) with
  | Directory, Directory -> true
  | File left, File right ->
      Bool.equal (left.mode = Snapshot.Symlink) (right.mode = Snapshot.Symlink)
  | Directory, File _ | File _, Directory -> false

let entry_value = function
  | Directory -> value_array [ Encoding.integer 0L ]
  | File { mode; content } ->
      value_array
        [
          Encoding.integer 1L;
          mode_value mode;
          Encoding.bytes
            (Store.Stored_object_id.to_raw_bytes
               (Snapshot.Content.stored_object_id content));
        ]

let decode_entry value =
  let* fields = array_values "entry" value in
  match fields with
  | [ tag ] ->
      let* tag = integer "entry tag" tag in
      if Int64.equal tag 0L then Ok Directory
      else Error (Invalid_schema "directory entry must use tag 0")
  | [ tag; mode; content ] ->
      let* tag = integer "entry tag" tag in
      if not (Int64.equal tag 1L) then
        Error (Invalid_schema "file entry must use tag 1")
      else
        let* mode = mode_of_value mode in
        let* content = raw_object_id content in
        Ok
          (File { mode; content = Snapshot.Content.of_stored_object_id content })
  | _ -> Error (Invalid_schema "entry must contain one or three values")

module Path_map = Map.Make (struct
  type t = path

  let compare = List.compare String.compare
end)

let path_parent path =
  match List.rev path with [] -> [] | _ :: rest -> List.rev rest

let rec is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | left :: left_rest, right :: right_rest ->
      String.equal left right && is_prefix left_rest right_rest

let is_proper_prefix prefix path =
  List.length prefix < List.length path && is_prefix prefix path

module State = struct
  type t = entry Path_map.t

  let entries state = Path_map.bindings state
  let find state path = Path_map.find_opt path state
  let equal left right = Path_map.equal entry_equal left right

  let ensure_parent state path =
    match path_parent path with
    | [] -> Ok ()
    | parent -> (
        match Path_map.find_opt parent state with
        | Some Directory -> Ok ()
        | Some (File _) -> Error (Parent_not_directory parent)
        | None -> Error (Missing_parent parent))

  let create entries =
    let rec add state = function
      | [] -> Ok state
      | (path, entry) :: rest ->
          if not (valid_path path) then Error (Invalid_path path)
          else if Path_map.mem path state then Error (Duplicate_path path)
          else
            let* () = ensure_parent state path in
            add (Path_map.add path entry state) rest
    in
    List.sort (fun (left, _) (right, _) -> compare_path left right) entries
    |> add Path_map.empty

  let rec collect_tree repository prefix identity =
    let* tree =
      Snapshot.Tree.load repository identity
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let rec collect reversed = function
      | [] -> Ok (List.rev reversed)
      | (name, entry) :: rest ->
          let path = prefix @ [ name ] in
          let* values =
            match entry with
            | Snapshot.Tree.File { mode; content } ->
                Ok [ (path, File { mode; content }) ]
            | Snapshot.Tree.Directory child ->
                let* children = collect_tree repository path child in
                Ok ((path, Directory) :: children)
          in
          collect (List.rev_append values reversed) rest
    in
    collect [] (Snapshot.Tree.entries tree)

  let of_snapshot repository snapshot =
    let* values =
      collect_tree repository [] (Snapshot.Snapshot.root snapshot)
    in
    create values

  let has_children state path =
    Path_map.exists (fun candidate _ -> is_proper_prefix path candidate) state

  let apply_one state = function
    | Create { path; entry } ->
        if not (valid_path path) then Error (Invalid_path path)
        else if Path_map.mem path state then Error (Path_already_exists path)
        else
          let* () = ensure_parent state path in
          Ok (Path_map.add path entry state)
    | Delete { path; prior } -> (
        match Path_map.find_opt path state with
        | None -> Error (Path_not_found path)
        | Some actual -> (
            if not (entry_equal actual prior) then
              Error (Expected_entry_mismatch path)
            else
              match actual with
              | Directory when has_children state path ->
                  Error (Nonempty_directory path)
              | Directory | File _ -> Ok (Path_map.remove path state)))
    | Modify_content { path; expected; replacement } -> (
        match Path_map.find_opt path state with
        | Some (File file) when Snapshot.Content.equal_id file.content expected
          ->
            Ok
              (Path_map.add path
                 (File { file with content = replacement })
                 state)
        | Some (File _) -> Error (Expected_content_mismatch path)
        | Some Directory | None -> Error (Path_not_found path))
    | Change_mode { path; expected; replacement } -> (
        match Path_map.find_opt path state with
        | Some (File file) when file.mode = expected ->
            Ok (Path_map.add path (File { file with mode = replacement }) state)
        | Some (File _) -> Error (Expected_mode_mismatch path)
        | Some Directory | None -> Error (Path_not_found path))
    | Move { source; destination; prior } -> (
        match Path_map.find_opt source state with
        | None -> Error (Path_not_found source)
        | Some actual ->
            if not (entry_equal actual prior) then
              Error (Expected_entry_mismatch source)
            else if actual = Directory && is_prefix source destination then
              Error (Move_into_descendant { source; destination })
            else if Path_map.mem destination state then
              Error (Path_already_exists destination)
            else
              let* () = ensure_parent state destination in
              let moved =
                Path_map.bindings state
                |> List.filter (fun (path, _) -> is_prefix source path)
              in
              let without =
                List.fold_left
                  (fun map (path, _) -> Path_map.remove path map)
                  state moved
              in
              let source_length = List.length source in
              List.fold_left
                (fun result (path, entry) ->
                  let suffix =
                    List.filteri (fun index _ -> index >= source_length) path
                  in
                  Result.map
                    (fun map -> Path_map.add (destination @ suffix) entry map)
                    result)
                (Ok without) moved)

  let apply state operations =
    List.fold_left
      (fun result operation ->
        Result.bind result (fun state -> apply_one state operation))
      (Ok state) operations

  let compare_delete (left, _) (right, _) =
    let depth = Int.compare (List.length right) (List.length left) in
    if depth <> 0 then depth else compare_path left right

  let compare_create (left, left_entry) (right, right_entry) =
    let depth = Int.compare (List.length left) (List.length right) in
    if depth <> 0 then depth
    else
      let kind =
        match (left_entry, right_entry) with
        | Directory, File _ -> -1
        | File _, Directory -> 1
        | Directory, Directory | File _, File _ -> 0
      in
      if kind <> 0 then kind else compare_path left right

  let diff ~from ~to_ =
    let deletions =
      Path_map.bindings from
      |> List.filter (fun (path, entry) ->
          match Path_map.find_opt path to_ with
          | Some candidate when entry_kind_equal entry candidate -> false
          | Some _ | None -> true)
      |> List.sort compare_delete
      |> List.map (fun (path, prior) -> Delete { path; prior })
    in
    let modifications =
      Path_map.bindings from
      |> List.filter_map (fun (path, entry) ->
          match (entry, Path_map.find_opt path to_) with
          | File left, Some (File right) ->
              if not (entry_kind_equal entry (File right)) then None
              else
                let content =
                  if Snapshot.Content.equal_id left.content right.content then
                    []
                  else
                    [
                      Modify_content
                        {
                          path;
                          expected = left.content;
                          replacement = right.content;
                        };
                    ]
                in
                let mode =
                  if left.mode = right.mode then []
                  else
                    [
                      Change_mode
                        { path; expected = left.mode; replacement = right.mode };
                    ]
                in
                Some (content @ mode)
          | Directory, Some Directory
          | File _, Some Directory
          | Directory, Some (File _)
          | _, None ->
              None)
      |> List.concat
    in
    let creations =
      Path_map.bindings to_
      |> List.filter (fun (path, entry) ->
          match Path_map.find_opt path from with
          | Some candidate when entry_kind_equal candidate entry -> false
          | Some _ | None -> true)
      |> List.sort compare_create
      |> List.map (fun (path, entry) -> Create { path; entry })
    in
    deletions @ modifications @ creations
end

type event = {
  event_id : Event_id.t;
  event_parent : Checkpoint_id.t;
  event_base : Snapshot.Snapshot.id;
  event_resulting : Snapshot.Snapshot.id;
  event_operations : operation list;
  event_source : source;
  event_observed_at : int64;
}

type checkpoint = {
  checkpoint_id : Checkpoint_id.t;
  parent : Checkpoint_id.t option;
  event : Event_id.t option;
  snapshot : Snapshot.Snapshot.id;
  created_at : int64;
  intrinsic_retention : retention_reason list;
}

type retention_action = Add | Remove

type retention_change = {
  retention_change_id : Retention_change_id.t;
  previous : Retention_change_id.t option;
  checkpoint : Checkpoint_id.t;
  action : retention_action;
  reason : retention_reason;
  changed_at : int64;
}

let source_value = function
  | Explicit -> Encoding.integer 0L
  | Scan -> Encoding.integer 1L

let source_of_value value =
  let* code = integer "observation source" value in
  match code with
  | 0L -> Ok Explicit
  | 1L -> Ok Scan
  | _ -> Error (Invalid_source code)

let retention_value = function
  | User_pinned -> value_array [ Encoding.integer 0L ]
  | Capsule_boundary identity ->
      value_array
        [
          Encoding.integer 1L;
          Encoding.bytes (Paengi_id.Capsule_id.to_bytes identity);
        ]
  | Release_boundary identity ->
      value_array
        [
          Encoding.integer 2L;
          Encoding.bytes (Paengi_id.Release_id.to_bytes identity);
        ]
  | Validation_passed identity ->
      value_array
        [
          Encoding.integer 3L;
          Encoding.bytes (Paengi_id.Validation_id.to_bytes identity);
        ]
  | Periodic_retention -> value_array [ Encoding.integer 4L ]
  | Recent_window -> value_array [ Encoding.integer 5L ]
  | Conflict_reference identity ->
      value_array
        [
          Encoding.integer 6L;
          Encoding.bytes (Paengi_id.Conflict_id.to_bytes identity);
        ]

let ensure_identity raw constructor =
  if String.length raw <> 32 then
    Error (Invalid_identity_length (String.length raw))
  else
    match constructor raw with
    | Ok identity -> Ok identity
    | Error error ->
        Error (Invalid_schema (Paengi_id.parse_error_to_string error))

let retention_of_value value =
  let* fields = array_values "retention reason" value in
  match fields with
  | [ tag ] -> (
      let* tag = integer "retention reason tag" tag in
      match tag with
      | 0L -> Ok User_pinned
      | 4L -> Ok Periodic_retention
      | 5L -> Ok Recent_window
      | _ -> Error (Invalid_retention_reason tag))
  | [ tag; raw ] -> (
      let* tag = integer "retention reason tag" tag in
      let* raw = bytes "retention identity" raw in
      match tag with
      | 1L ->
          ensure_identity raw Paengi_id.Capsule_id.of_bytes
          |> Result.map (fun value -> Capsule_boundary value)
      | 2L ->
          ensure_identity raw Paengi_id.Release_id.of_bytes
          |> Result.map (fun value -> Release_boundary value)
      | 3L ->
          ensure_identity raw Paengi_id.Validation_id.of_bytes
          |> Result.map (fun value -> Validation_passed value)
      | 6L ->
          ensure_identity raw Paengi_id.Conflict_id.of_bytes
          |> Result.map (fun value -> Conflict_reference value)
      | _ -> Error (Invalid_retention_reason tag))
  | _ -> Error (Invalid_schema "retention reason has an invalid shape")

let compare_retention left right =
  let left = retention_value left and right = retention_value right in
  match (left, right) with
  | Ok left, Ok right ->
      String.compare (Encoding.encode left) (Encoding.encode right)
  | Error _, _ | _, Error _ -> assert false

let normalise_retention reasons = List.sort_uniq compare_retention reasons

let operation_value = function
  | Create { path; entry } ->
      let* path = path_value path in
      let* entry = entry_value entry in
      value_array [ Encoding.integer 0L; path; entry ]
  | Delete { path; prior } ->
      let* path = path_value path in
      let* prior = entry_value prior in
      value_array [ Encoding.integer 1L; path; prior ]
  | Modify_content { path; expected; replacement } ->
      let* path = path_value path in
      value_array
        [
          Encoding.integer 2L;
          path;
          Encoding.bytes
            (Store.Stored_object_id.to_raw_bytes
               (Snapshot.Content.stored_object_id expected));
          Encoding.bytes
            (Store.Stored_object_id.to_raw_bytes
               (Snapshot.Content.stored_object_id replacement));
        ]
  | Change_mode { path; expected; replacement } ->
      let* path = path_value path in
      value_array
        [
          Encoding.integer 3L; path; mode_value expected; mode_value replacement;
        ]
  | Move { source; destination; prior } ->
      let* source = path_value source in
      let* destination = path_value destination in
      let* prior = entry_value prior in
      value_array [ Encoding.integer 4L; source; destination; prior ]

let operations_value operations =
  let rec encode reversed = function
    | [] -> Ok (List.rev reversed)
    | operation :: rest ->
        let* operation = operation_value operation in
        encode (operation :: reversed) rest
  in
  let* values = encode [] operations in
  value_array values

let operation_of_value value =
  let* fields = array_values "scratch operation" value in
  match fields with
  | tag :: rest -> (
      let* tag = integer "scratch operation tag" tag in
      match (tag, rest) with
      | 0L, [ path; entry ] ->
          let* path = decode_path path in
          let* entry = decode_entry entry in
          Ok (Create { path; entry })
      | 1L, [ path; prior ] ->
          let* path = decode_path path in
          let* prior = decode_entry prior in
          Ok (Delete { path; prior })
      | 2L, [ path; expected; replacement ] ->
          let* path = decode_path path in
          let* expected = raw_object_id expected in
          let* replacement = raw_object_id replacement in
          Ok
            (Modify_content
               {
                 path;
                 expected = Snapshot.Content.of_stored_object_id expected;
                 replacement = Snapshot.Content.of_stored_object_id replacement;
               })
      | 3L, [ path; expected; replacement ] ->
          let* path = decode_path path in
          let* expected = mode_of_value expected in
          let* replacement = mode_of_value replacement in
          Ok (Change_mode { path; expected; replacement })
      | 4L, [ source; destination; prior ] ->
          let* source = decode_path source in
          let* destination = decode_path destination in
          let* prior = decode_entry prior in
          Ok (Move { source; destination; prior })
      | _ -> Error (Invalid_schema "scratch operation has an invalid shape"))
  | [] -> Error (Invalid_schema "scratch operation is empty")

let operations_of_value value =
  let* values = array_values "scratch operations" value in
  let rec decode reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* operation = operation_of_value value in
        decode (operation :: reversed) rest
  in
  decode [] values

let object_envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let event_payload (event : event) =
  let* operations = operations_value event.event_operations in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes
           (Checkpoint_id.stored_object_id event.event_parent));
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes
           (Snapshot.Snapshot.stored_object_id event.event_base));
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes
           (Snapshot.Snapshot.stored_object_id event.event_resulting));
      operations;
      source_value event.event_source;
      Encoding.integer event.event_observed_at;
    ]

let event_envelope event =
  let* payload = event_payload event in
  object_envelope Envelope.Scratch_event payload

let event_id_for_fields ~parent ~base ~resulting ~operations ~source
    ~observed_at =
  let provisional : event =
    {
      event_id =
        Event_id.of_stored_object_id
          (Store.Stored_object_id.of_raw_bytes (String.make 32 '\000')
          |> Option.get);
      event_parent = parent;
      event_base = base;
      event_resulting = resulting;
      event_operations = operations;
      event_source = source;
      event_observed_at = observed_at;
    }
  in
  match event_envelope provisional with
  | Ok envelope -> Event_id.of_stored_object_id (Store.id_of_envelope envelope)
  | Error _ -> assert false

module Event = struct
  type t = event

  let create ~parent ~base ~resulting ~operations ~source ~observed_at =
    let event_id =
      event_id_for_fields ~parent ~base ~resulting ~operations ~source
        ~observed_at
    in
    {
      event_id;
      event_parent = parent;
      event_base = base;
      event_resulting = resulting;
      event_operations = operations;
      event_source = source;
      event_observed_at = observed_at;
    }

  let id event = event.event_id
  let parent (event : t) = event.event_parent
  let base (event : t) = event.event_base
  let resulting (event : t) = event.event_resulting
  let operations (event : t) = event.event_operations
  let source (event : t) = event.event_source
  let observed_at (event : t) = event.event_observed_at

  let store repository event =
    let* envelope = event_envelope event in
    let* identity =
      Store.put repository envelope
      |> Result.map_error (fun error -> Store_error error)
    in
    let identity = Event_id.of_stored_object_id identity in
    if Event_id.equal identity event.event_id then Ok identity
    else Error (Invalid_schema "scratch event identity changed during storage")

  let decode payload identity =
    let* fields = exact_array "scratch event" 7 payload in
    match fields with
    | [ version; parent; base; resulting; operations; source; observed_at ] ->
        let* version = integer "scratch event version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* parent = raw_object_id parent in
          let* base = raw_object_id base in
          let* resulting = raw_object_id resulting in
          let* operations = operations_of_value operations in
          let* source = source_of_value source in
          let* observed_at = integer "scratch event timestamp" observed_at in
          let event =
            create
              ~parent:(Checkpoint_id.of_stored_object_id parent)
              ~base:(Snapshot.Snapshot.of_stored_object_id base)
              ~resulting:(Snapshot.Snapshot.of_stored_object_id resulting)
              ~operations ~source ~observed_at
          in
          if not (Event_id.equal event.event_id identity) then
            Error Noncanonical_schema
          else
            let* expected = event_payload event in
            if String.equal (Encoding.encode expected) (Encoding.encode payload)
            then Ok event
            else Error Noncanonical_schema
    | _ -> assert false

  let load repository identity =
    let* object_ =
      Store.get repository (Event_id.stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Scratch_event then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Scratch_event;
             actual = Envelope.object_type object_;
           })
    else decode (Envelope.payload object_) identity
end

let intrinsic_value reasons =
  let rec encode reversed = function
    | [] -> Ok (List.rev reversed)
    | reason :: rest ->
        let* reason = retention_value reason in
        encode (reason :: reversed) rest
  in
  let* reasons = encode [] reasons in
  value_array reasons

let intrinsic_of_value value =
  let* values = array_values "intrinsic retention" value in
  let rec decode reversed = function
    | [] -> Ok (normalise_retention (List.rev reversed))
    | value :: rest ->
        let* reason = retention_of_value value in
        decode (reason :: reversed) rest
  in
  decode [] values

let checkpoint_payload checkpoint =
  let* retention = intrinsic_value checkpoint.intrinsic_retention in
  value_array
    [
      Encoding.integer 1L;
      (match checkpoint.parent with
      | None -> Encoding.null
      | Some identity ->
          Encoding.bytes
            (Store.Stored_object_id.to_raw_bytes
               (Checkpoint_id.stored_object_id identity)));
      (match checkpoint.event with
      | None -> Encoding.null
      | Some identity ->
          Encoding.bytes
            (Store.Stored_object_id.to_raw_bytes
               (Event_id.stored_object_id identity)));
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes
           (Snapshot.Snapshot.stored_object_id checkpoint.snapshot));
      Encoding.integer checkpoint.created_at;
      retention;
    ]

let checkpoint_envelope checkpoint =
  let* payload = checkpoint_payload checkpoint in
  object_envelope Envelope.Checkpoint payload

let checkpoint_id_for_fields ~parent ~event ~snapshot ~created_at
    ~intrinsic_retention =
  let provisional =
    {
      checkpoint_id =
        Checkpoint_id.of_stored_object_id
          (Store.Stored_object_id.of_raw_bytes (String.make 32 '\000')
          |> Option.get);
      parent;
      event;
      snapshot;
      created_at;
      intrinsic_retention;
    }
  in
  match checkpoint_envelope provisional with
  | Ok envelope ->
      Checkpoint_id.of_stored_object_id (Store.id_of_envelope envelope)
  | Error _ -> assert false

module Checkpoint = struct
  type t = checkpoint

  let make ~parent ~event ~snapshot ~created_at ~intrinsic_retention =
    let intrinsic_retention = normalise_retention intrinsic_retention in
    let checkpoint_id =
      checkpoint_id_for_fields ~parent ~event ~snapshot ~created_at
        ~intrinsic_retention
    in
    { checkpoint_id; parent; event; snapshot; created_at; intrinsic_retention }

  let create_initial ~snapshot ~created_at =
    make ~parent:None ~event:None ~snapshot ~created_at
      ~intrinsic_retention:[ Recent_window ]

  let create_initial_with_retention ~snapshot ~created_at ~intrinsic_retention =
    make ~parent:None ~event:None ~snapshot ~created_at ~intrinsic_retention

  let create ~parent ~event ~snapshot ~created_at =
    make ~parent:(Some parent) ~event:(Some event) ~snapshot ~created_at
      ~intrinsic_retention:[ Recent_window ]

  let create_with_retention ~parent ~event ~snapshot ~created_at
      ~intrinsic_retention =
    make ~parent:(Some parent) ~event:(Some event) ~snapshot ~created_at
      ~intrinsic_retention

  let id (checkpoint : t) = checkpoint.checkpoint_id
  let parent (checkpoint : t) = checkpoint.parent
  let event (checkpoint : t) = checkpoint.event
  let snapshot (checkpoint : t) = checkpoint.snapshot
  let created_at (checkpoint : t) = checkpoint.created_at
  let intrinsic_retention (checkpoint : t) = checkpoint.intrinsic_retention

  let store repository checkpoint =
    let* envelope = checkpoint_envelope checkpoint in
    let* identity =
      Store.put repository envelope
      |> Result.map_error (fun error -> Store_error error)
    in
    let identity = Checkpoint_id.of_stored_object_id identity in
    if Checkpoint_id.equal identity checkpoint.checkpoint_id then Ok identity
    else
      Error
        (Invalid_schema "scratch checkpoint identity changed during storage")

  let decode payload identity =
    let* fields = exact_array "scratch checkpoint" 6 payload in
    match fields with
    | [ version; parent; event; snapshot; created_at; retention ] ->
        let* version = integer "scratch checkpoint version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* parent = optional_object_id parent in
          let* event = optional_object_id event in
          let* snapshot = raw_object_id snapshot in
          let* created_at = integer "scratch checkpoint timestamp" created_at in
          let* intrinsic_retention = intrinsic_of_value retention in
          if Option.is_some parent <> Option.is_some event then
            Error Invalid_checkpoint_structure
          else
            let checkpoint =
              make
                ~parent:(Option.map Checkpoint_id.of_stored_object_id parent)
                ~event:(Option.map Event_id.of_stored_object_id event)
                ~snapshot:(Snapshot.Snapshot.of_stored_object_id snapshot)
                ~created_at ~intrinsic_retention
            in
            if not (Checkpoint_id.equal checkpoint.checkpoint_id identity) then
              Error Noncanonical_schema
            else
              let* expected = checkpoint_payload checkpoint in
              if
                String.equal (Encoding.encode expected)
                  (Encoding.encode payload)
              then Ok checkpoint
              else Error Noncanonical_schema
    | _ -> assert false

  let load repository identity =
    let* object_ =
      Store.get repository (Checkpoint_id.stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Checkpoint then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Checkpoint;
             actual = Envelope.object_type object_;
           })
    else decode (Envelope.payload object_) identity
end

let action_value = function
  | Add -> Encoding.integer 0L
  | Remove -> Encoding.integer 1L

let action_of_value value =
  let* code = integer "retention action" value in
  match code with
  | 0L -> Ok Add
  | 1L -> Ok Remove
  | _ -> Error (Invalid_retention_action code)

let retention_change_payload change =
  let* reason = retention_value change.reason in
  value_array
    [
      Encoding.integer 1L;
      (match change.previous with
      | None -> Encoding.null
      | Some identity ->
          Encoding.bytes
            (Store.Stored_object_id.to_raw_bytes
               (Retention_change_id.stored_object_id identity)));
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes
           (Checkpoint_id.stored_object_id change.checkpoint));
      action_value change.action;
      reason;
      Encoding.integer change.changed_at;
    ]

let retention_change_envelope change =
  let* payload = retention_change_payload change in
  object_envelope Envelope.Retention_change payload

let retention_change_id_for_fields ~previous ~checkpoint ~action ~reason
    ~changed_at =
  let provisional : retention_change =
    {
      retention_change_id =
        Retention_change_id.of_stored_object_id
          (Store.Stored_object_id.of_raw_bytes (String.make 32 '\000')
          |> Option.get);
      previous;
      checkpoint;
      action;
      reason;
      changed_at;
    }
  in
  match retention_change_envelope provisional with
  | Ok envelope ->
      Retention_change_id.of_stored_object_id (Store.id_of_envelope envelope)
  | Error _ -> assert false

module Retention_change = struct
  type action = retention_action = Add | Remove
  type t = retention_change

  let create ~previous ~checkpoint ~action ~reason ~changed_at =
    let retention_change_id =
      retention_change_id_for_fields ~previous ~checkpoint ~action ~reason
        ~changed_at
    in
    { retention_change_id; previous; checkpoint; action; reason; changed_at }

  let id change = change.retention_change_id
  let previous change = change.previous
  let checkpoint change = change.checkpoint
  let action change = change.action
  let reason change = change.reason
  let changed_at change = change.changed_at

  let store repository change =
    let* envelope = retention_change_envelope change in
    let* identity =
      Store.put repository envelope
      |> Result.map_error (fun error -> Store_error error)
    in
    let identity = Retention_change_id.of_stored_object_id identity in
    if Retention_change_id.equal identity change.retention_change_id then
      Ok identity
    else
      Error (Invalid_schema "retention change identity changed during storage")

  let decode payload identity =
    let* fields = exact_array "retention change" 6 payload in
    match fields with
    | [ version; previous; checkpoint; action; reason; changed_at ] ->
        let* version = integer "retention change version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* previous = optional_object_id previous in
          let* checkpoint = raw_object_id checkpoint in
          let* action = action_of_value action in
          let* reason = retention_of_value reason in
          let* changed_at = integer "retention change timestamp" changed_at in
          let change =
            create
              ~previous:
                (Option.map Retention_change_id.of_stored_object_id previous)
              ~checkpoint:(Checkpoint_id.of_stored_object_id checkpoint)
              ~action ~reason ~changed_at
          in
          if not (Retention_change_id.equal change.retention_change_id identity)
          then Error Noncanonical_schema
          else
            let* expected = retention_change_payload change in
            if String.equal (Encoding.encode expected) (Encoding.encode payload)
            then Ok change
            else Error Noncanonical_schema
    | _ -> assert false

  let load repository identity =
    let* object_ =
      Store.get repository (Retention_change_id.stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Retention_change then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Retention_change;
             actual = Envelope.object_type object_;
           })
    else decode (Envelope.payload object_) identity
end

module Cleanup_manifest = struct
  type candidate = {
    object_id : Store.Stored_object_id.t;
    expected_type : Envelope.object_type;
  }

  type t = { manifest_id : Cleanup_manifest_id.t; candidates : candidate list }

  let allowed_type = function
    | Envelope.Scratch_event | Envelope.Checkpoint | Envelope.Retention_change
      ->
        true
    | Envelope.Content | Envelope.Tree | Envelope.Snapshot | Envelope.Capsule
    | Envelope.Capsule_revision | Envelope.Release | Envelope.Conflict
    | Envelope.Validation | Envelope.Resolution | Envelope.Repository_config
    | Envelope.Chunk | Envelope.File_manifest
    | Envelope.Scratch_generation_segment | Envelope.Scratch_generation
    | Envelope.Scratch_cleanup_manifest ->
        false
    | Envelope.Workspace | Envelope.Workspace_revision
    | Envelope.Workspace_attempt | Envelope.Release_attestation
    | Envelope.Git_mapping | Envelope.Imported_transition ->
        false

  let compare_candidate left right =
    Store.Stored_object_id.compare left.object_id right.object_id

  let valid_candidates candidates =
    let rec loop previous = function
      | [] -> Ok ()
      | candidate :: rest -> (
          if not (allowed_type candidate.expected_type) then
            Error (Invalid_schema "cleanup manifest contains a protected type")
          else
            match previous with
            | Some previous when compare_candidate previous candidate >= 0 ->
                Error
                  (Invalid_schema
                     "cleanup manifest candidates must be strictly sorted")
            | None | Some _ -> loop (Some candidate) rest)
    in
    loop None candidates

  let candidate_value candidate =
    value_array
      [
        Encoding.bytes (Store.Stored_object_id.to_raw_bytes candidate.object_id);
        Encoding.integer
          (Int64.of_int (Envelope.object_type_code candidate.expected_type));
      ]

  let payload candidates =
    let* candidates =
      let rec encode reversed = function
        | [] -> Ok (List.rev reversed)
        | candidate :: rest ->
            let* candidate = candidate_value candidate in
            encode (candidate :: reversed) rest
      in
      encode [] candidates
    in
    let* candidates =
      Encoding.array candidates
      |> Result.map_error (fun error -> Encoding_error error)
    in
    value_array [ Encoding.integer 1L; candidates ]

  let envelope candidates =
    let* payload = payload candidates in
    object_envelope Envelope.Scratch_cleanup_manifest payload

  let identity candidates =
    match envelope candidates with
    | Ok envelope ->
        Cleanup_manifest_id.of_stored_object_id (Store.id_of_envelope envelope)
    | Error _ -> assert false

  let create candidates =
    let candidates = List.sort compare_candidate candidates in
    let* () = valid_candidates candidates in
    Ok { manifest_id = identity candidates; candidates }

  let id manifest = manifest.manifest_id
  let candidates manifest = manifest.candidates

  let store repository manifest =
    let* envelope = envelope manifest.candidates in
    let* identity =
      Store.put repository envelope
      |> Result.map_error (fun error -> Store_error error)
    in
    let identity = Cleanup_manifest_id.of_stored_object_id identity in
    if Cleanup_manifest_id.equal identity manifest.manifest_id then Ok identity
    else
      Error (Invalid_schema "cleanup manifest identity changed during storage")

  let candidate_of_value value =
    let* fields = exact_array "cleanup candidate" 2 value in
    match fields with
    | [ object_id; expected_type ] -> (
        let* object_id = raw_object_id object_id in
        let* expected_type =
          integer "cleanup candidate object type" expected_type
        in
        if
          Int64.compare expected_type 0L < 0
          || Int64.compare expected_type (Int64.of_int max_int) > 0
        then Error (Invalid_schema "cleanup candidate object type is invalid")
        else
          match Envelope.object_type_of_code (Int64.to_int expected_type) with
          | Some expected_type when allowed_type expected_type ->
              Ok { object_id; expected_type }
          | Some _ ->
              Error
                (Invalid_schema "cleanup manifest contains a protected type")
          | None ->
              Error (Invalid_schema "cleanup candidate object type is unknown"))
    | _ -> assert false

  let decode input manifest_id =
    let* fields = exact_array "scratch cleanup manifest" 2 input in
    match fields with
    | [ version; candidates ] ->
        let* version = integer "scratch cleanup manifest version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* candidates =
            array_values "cleanup manifest candidates" candidates
          in
          let rec decode reversed = function
            | [] -> Ok (List.rev reversed)
            | value :: rest ->
                let* candidate = candidate_of_value value in
                decode (candidate :: reversed) rest
          in
          let* candidates = decode [] candidates in
          let* () = valid_candidates candidates in
          let manifest = { manifest_id; candidates } in
          let* expected = payload candidates in
          if String.equal (Encoding.encode expected) (Encoding.encode input)
          then Ok manifest
          else Error Noncanonical_schema
    | _ -> assert false

  let load repository manifest_id =
    let* object_ =
      Store.get repository (Cleanup_manifest_id.stored_object_id manifest_id)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Scratch_cleanup_manifest then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Scratch_cleanup_manifest;
             actual = Envelope.object_type object_;
           })
    else decode (Envelope.payload object_) manifest_id
end

module Generation = struct
  let max_entries_per_segment = 128
  let max_segments = 128

  type entry = {
    logical : Checkpoint_id.t;
    physical : Checkpoint_id.t;
    snapshot : Snapshot.Snapshot.id;
    previous_logical : Checkpoint_id.t option;
    effective_retention : retention_reason list;
  }

  type segment = {
    segment_id : Store.Stored_object_id.t;
    segment_entries : entry list;
  }

  type t = {
    generation_id : Generation_id.t;
    previous : Generation_id.t option;
    source_scratch_head : Checkpoint_id.t;
    source_scratch_ref_generation : int64;
    source_retention_head : Retention_change_id.t option;
    source_retention_ref_generation : int64 option;
    recent_window_seconds : int64;
    periodic_interval_seconds : int64;
    storage_budget_bytes : int64 option;
    segment_ids : Generation_id.t list;
    entries : entry list;
    physical_head : Checkpoint_id.t;
    retention_cutoff : Retention_change_id.t option;
    cleanup_manifest : Cleanup_manifest_id.t;
  }

  type root_input = {
    root_previous : Generation_id.t option;
    root_source_scratch_head : Checkpoint_id.t;
    root_source_scratch_ref_generation : int64;
    root_source_retention_head : Retention_change_id.t option;
    root_source_retention_ref_generation : int64 option;
    root_recent_window_seconds : int64;
    root_periodic_interval_seconds : int64;
    root_storage_budget_bytes : int64 option;
    root_segments : Generation_id.t list;
    root_physical_head : Checkpoint_id.t;
    root_retention_cutoff : Retention_change_id.t option;
    root_cleanup_manifest : Cleanup_manifest_id.t;
  }

  let entry ~logical ~physical ~snapshot ~previous_logical ~effective_retention
      =
    {
      logical;
      physical;
      snapshot;
      previous_logical;
      effective_retention = normalise_retention effective_retention;
    }

  let logical (entry : entry) = entry.logical
  let physical (entry : entry) = entry.physical
  let snapshot (entry : entry) = entry.snapshot
  let previous_logical (entry : entry) = entry.previous_logical
  let effective_retention (entry : entry) = entry.effective_retention

  let raw_checkpoint identity =
    Encoding.bytes
      (Store.Stored_object_id.to_raw_bytes
         (Checkpoint_id.stored_object_id identity))

  let raw_snapshot identity =
    Encoding.bytes
      (Store.Stored_object_id.to_raw_bytes
         (Snapshot.Snapshot.stored_object_id identity))

  let raw_generation identity =
    Encoding.bytes
      (Store.Stored_object_id.to_raw_bytes
         (Generation_id.stored_object_id identity))

  let raw_retention identity =
    Encoding.bytes
      (Store.Stored_object_id.to_raw_bytes
         (Retention_change_id.stored_object_id identity))

  let raw_manifest identity =
    Encoding.bytes
      (Store.Stored_object_id.to_raw_bytes
         (Cleanup_manifest_id.stored_object_id identity))

  let optional encode = function
    | None -> Encoding.null
    | Some value -> encode value

  let retention_list_value reasons =
    let* values = intrinsic_value (normalise_retention reasons) in
    Ok values

  let entry_value entry =
    let* retention = retention_list_value entry.effective_retention in
    value_array
      [
        raw_checkpoint entry.logical;
        raw_checkpoint entry.physical;
        raw_snapshot entry.snapshot;
        optional raw_checkpoint entry.previous_logical;
        retention;
      ]

  let segment_payload entries =
    let rec encode reversed = function
      | [] -> Ok (List.rev reversed)
      | entry :: rest ->
          let* entry = entry_value entry in
          encode (entry :: reversed) rest
    in
    let* entries = encode [] entries in
    let* entries =
      Encoding.array entries
      |> Result.map_error (fun error -> Encoding_error error)
    in
    value_array [ Encoding.integer 1L; entries ]

  let segment_envelope entries =
    let* payload = segment_payload entries in
    object_envelope Envelope.Scratch_generation_segment payload

  let segment_identity entries =
    match segment_envelope entries with
    | Ok envelope -> Store.id_of_envelope envelope
    | Error _ -> assert false

  let entry_of_value value =
    let* fields = exact_array "scratch generation entry" 5 value in
    match fields with
    | [ logical; physical; snapshot; previous_logical; effective_retention ] ->
        let* logical = raw_object_id logical in
        let* physical = raw_object_id physical in
        let* snapshot = raw_object_id snapshot in
        let* previous_logical = optional_object_id previous_logical in
        let* effective_retention = intrinsic_of_value effective_retention in
        Ok
          (entry
             ~logical:(Checkpoint_id.of_stored_object_id logical)
             ~physical:(Checkpoint_id.of_stored_object_id physical)
             ~snapshot:(Snapshot.Snapshot.of_stored_object_id snapshot)
             ~previous_logical:
               (Option.map Checkpoint_id.of_stored_object_id previous_logical)
             ~effective_retention)
    | _ -> assert false

  let validate_entries entries =
    let rec loop previous logicals physicals = function
      | [] -> Ok ()
      | entry :: rest ->
          if List.exists (Checkpoint_id.equal entry.logical) logicals then
            Error
              (Invalid_schema "scratch generation has duplicate logical IDs")
          else if List.exists (Checkpoint_id.equal entry.physical) physicals
          then
            Error
              (Invalid_schema "scratch generation has duplicate physical IDs")
          else if
            not
              (Option.equal Checkpoint_id.equal entry.previous_logical previous)
          then
            Error
              (Invalid_schema
                 "scratch generation entries do not form a predecessor chain")
          else
            loop (Some entry.logical)
              (entry.logical :: logicals)
              (entry.physical :: physicals)
              rest
    in
    loop None [] [] entries

  let decode_segment payload identity =
    let* fields = exact_array "scratch generation segment" 2 payload in
    match fields with
    | [ version; entries ] ->
        let* version = integer "scratch generation segment version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* entries = array_values "scratch generation entries" entries in
          if entries = [] || List.length entries > max_entries_per_segment then
            Error
              (Invalid_schema "scratch generation segment has invalid length")
          else
            let rec decode reversed = function
              | [] -> Ok (List.rev reversed)
              | value :: rest ->
                  let* entry = entry_of_value value in
                  decode (entry :: reversed) rest
            in
            let* entries = decode [] entries in
            let segment : segment =
              { segment_id = identity; segment_entries = entries }
            in
            let* expected = segment_payload entries in
            if String.equal (Encoding.encode expected) (Encoding.encode payload)
            then Ok segment
            else Error Noncanonical_schema
    | _ -> assert false

  let store_segment repository entries =
    let* envelope = segment_envelope entries in
    let* identity =
      Store.put repository envelope
      |> Result.map_error (fun error -> Store_error error)
    in
    if Store.Stored_object_id.equal identity (segment_identity entries) then
      Ok identity
    else Error (Invalid_schema "scratch generation segment identity changed")

  let load_segment repository identity =
    let* object_ =
      Store.get repository identity
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Scratch_generation_segment then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Scratch_generation_segment;
             actual = Envelope.object_type object_;
           })
    else decode_segment (Envelope.payload object_) identity

  let chunks entries =
    let rec split reversed current size = function
      | [] ->
          List.rev
            (if current = [] then reversed else List.rev current :: reversed)
      | entry :: rest when size = max_entries_per_segment ->
          split (List.rev current :: reversed) [ entry ] 1 rest
      | entry :: rest -> split reversed (entry :: current) (size + 1) rest
    in
    split [] [] 0 entries

  let policy_value ~recent_window_seconds ~periodic_interval_seconds
      ~storage_budget_bytes =
    value_array
      [
        Encoding.integer recent_window_seconds;
        Encoding.integer periodic_interval_seconds;
        optional Encoding.integer storage_budget_bytes;
      ]

  let root_payload (input : root_input) =
    let* policy =
      policy_value ~recent_window_seconds:input.root_recent_window_seconds
        ~periodic_interval_seconds:input.root_periodic_interval_seconds
        ~storage_budget_bytes:input.root_storage_budget_bytes
    in
    let segments =
      List.map (fun identity -> raw_generation identity) input.root_segments
    in
    let* segments =
      Encoding.array segments
      |> Result.map_error (fun error -> Encoding_error error)
    in
    value_array
      [
        Encoding.integer 1L;
        optional raw_generation input.root_previous;
        raw_checkpoint input.root_source_scratch_head;
        Encoding.integer input.root_source_scratch_ref_generation;
        optional raw_retention input.root_source_retention_head;
        optional Encoding.integer input.root_source_retention_ref_generation;
        policy;
        segments;
        raw_checkpoint input.root_physical_head;
        optional raw_retention input.root_retention_cutoff;
        raw_manifest input.root_cleanup_manifest;
      ]

  let root_envelope arguments =
    let* payload = root_payload arguments in
    object_envelope Envelope.Scratch_generation payload

  let root_identity arguments =
    match root_envelope arguments with
    | Ok envelope ->
        Generation_id.of_stored_object_id (Store.id_of_envelope envelope)
    | Error _ -> assert false

  let nonnegative name value =
    if Int64.compare value 0L < 0 then
      Error (Invalid_schema (name ^ " is negative"))
    else Ok value

  let policy_of_value value =
    let* fields = exact_array "scratch generation policy" 3 value in
    match fields with
    | [ recent; periodic; budget ] ->
        let* recent = integer "generation recent window" recent in
        let* periodic = integer "generation periodic interval" periodic in
        let* recent = nonnegative "generation recent window" recent in
        let* periodic = nonnegative "generation periodic interval" periodic in
        let* budget =
          match budget with
          | Encoding.Null -> Ok None
          | Encoding.Integer budget ->
              let* budget = nonnegative "generation storage budget" budget in
              Ok (Some budget)
          | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
          | Encoding.Map _ | Encoding.Bool _ ->
              Error
                (Invalid_schema "generation storage budget must be an integer")
        in
        Ok (recent, periodic, budget)
    | _ -> assert false

  let raw_generation_of_value value =
    raw_object_id value |> Result.map Generation_id.of_stored_object_id

  let raw_retention_of_value value =
    raw_object_id value |> Result.map Retention_change_id.of_stored_object_id

  let raw_manifest_of_value value =
    raw_object_id value |> Result.map Cleanup_manifest_id.of_stored_object_id

  let optional_with decode = function
    | Encoding.Null -> Ok None
    | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
      | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ ) as value ->
        decode value |> Result.map Option.some

  let decode_root repository payload generation_id =
    let* fields = exact_array "scratch generation" 11 payload in
    match fields with
    | [
     version;
     previous;
     source_scratch_head;
     source_scratch_ref_generation;
     source_retention_head;
     source_retention_ref_generation;
     policy;
     segments;
     physical_head;
     retention_cutoff;
     cleanup_manifest;
    ] ->
        let* version = integer "scratch generation version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* previous = optional_with raw_generation_of_value previous in
          let* source_scratch_head = raw_object_id source_scratch_head in
          let* source_scratch_ref_generation =
            integer "source scratch ref generation"
              source_scratch_ref_generation
          in
          let* source_scratch_ref_generation =
            nonnegative "source scratch ref generation"
              source_scratch_ref_generation
          in
          let* source_retention_head =
            optional_with raw_retention_of_value source_retention_head
          in
          let* source_retention_ref_generation =
            optional_with
              (fun value ->
                let* generation =
                  integer "source retention ref generation" value
                in
                nonnegative "source retention ref generation" generation)
              source_retention_ref_generation
          in
          let* ( recent_window_seconds,
                 periodic_interval_seconds,
                 storage_budget_bytes ) =
            policy_of_value policy
          in
          let* segment_values =
            array_values "scratch generation segments" segments
          in
          if segment_values = [] || List.length segment_values > max_segments
          then
            Error
              (Invalid_schema "scratch generation has invalid segment count")
          else
            let rec decode_segments reversed = function
              | [] -> Ok (List.rev reversed)
              | value :: rest ->
                  let* identity = raw_generation_of_value value in
                  let* segment =
                    load_segment repository
                      (Generation_id.stored_object_id identity)
                  in
                  decode_segments (segment :: reversed) rest
            in
            let* segments = decode_segments [] segment_values in
            let entries =
              List.concat_map
                (fun (segment : segment) -> segment.segment_entries)
                segments
            in
            let* () = validate_entries entries in
            let* physical_head = raw_object_id physical_head in
            let* retention_cutoff =
              optional_with raw_retention_of_value retention_cutoff
            in
            let* cleanup_manifest = raw_manifest_of_value cleanup_manifest in
            let segment_ids =
              List.map
                (fun (segment : segment) ->
                  Generation_id.of_stored_object_id segment.segment_id)
                segments
            in
            let generation =
              {
                generation_id;
                previous;
                source_scratch_head =
                  Checkpoint_id.of_stored_object_id source_scratch_head;
                source_scratch_ref_generation;
                source_retention_head;
                source_retention_ref_generation;
                recent_window_seconds;
                periodic_interval_seconds;
                storage_budget_bytes;
                segment_ids;
                entries;
                physical_head = Checkpoint_id.of_stored_object_id physical_head;
                retention_cutoff;
                cleanup_manifest;
              }
            in
            let arguments : root_input =
              {
                root_previous = generation.previous;
                root_source_scratch_head = generation.source_scratch_head;
                root_source_scratch_ref_generation =
                  generation.source_scratch_ref_generation;
                root_source_retention_head = generation.source_retention_head;
                root_source_retention_ref_generation =
                  generation.source_retention_ref_generation;
                root_recent_window_seconds = generation.recent_window_seconds;
                root_periodic_interval_seconds =
                  generation.periodic_interval_seconds;
                root_storage_budget_bytes = generation.storage_budget_bytes;
                root_segments = segment_ids;
                root_physical_head = generation.physical_head;
                root_retention_cutoff = generation.retention_cutoff;
                root_cleanup_manifest = generation.cleanup_manifest;
              }
            in
            let* expected = root_payload arguments in
            if String.equal (Encoding.encode expected) (Encoding.encode payload)
            then Ok generation
            else Error Noncanonical_schema
    | _ -> assert false

  let store repository ~previous ~source_scratch_head
      ~source_scratch_ref_generation ~source_retention_head
      ~source_retention_ref_generation ~recent_window_seconds
      ~periodic_interval_seconds ~storage_budget_bytes ~entries ~physical_head
      ~retention_cutoff ~cleanup_manifest =
    let* () = validate_entries entries in
    if entries = [] then
      Error (Invalid_schema "scratch generation cannot be empty")
    else if
      not
        (Checkpoint_id.equal physical_head
           (physical (List.hd (List.rev entries))))
    then
      Error
        (Invalid_schema "scratch generation physical head is not final entry")
    else
      let segments = chunks entries in
      if List.length segments > max_segments then
        Error
          (Invalid_schema "scratch generation exceeds bounded segment count")
      else
        let rec store_segments reversed = function
          | [] -> Ok (List.rev reversed)
          | entries :: rest ->
              let* identity = store_segment repository entries in
              store_segments
                (Generation_id.of_stored_object_id identity :: reversed)
                rest
        in
        let* segments = store_segments [] segments in
        let arguments : root_input =
          {
            root_previous = previous;
            root_source_scratch_head = source_scratch_head;
            root_source_scratch_ref_generation = source_scratch_ref_generation;
            root_source_retention_head = source_retention_head;
            root_source_retention_ref_generation =
              source_retention_ref_generation;
            root_recent_window_seconds = recent_window_seconds;
            root_periodic_interval_seconds = periodic_interval_seconds;
            root_storage_budget_bytes = storage_budget_bytes;
            root_segments = segments;
            root_physical_head = physical_head;
            root_retention_cutoff = retention_cutoff;
            root_cleanup_manifest = cleanup_manifest;
          }
        in
        let* envelope = root_envelope arguments in
        let* identity =
          Store.put repository envelope
          |> Result.map_error (fun error -> Store_error error)
        in
        let identity = Generation_id.of_stored_object_id identity in
        if Generation_id.equal identity (root_identity arguments) then
          Ok identity
        else
          Error
            (Invalid_schema "scratch generation identity changed during storage")

  let load repository generation_id =
    let* object_ =
      Store.get repository (Generation_id.stored_object_id generation_id)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Scratch_generation then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Scratch_generation;
             actual = Envelope.object_type object_;
           })
    else decode_root repository (Envelope.payload object_) generation_id

  let id generation = generation.generation_id
  let previous (generation : t) = generation.previous
  let source_scratch_head (generation : t) = generation.source_scratch_head

  let source_scratch_ref_generation (generation : t) =
    generation.source_scratch_ref_generation

  let source_retention_head (generation : t) = generation.source_retention_head

  let source_retention_ref_generation generation =
    generation.source_retention_ref_generation

  let recent_window_seconds (generation : t) = generation.recent_window_seconds

  let periodic_interval_seconds (generation : t) =
    generation.periodic_interval_seconds

  let storage_budget_bytes (generation : t) = generation.storage_budget_bytes
  let segment_ids (generation : t) = generation.segment_ids
  let entries (generation : t) = generation.entries
  let physical_head (generation : t) = generation.physical_head
  let retention_cutoff (generation : t) = generation.retention_cutoff
  let cleanup_manifest (generation : t) = generation.cleanup_manifest
end

type repository = { store : Store.repository }
type checkpoint_result = Created of Checkpoint.t | Unchanged of Checkpoint.t

type resolved_checkpoint = {
  resolved_logical : Checkpoint_id.t;
  resolved_physical : Checkpoint_id.t;
  resolved_value : Checkpoint.t;
}

type timeline_entry = {
  logical_id : Checkpoint_id.t;
  checkpoint : Checkpoint.t;
  depth : int;
  effective_retention : retention_reason list;
}

let open_repository store = { store }
let scratch_head_name = "scratch-head"
let retention_head_name = "retention-head"
let scratch_generation_name = "scratch-generation"
let resolved_logical_id resolved = resolved.resolved_logical
let resolved_physical_id resolved = resolved.resolved_physical
let resolved_checkpoint resolved = resolved.resolved_value

let verify_generation_aliases repository generation =
  List.fold_left
    (fun result entry ->
      let* () = result in
      let logical = Generation.logical entry in
      let physical = Generation.physical entry in
      let* checkpoint =
        Checkpoint.load repository.store physical
        |> Result.map_error (fun error ->
            Generation_alias_target_invalid
              { logical; detail = error_to_string error })
      in
      if
        Snapshot.Snapshot.equal_id
          (Generation.snapshot entry)
          (Checkpoint.snapshot checkpoint)
      then Ok ()
      else Error (Generation_alias_snapshot_mismatch logical))
    (Ok ())
    (Generation.entries generation)

let active_generation repository =
  let* reference =
    Store.read_ref repository.store ~name:scratch_generation_name
    |> Result.map_error (fun error -> Store_error error)
  in
  match reference with
  | None -> Ok None
  | Some reference -> (
      match Store.Mutable_ref.target reference with
      | None -> Error Scratch_generation_is_null
      | Some identity ->
          let* generation =
            Generation.load repository.store
              (Generation_id.of_stored_object_id identity)
            |> Result.map_error (fun error ->
                Generation_corrupt (error_to_string error))
          in
          let* () = verify_generation_aliases repository generation in
          Ok (Some generation))

let resolve_checkpoint repository logical_id =
  let* generation = active_generation repository in
  match generation with
  | None ->
      let* checkpoint = Checkpoint.load repository.store logical_id in
      Ok
        {
          resolved_logical = logical_id;
          resolved_physical = logical_id;
          resolved_value = checkpoint;
        }
  | Some generation -> (
      match
        List.find_opt
          (fun entry ->
            Checkpoint_id.equal logical_id (Generation.logical entry))
          (Generation.entries generation)
      with
      | Some entry ->
          let physical_id = Generation.physical entry in
          let* checkpoint =
            Checkpoint.load repository.store physical_id
            |> Result.map_error (fun error ->
                Generation_alias_target_invalid
                  { logical = logical_id; detail = error_to_string error })
          in
          if
            not
              (Snapshot.Snapshot.equal_id
                 (Generation.snapshot entry)
                 (Checkpoint.snapshot checkpoint))
          then Error (Generation_alias_snapshot_mismatch logical_id)
          else
            Ok
              {
                resolved_logical = logical_id;
                resolved_physical = physical_id;
                resolved_value = checkpoint;
              }
      | None ->
          let path =
            Store.object_path repository.store
              (Checkpoint_id.stored_object_id logical_id)
          in
          if not (Sys.file_exists path) then
            Error (Checkpoint_not_retained logical_id)
          else
            let* checkpoint = Checkpoint.load repository.store logical_id in
            Ok
              {
                resolved_logical = logical_id;
                resolved_physical = logical_id;
                resolved_value = checkpoint;
              })

let read_checkpoint_ref repository =
  let* reference =
    Store.read_ref repository.store ~name:scratch_head_name
    |> Result.map_error (fun error -> Store_error error)
  in
  match reference with
  | None -> Ok None
  | Some reference -> (
      match Store.Mutable_ref.target reference with
      | None -> Error Scratch_head_is_null
      | Some identity ->
          let identity = Checkpoint_id.of_stored_object_id identity in
          let* resolved = resolve_checkpoint repository identity in
          Ok (Some (reference, resolved)))

let read_retention_ref repository =
  let* reference =
    Store.read_ref repository.store ~name:retention_head_name
    |> Result.map_error (fun error -> Store_error error)
  in
  match reference with
  | None -> Ok (None, None)
  | Some reference ->
      Ok
        ( Some reference,
          Option.map Retention_change_id.of_stored_object_id
            (Store.Mutable_ref.target reference) )

let create_initial repository ~snapshot ~created_at =
  let* _ =
    Snapshot.Snapshot.load repository.store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* existing =
    Store.read_ref repository.store ~name:scratch_head_name
    |> Result.map_error (fun error -> Store_error error)
  in
  match existing with
  | Some _ -> Error Scratch_already_initialized
  | None ->
      let checkpoint = Checkpoint.create_initial ~snapshot ~created_at in
      let* identity = Checkpoint.store repository.store checkpoint in
      let* _ =
        Store.compare_and_swap_ref repository.store ~name:scratch_head_name
          ~expected:None
          ~target:(Some (Checkpoint_id.stored_object_id identity))
        |> Result.map_error (fun error -> Store_error error)
      in
      Ok checkpoint

let head repository =
  let* value = read_checkpoint_ref repository in
  Ok (Option.map (fun (_, resolved) -> resolved.resolved_value) value)

let head_id repository =
  let* value = read_checkpoint_ref repository in
  Ok (Option.map (fun (_, resolved) -> resolved.resolved_logical) value)

let checkpoint repository ~snapshot ~source ~observed_at ~created_at =
  let* _ =
    Snapshot.Snapshot.load repository.store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* current = read_checkpoint_ref repository in
  match current with
  | None -> Error Scratch_head_missing
  | Some (reference, parent) ->
      let parent_checkpoint = parent.resolved_value in
      if
        Snapshot.Snapshot.equal_id
          (Checkpoint.snapshot parent_checkpoint)
          snapshot
      then Ok (Unchanged parent_checkpoint)
      else
        let* base =
          Snapshot.Snapshot.load repository.store
            (Checkpoint.snapshot parent_checkpoint)
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let* resulting =
          Snapshot.Snapshot.load repository.store snapshot
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let* base_state = State.of_snapshot repository.store base in
        let* resulting_state = State.of_snapshot repository.store resulting in
        let operations = State.diff ~from:base_state ~to_:resulting_state in
        let* replayed = State.apply base_state operations in
        if not (State.equal replayed resulting_state) then
          Error (Replay_mismatch parent.resolved_logical)
        else
          let event =
            Event.create ~parent:parent.resolved_logical
              ~base:(Checkpoint.snapshot parent_checkpoint)
              ~resulting:snapshot ~operations ~source ~observed_at
          in
          let* event = Event.store repository.store event in
          let checkpoint =
            Checkpoint.create ~parent:parent.resolved_logical ~event ~snapshot
              ~created_at
          in
          let* identity = Checkpoint.store repository.store checkpoint in
          let* _ =
            Store.compare_and_swap_ref repository.store ~name:scratch_head_name
              ~expected:(Some reference)
              ~target:(Some (Checkpoint_id.stored_object_id identity))
            |> Result.map_error (fun error -> Store_error error)
          in
          Ok (Created checkpoint)

let effective_retention repository ~logical_id checkpoint =
  let* generation = active_generation repository in
  let base, cutoff =
    match generation with
    | None -> (Checkpoint.intrinsic_retention checkpoint, None)
    | Some generation -> (
        match
          List.find_opt
            (fun entry ->
              Checkpoint_id.equal logical_id (Generation.logical entry))
            (Generation.entries generation)
        with
        | Some entry ->
            ( Generation.effective_retention entry,
              Generation.retention_cutoff generation )
        | None ->
            ( Checkpoint.intrinsic_retention checkpoint,
              Generation.retention_cutoff generation ))
  in
  let* _, head = read_retention_ref repository in
  let rec walk seen reversed = function
    | None -> (
        match cutoff with
        | None -> Ok reversed
        | Some _ -> Error (Generation_corrupt "retention cutoff is unreachable")
        )
    | Some identity ->
        if Option.exists (Retention_change_id.equal identity) cutoff then
          Ok reversed
        else if List.exists (Retention_change_id.equal identity) seen then
          Error (Retention_cycle identity)
        else
          let* change = Retention_change.load repository.store identity in
          walk (identity :: seen) (change :: reversed)
            (Retention_change.previous change)
  in
  let* changes = walk [] [] head in
  let reasons =
    List.fold_left
      (fun reasons change ->
        if
          not
            (Checkpoint_id.equal
               (Retention_change.checkpoint change)
               logical_id)
        then reasons
        else
          match Retention_change.action change with
          | Add -> Retention_change.reason change :: reasons
          | Remove ->
              List.filter
                (fun reason ->
                  compare_retention reason (Retention_change.reason change) <> 0)
                reasons)
      base changes
  in
  Ok (normalise_retention reasons)

let validate_child repository resolved =
  let checkpoint = resolved.resolved_value in
  match (Checkpoint.parent checkpoint, Checkpoint.event checkpoint) with
  | None, None -> Ok None
  | Some parent, Some event ->
      let* parent_resolved = resolve_checkpoint repository parent in
      let parent_checkpoint = parent_resolved.resolved_value in
      let* event = Event.load repository.store event in
      if
        (not (Checkpoint_id.equal (Event.parent event) parent))
        || (not
              (Snapshot.Snapshot.equal_id (Event.base event)
                 (Checkpoint.snapshot parent_checkpoint)))
        || not
             (Snapshot.Snapshot.equal_id (Event.resulting event)
                (Checkpoint.snapshot checkpoint))
      then Error (Checkpoint_event_mismatch resolved.resolved_logical)
      else
        let* parent_snapshot =
          Snapshot.Snapshot.load repository.store
            (Checkpoint.snapshot parent_checkpoint)
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let* child_snapshot =
          Snapshot.Snapshot.load repository.store
            (Checkpoint.snapshot checkpoint)
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let* parent_state =
          State.of_snapshot repository.store parent_snapshot
        in
        let* child_state = State.of_snapshot repository.store child_snapshot in
        let* replayed = State.apply parent_state (Event.operations event) in
        if State.equal replayed child_state then Ok (Some parent_resolved)
        else Error (Replay_mismatch resolved.resolved_logical)
  | None, Some _ | Some _, None -> Error Invalid_checkpoint_structure

let timeline repository ?start ~limit () =
  if limit < 0 then Error (Invalid_timeline_limit limit)
  else
    let* start =
      match start with
      | Some identity ->
          resolve_checkpoint repository identity |> Result.map Option.some
      | None ->
          read_checkpoint_ref repository
          |> Result.map (Option.map (fun (_, resolved) -> resolved))
    in
    let rec walk seen depth remaining reversed = function
      | _ when remaining = 0 -> Ok (List.rev reversed)
      | None -> Ok (List.rev reversed)
      | Some resolved ->
          let identity = resolved.resolved_logical in
          if List.exists (Checkpoint_id.equal identity) seen then
            Error (Checkpoint_cycle identity)
          else
            let* effective_retention =
              effective_retention repository ~logical_id:identity
                resolved.resolved_value
            in
            let entry =
              {
                logical_id = identity;
                checkpoint = resolved.resolved_value;
                depth;
                effective_retention;
              }
            in
            let* parent = validate_child repository resolved in
            walk (identity :: seen) (depth + 1) (remaining - 1)
              (entry :: reversed) parent
    in
    walk [] 0 limit [] start

let change_retention repository checkpoint ~action ~reason ~changed_at =
  let* _ = resolve_checkpoint repository checkpoint in
  let* reference, previous = read_retention_ref repository in
  let change =
    Retention_change.create ~previous ~checkpoint ~action ~reason ~changed_at
  in
  let* identity = Retention_change.store repository.store change in
  let* _ =
    Store.compare_and_swap_ref repository.store ~name:retention_head_name
      ~expected:reference
      ~target:(Some (Retention_change_id.stored_object_id identity))
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok ()

let pin repository checkpoint ~changed_at =
  change_retention repository checkpoint ~action:Add ~reason:User_pinned
    ~changed_at

let unpin repository checkpoint ~changed_at =
  change_retention repository checkpoint ~action:Remove ~reason:User_pinned
    ~changed_at

let has_capsule_boundary repository checkpoint ~capsule =
  let* entries = timeline repository ~start:checkpoint ~limit:1 () in
  match entries with
  | [ entry ] ->
      Ok
        (List.exists
           (function
             | Capsule_boundary existing ->
                 Paengi_id.Capsule_id.equal existing capsule
             | User_pinned | Release_boundary _ | Validation_passed _
             | Periodic_retention | Recent_window | Conflict_reference _ ->
                 false)
           entry.effective_retention)
  | [] -> Error (Checkpoint_not_retained checkpoint)
  | _ -> assert false

let pin_capsule_boundary repository checkpoint ~capsule ~changed_at =
  let* already_pinned = has_capsule_boundary repository checkpoint ~capsule in
  if already_pinned then Ok ()
  else
    change_retention repository checkpoint ~action:Add
      ~reason:(Capsule_boundary capsule) ~changed_at

module Polling = struct
  type t = {
    debounce_ms : int64;
    pending : (Snapshot.Snapshot.id * int64) option;
  }

  let create ~debounce_ms =
    { debounce_ms = Int64.of_int (max 0 debounce_ms); pending = None }

  let observe state ~head ~observed ~now_ms =
    if Snapshot.Snapshot.equal_id head observed then
      ({ state with pending = None }, false)
    else if Int64.equal state.debounce_ms 0L then
      ({ state with pending = None }, true)
    else
      match state.pending with
      | Some (pending, since)
        when Snapshot.Snapshot.equal_id pending observed
             && Int64.compare (Int64.sub now_ms since) state.debounce_ms >= 0 ->
          ({ state with pending = None }, true)
      | Some (pending, since) when Snapshot.Snapshot.equal_id pending observed
        ->
          ({ state with pending = Some (pending, since) }, false)
      | Some _ | None ->
          ({ state with pending = Some (observed, now_ms) }, false)
end

module Restore = struct
  type plan = {
    current_snapshot : Snapshot.Snapshot.id;
    target_checkpoint : Checkpoint_id.t;
    target_snapshot : Snapshot.Snapshot.id;
    target_state : State.t;
    actions : operation list;
    safety_checkpoint : Checkpoint_id.t option;
    expected_head : Store.Mutable_ref.t;
  }

  let current_snapshot plan = plan.current_snapshot
  let target_checkpoint plan = plan.target_checkpoint
  let safety_checkpoint plan = plan.safety_checkpoint
  let actions plan = plan.actions

  let scan root repository =
    try
      if (Unix.lstat root).Unix.st_kind <> Unix.S_DIR then
        Error (Restore_destination_not_directory root)
      else
        Snapshot.scan ~root ~store:repository.store
        |> Result.map_error (fun error -> Snapshot_error error)
    with Unix.Unix_error (error, _, _) ->
      Error
        (Restore_apply_error
           {
             safety_checkpoint = None;
             path = root;
             operation = "lstat";
             message = Unix.error_message error;
           })

  let checked_target repository target =
    let* resolved = resolve_checkpoint repository target in
    let* _ = timeline repository ~start:target ~limit:1 () in
    Ok resolved.resolved_value

  let build repository ~current_snapshot ~target_checkpoint ~safety_checkpoint
      ~require_current_head =
    let* target = checked_target repository target_checkpoint in
    let* current =
      Snapshot.Snapshot.load repository.store current_snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* target_snapshot =
      Snapshot.Snapshot.load repository.store (Checkpoint.snapshot target)
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* current_state = State.of_snapshot repository.store current in
    let* target_state = State.of_snapshot repository.store target_snapshot in
    let* current_head = read_checkpoint_ref repository in
    let expected_head =
      match current_head with
      | Some (reference, resolved) ->
          let checkpoint = resolved.resolved_value in
          let expected =
            match safety_checkpoint with
            | Some safety ->
                Checkpoint_id.equal safety resolved.resolved_logical
            | None ->
                (not require_current_head)
                || Snapshot.Snapshot.equal_id current_snapshot
                     (Checkpoint.snapshot checkpoint)
          in
          if expected then Ok reference
          else Error (Checkpoint_event_mismatch (Checkpoint.id checkpoint))
      | None -> Error Scratch_head_missing
    in
    let* expected_head = expected_head in
    Ok
      {
        current_snapshot;
        target_checkpoint;
        target_snapshot = Checkpoint.snapshot target;
        target_state;
        actions = State.diff ~from:current_state ~to_:target_state;
        safety_checkpoint;
        expected_head;
      }

  let dry_run repository ~root ~target =
    let* current_snapshot, _ = scan root repository in
    build repository ~current_snapshot ~target_checkpoint:target
      ~safety_checkpoint:None ~require_current_head:false

  let prepare repository ~root ~target ~observed_at ~created_at =
    let* current_snapshot, _ = scan root repository in
    let* current_head = head repository in
    let* safety_checkpoint =
      match current_head with
      | None -> Error Scratch_head_missing
      | Some checkpoint
        when Snapshot.Snapshot.equal_id current_snapshot
               (Checkpoint.snapshot checkpoint) ->
          Ok None
      | Some _ -> (
          let* result =
            checkpoint repository ~snapshot:current_snapshot ~source:Scan
              ~observed_at ~created_at
          in
          match result with
          | Created checkpoint -> Ok (Some (Checkpoint.id checkpoint))
          | Unchanged checkpoint -> Ok (Some (Checkpoint.id checkpoint)))
    in
    build repository ~current_snapshot ~target_checkpoint:target
      ~safety_checkpoint ~require_current_head:true

  let stage_snapshot repository ~parent ~target_snapshot ~observed_at
      ~created_at =
    let* parent = resolve_checkpoint repository parent in
    let parent_id = parent.resolved_logical in
    let parent_checkpoint = parent.resolved_value in
    if
      Snapshot.Snapshot.equal_id
        (Checkpoint.snapshot parent_checkpoint)
        target_snapshot
    then Ok parent_id
    else
      let* base =
        Snapshot.Snapshot.load repository.store
          (Checkpoint.snapshot parent_checkpoint)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let* target =
        Snapshot.Snapshot.load repository.store target_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let* base_state = State.of_snapshot repository.store base in
      let* target_state = State.of_snapshot repository.store target in
      let operations = State.diff ~from:base_state ~to_:target_state in
      let* replayed = State.apply base_state operations in
      if not (State.equal replayed target_state) then
        Error (Replay_mismatch parent_id)
      else
        let event =
          Event.create ~parent:parent_id
            ~base:(Checkpoint.snapshot parent_checkpoint)
            ~resulting:target_snapshot ~operations ~source:Explicit ~observed_at
        in
        let* event = Event.store repository.store event in
        let checkpoint =
          Checkpoint.create ~parent:parent_id ~event ~snapshot:target_snapshot
            ~created_at
        in
        Checkpoint.store repository.store checkpoint

  let prepare_snapshot repository ~root ~target_snapshot ~observed_at
      ~created_at =
    let* current_snapshot, _ = scan root repository in
    let* current_head = head repository in
    let* safety_checkpoint =
      match current_head with
      | None -> Error Scratch_head_missing
      | Some checkpoint
        when Snapshot.Snapshot.equal_id current_snapshot
               (Checkpoint.snapshot checkpoint) ->
          Ok None
      | Some _ -> (
          let* result =
            checkpoint repository ~snapshot:current_snapshot ~source:Scan
              ~observed_at ~created_at
          in
          match result with
          | Created checkpoint -> Ok (Some (Checkpoint.id checkpoint))
          | Unchanged checkpoint -> Ok (Some (Checkpoint.id checkpoint)))
    in
    let* parent = head_id repository in
    let* parent =
      match parent with
      | Some checkpoint -> Ok checkpoint
      | None -> Error Scratch_head_missing
    in
    let* target_checkpoint =
      stage_snapshot repository ~parent ~target_snapshot ~observed_at
        ~created_at
    in
    build repository ~current_snapshot ~target_checkpoint ~safety_checkpoint
      ~require_current_head:true

  let restore_error plan path operation error =
    Restore_apply_error
      {
        safety_checkpoint = plan.safety_checkpoint;
        path;
        operation;
        message = Unix.error_message error;
      }

  let checked_output_path root path =
    if not (valid_path path) then Error (Invalid_path path)
    else Ok (List.fold_left Filename.concat root path)

  let ensure_directory path plan =
    try
      if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then Ok ()
      else
        Error
          (Restore_apply_error
             {
               safety_checkpoint = plan.safety_checkpoint;
               path;
               operation = "lstat";
               message =
                 "expected directory and rejected symlink or non-directory";
             })
    with Unix.Unix_error (error, _, _) ->
      Error (restore_error plan path "lstat" error)

  let ensure_regular_file path plan =
    try
      if (Unix.lstat path).Unix.st_kind = Unix.S_REG then Ok ()
      else
        Error
          (Restore_apply_error
             {
               safety_checkpoint = plan.safety_checkpoint;
               path;
               operation = "lstat";
               message =
                 "expected regular file and rejected symlink or other node";
             })
    with Unix.Unix_error (error, _, _) ->
      Error (restore_error plan path "lstat" error)

  let ensure_parent_directories plan root path =
    let parent = path_parent path in
    let rec check prefix = function
      | [] -> Ok ()
      | component :: rest ->
          let next = prefix @ [ component ] in
          let* output = checked_output_path root next in
          let* () = ensure_directory output plan in
          check next rest
    in
    let* () = ensure_directory root plan in
    check [] parent

  let write_all descriptor path bytes plan =
    let rec write offset =
      if offset = Bytes.length bytes then Ok ()
      else
        try
          match
            Unix.write descriptor bytes offset (Bytes.length bytes - offset)
          with
          | 0 ->
              Error
                (Restore_apply_error
                   {
                     safety_checkpoint = plan.safety_checkpoint;
                     path;
                     operation = "write";
                     message = "write returned zero before completion";
                   })
          | written -> write (offset + written)
        with Unix.Unix_error (error, _, _) ->
          Error (restore_error plan path "write" error)
    in
    write 0

  let close descriptor path plan =
    try
      Unix.close descriptor;
      Ok ()
    with Unix.Unix_error (error, _, _) ->
      Error (restore_error plan path "close" error)

  let permissions = function
    | Snapshot.Executable -> 0o755
    | Snapshot.Regular -> 0o644
    | Snapshot.Symlink -> 0o777

  let write_new_regular plan path contents mode =
    try
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      let result = write_all descriptor path (Bytes.of_string contents) plan in
      let fsync_result =
        match result with
        | Error _ as error -> error
        | Ok () -> (
            try
              Unix.fsync descriptor;
              Ok ()
            with Unix.Unix_error (error, _, _) ->
              Error (restore_error plan path "fsync" error))
      in
      let close_result = close descriptor path plan in
      let* () = fsync_result in
      let* () = close_result in
      try
        Unix.chmod path (permissions mode);
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (restore_error plan path "chmod" error)
    with Unix.Unix_error (error, _, _) ->
      Error (restore_error plan path "create" error)

  let temporary_path directory basename attempt =
    Filename.concat directory
      (Printf.sprintf ".%s.paengi-restore-%d-%d" basename (Unix.getpid ())
         attempt)

  let rec write_replace_regular plan path contents mode attempt =
    if attempt = 128 then
      Error
        (Restore_apply_error
           {
             safety_checkpoint = plan.safety_checkpoint;
             path;
             operation = "create temporary";
             message = "temporary name exhaustion";
           })
    else
      let temporary =
        temporary_path (Filename.dirname path) (Filename.basename path) attempt
      in
      try
        let descriptor =
          Unix.openfile temporary
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
            0o600
        in
        let result =
          write_all descriptor temporary (Bytes.of_string contents) plan
        in
        let fsync_result =
          match result with
          | Error _ as error -> error
          | Ok () -> (
              try
                Unix.fsync descriptor;
                Ok ()
              with Unix.Unix_error (error, _, _) ->
                Error (restore_error plan temporary "fsync" error))
        in
        let close_result = close descriptor temporary plan in
        let result =
          let* () = fsync_result in
          let* () = close_result in
          try
            Unix.chmod temporary (permissions mode);
            Unix.rename temporary path;
            Ok ()
          with Unix.Unix_error (error, _, _) ->
            Error (restore_error plan path "rename" error)
        in
        match result with
        | Ok () -> Ok ()
        | Error error ->
            (try Unix.unlink temporary with Unix.Unix_error _ -> ());
            Error error
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) ->
          write_replace_regular plan path contents mode (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (restore_error plan temporary "create" error)

  let create_or_replace_symlink plan path target replace =
    if String.contains target '\000' then
      Error
        (Restore_apply_error
           {
             safety_checkpoint = plan.safety_checkpoint;
             path;
             operation = "symlink";
             message = "symlink target contains NUL";
           })
    else if not replace then
      try
        Unix.symlink target path;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (restore_error plan path "symlink" error)
    else
      let temporary =
        temporary_path (Filename.dirname path) (Filename.basename path) 0
      in
      try
        Unix.symlink target temporary;
        Unix.rename temporary path;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        (try Unix.unlink temporary with Unix.Unix_error _ -> ());
        Error (restore_error plan path "symlink" error)

  let write_file_entry repository plan root path ~replace mode content =
    let* () = ensure_parent_directories plan root path in
    let* output = checked_output_path root path in
    let* contents =
      Snapshot.Content.load repository.store content
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    match mode with
    | Snapshot.Symlink -> create_or_replace_symlink plan output contents replace
    | Snapshot.Regular | Snapshot.Executable ->
        if replace then write_replace_regular plan output contents mode 0
        else write_new_regular plan output contents mode

  let delete_entry plan root path entry =
    let* () = ensure_parent_directories plan root path in
    let* output = checked_output_path root path in
    try
      match entry with
      | Directory ->
          Unix.rmdir output;
          Ok ()
      | File _ ->
          Unix.unlink output;
          Ok ()
    with Unix.Unix_error (error, _, _) ->
      Error (restore_error plan output "delete" error)

  let create_entry repository plan root path = function
    | Directory -> (
        let* () = ensure_parent_directories plan root path in
        let* output = checked_output_path root path in
        try
          Unix.mkdir output 0o700;
          Ok ()
        with Unix.Unix_error (error, _, _) ->
          Error (restore_error plan output "mkdir" error))
    | File { mode; content } ->
        write_file_entry repository plan root path ~replace:false mode content

  let apply_action repository plan root = function
    | Create { path; entry } -> create_entry repository plan root path entry
    | Delete { path; prior } -> delete_entry plan root path prior
    | Modify_content { path; expected = _; replacement = _ } -> (
        match State.find plan.target_state path with
        | Some (File { mode; content }) ->
            write_file_entry repository plan root path ~replace:true mode
              content
        | Some Directory | None -> Error (Expected_entry_mismatch path))
    | Change_mode { path; expected = _; replacement } -> (
        let* () = ensure_parent_directories plan root path in
        let* output = checked_output_path root path in
        let* () = ensure_regular_file output plan in
        try
          Unix.chmod output (permissions replacement);
          Ok ()
        with Unix.Unix_error (error, _, _) ->
          Error (restore_error plan output "chmod" error))
    | Move { source; destination; prior = _ } -> (
        let* () = ensure_parent_directories plan root source in
        let* () = ensure_parent_directories plan root destination in
        let* source = checked_output_path root source in
        let* destination = checked_output_path root destination in
        try
          Unix.rename source destination;
          Ok ()
        with Unix.Unix_error (error, _, _) ->
          Error (restore_error plan source "rename" error))

  let apply repository ~root plan =
    let* actual_snapshot, actual = scan root repository in
    if not (Snapshot.Snapshot.equal_id actual_snapshot plan.current_snapshot)
    then
      Error
        (Restore_external_change
           { expected = plan.current_snapshot; actual = actual_snapshot })
    else
      let* actual_state = State.of_snapshot repository.store actual in
      let* replayed = State.apply actual_state plan.actions in
      if not (State.equal replayed plan.target_state) then
        Error (Replay_mismatch plan.target_checkpoint)
      else
        let* () =
          List.fold_left
            (fun result action ->
              Result.bind result (fun () ->
                  apply_action repository plan root action))
            (Ok ()) plan.actions
        in
        let* verified_snapshot, _ = scan root repository in
        if
          not
            (Snapshot.Snapshot.equal_id verified_snapshot plan.target_snapshot)
        then
          Error
            (Restore_verification_mismatch
               { expected = plan.target_snapshot; actual = verified_snapshot })
        else
          Store.compare_and_swap_ref repository.store ~name:scratch_head_name
            ~expected:(Some plan.expected_head)
            ~target:
              (Some (Checkpoint_id.stored_object_id plan.target_checkpoint))
          |> Result.map_error (fun error -> Store_error error)
          |> Result.map (fun _ -> ())

  let restore repository ~root ~target ~observed_at ~created_at =
    let* plan = prepare repository ~root ~target ~observed_at ~created_at in
    let* () = apply repository ~root plan in
    Ok plan.safety_checkpoint
end
