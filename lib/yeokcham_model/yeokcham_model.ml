module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id

module Path = struct
  type t = string list

  type error =
    | Empty_path
    | Empty_component of int
    | Dot_component of int
    | Dot_dot_component of int
    | Separator_in_component of int
    | Nul_in_component of int

  let error_to_string = function
    | Empty_path -> "path has no components"
    | Empty_component index -> Printf.sprintf "path component %d is empty" index
    | Dot_component index -> Printf.sprintf "path component %d is ." index
    | Dot_dot_component index -> Printf.sprintf "path component %d is .." index
    | Separator_in_component index ->
        Printf.sprintf "path component %d contains /" index
    | Nul_in_component index ->
        Printf.sprintf "path component %d contains NUL" index

  let validate_component index component =
    if String.is_empty component then Error (Empty_component index)
    else if String.equal component "." then Error (Dot_component index)
    else if String.equal component ".." then Error (Dot_dot_component index)
    else if String.contains component '/' then
      Error (Separator_in_component index)
    else if String.contains component '\000' then Error (Nul_in_component index)
    else Ok component

  let of_components components =
    match components with
    | [] -> Error Empty_path
    | _ ->
        let rec validate index = function
          | [] -> Ok components
          | component :: rest -> (
              match validate_component index component with
              | Error error -> Error error
              | Ok _ -> validate (index + 1) rest)
        in
        validate 0 components

  let to_components path = path
  let compare = List.compare String.compare
  let equal left right = compare left right = 0
  let to_string path = String.concat "/" path
end

type file_mode = Regular | Executable | Symlink
type file_entry = { mode : file_mode; content : string }

module Component_map = Map.Make (String)

type tree = tree_entry Component_map.t
and tree_entry = File of file_entry | Directory of tree

type initial_entry =
  | Directory_path of Path.t
  | File_path of Path.t * file_entry

type construction_error =
  | Duplicate_initial_path of Path.t
  | Missing_initial_parent of Path.t
  | Initial_parent_is_file of Path.t

let construction_error_to_string = function
  | Duplicate_initial_path path ->
      Printf.sprintf "duplicate initial path: %s" (Path.to_string path)
  | Missing_initial_parent path ->
      Printf.sprintf "initial parent does not exist: %s" (Path.to_string path)
  | Initial_parent_is_file path ->
      Printf.sprintf "initial parent is a file: %s" (Path.to_string path)

type scratch_operation =
  | Create_file of { path : Path.t; content : string; mode : file_mode }
  | Create_directory of { path : Path.t }
  | Modify_file of {
      path : Path.t;
      expected_content : string;
      replacement_content : string;
    }
  | Delete_path of { path : Path.t; prior : tree_entry }
  | Move_path of { source : Path.t; destination : Path.t; prior : tree_entry }
  | Change_mode of {
      path : Path.t;
      expected_mode : file_mode;
      replacement_mode : file_mode;
    }

type transition_error =
  | Path_not_found of Path.t
  | Path_already_exists of Path.t
  | Parent_not_found of Path.t
  | Parent_is_file of Path.t
  | Expected_entry_mismatch of Path.t
  | Expected_content_mismatch of Path.t
  | Expected_mode_mismatch of Path.t
  | Move_into_descendant of { source : Path.t; destination : Path.t }

let transition_error_to_string = function
  | Path_not_found path ->
      Printf.sprintf "path not found: %s" (Path.to_string path)
  | Path_already_exists path ->
      Printf.sprintf "path already exists: %s" (Path.to_string path)
  | Parent_not_found path ->
      Printf.sprintf "parent not found: %s" (Path.to_string path)
  | Parent_is_file path ->
      Printf.sprintf "parent is a file: %s" (Path.to_string path)
  | Expected_entry_mismatch path ->
      Printf.sprintf "entry precondition failed: %s" (Path.to_string path)
  | Expected_content_mismatch path ->
      Printf.sprintf "content precondition failed: %s" (Path.to_string path)
  | Expected_mode_mismatch path ->
      Printf.sprintf "mode precondition failed: %s" (Path.to_string path)
  | Move_into_descendant { source; destination } ->
      Printf.sprintf "cannot move %s into %s" (Path.to_string source)
        (Path.to_string destination)

type replay_error = { operation_index : int; cause : transition_error }

let replay_error_to_string { operation_index; cause } =
  Printf.sprintf "operation %d: %s" operation_index
    (transition_error_to_string cause)

type canonical_decode_error =
  | Canonical_payload_error of Encoding.decode_error
  | Unsupported_canonical_version of int64
  | Invalid_canonical_shape of string
  | Invalid_canonical_path of Path.error
  | Invalid_canonical_mode of int64
  | Invalid_canonical_identity_length of int
  | Invalid_canonical_identity of Id.parse_error
  | Invalid_canonical_snapshot of construction_error
  | Canonical_snapshot_reference_mismatch
  | Noncanonical_canonical_bytes

let canonical_decode_error_to_string = function
  | Canonical_payload_error error -> Encoding.decode_error_to_string error
  | Unsupported_canonical_version version ->
      Printf.sprintf "unsupported canonical model version: %Ld" version
  | Invalid_canonical_shape message ->
      Printf.sprintf "invalid canonical model shape: %s" message
  | Invalid_canonical_path error ->
      Printf.sprintf "invalid canonical model path: %s"
        (Path.error_to_string error)
  | Invalid_canonical_mode mode ->
      Printf.sprintf "invalid canonical file mode: %Ld" mode
  | Invalid_canonical_identity_length length ->
      Printf.sprintf "invalid canonical identity length: %d" length
  | Invalid_canonical_identity error ->
      Printf.sprintf "invalid canonical identity: %s"
        (Id.parse_error_to_string error)
  | Invalid_canonical_snapshot error ->
      Printf.sprintf "invalid canonical snapshot: %s"
        (construction_error_to_string error)
  | Canonical_snapshot_reference_mismatch ->
      "canonical checkpoint snapshot reference does not match supplied snapshot"
  | Noncanonical_canonical_bytes -> "canonical model bytes are not normalized"

let canonical_value bytes =
  match Encoding.decode bytes with
  | Ok value -> Ok value
  | Error error -> Error (Canonical_payload_error error)

let canonical_array name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_canonical_shape (name ^ " must be an array"))

let canonical_exact_array name length value =
  match canonical_array name value with
  | Error error -> Error error
  | Ok values ->
      if List.length values = length then Ok values
      else
        Error
          (Invalid_canonical_shape
             (Printf.sprintf "%s must contain %d values" name length))

let canonical_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_canonical_shape (name ^ " must be an integer"))

let canonical_bytes_value name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_canonical_shape (name ^ " must be bytes"))

let canonical_path value =
  match canonical_array "path" value with
  | Error error -> Error error
  | Ok values ->
      let rec components reversed = function
        | [] ->
            Path.of_components (List.rev reversed)
            |> Result.map_error (fun error -> Invalid_canonical_path error)
        | value :: rest -> (
            match canonical_bytes_value "path component" value with
            | Error error -> Error error
            | Ok component -> components (component :: reversed) rest)
      in
      components [] values

let canonical_mode value =
  match canonical_integer "file mode" value with
  | Error error -> Error error
  | Ok 0L -> Ok Regular
  | Ok 1L -> Ok Executable
  | Ok 2L -> Ok Symlink
  | Ok mode -> Error (Invalid_canonical_mode mode)

let canonical_identity value of_bytes =
  match canonical_bytes_value "identity" value with
  | Error error -> Error error
  | Ok bytes ->
      if String.length bytes <> 32 then
        Error (Invalid_canonical_identity_length (String.length bytes))
      else
        of_bytes bytes
        |> Result.map_error (fun error -> Invalid_canonical_identity error)

type observation_source = Explicit | Scan

type retention_reason =
  | User_pinned
  | Capsule_boundary of Id.Capsule_id.t
  | Release_boundary of Id.Release_id.t
  | Validation_passed of Id.Validation_id.t
  | Periodic_retention
  | Recent_window
  | Conflict_reference of Id.Conflict_id.t

let retention_reason_to_string = function
  | User_pinned -> "user pinned"
  | Capsule_boundary identity ->
      Printf.sprintf "capsule boundary: %s" (Id.Capsule_id.short_hex identity)
  | Release_boundary identity ->
      Printf.sprintf "release boundary: %s" (Id.Release_id.short_hex identity)
  | Validation_passed identity ->
      Printf.sprintf "validation passed: %s"
        (Id.Validation_id.short_hex identity)
  | Periodic_retention -> "periodic retention"
  | Recent_window -> "recent window"
  | Conflict_reference identity ->
      Printf.sprintf "conflict reference: %s"
        (Id.Conflict_id.short_hex identity)

let rec entry_equal left right =
  match (left, right) with
  | File left, File right ->
      left.mode = right.mode && String.equal left.content right.content
  | Directory left, Directory right ->
      Component_map.equal entry_equal left right
  | File _, Directory _ | Directory _, File _ -> false

let initial_entry_path = function
  | Directory_path path -> path
  | File_path (path, _) -> path

let path_parent path =
  match List.rev (Path.to_components path) with
  | [] -> assert false
  | _ :: reversed_parent -> List.rev reversed_parent

let path_from_components components =
  match Path.of_components components with
  | Ok path -> path
  | Error _ -> assert false

let path_parent_value path = path_from_components (path_parent path)

let rec find_entry tree components =
  match components with
  | [] -> None
  | [ name ] -> Component_map.find_opt name tree
  | name :: rest -> (
      match Component_map.find_opt name tree with
      | Some (Directory child) -> find_entry child rest
      | Some (File _) | None -> None)

let rec insert_entry tree components entry path =
  match components with
  | [] -> assert false
  | [ name ] ->
      if Component_map.mem name tree then Error (Path_already_exists path)
      else Ok (Component_map.add name entry tree)
  | name :: rest -> (
      match Component_map.find_opt name tree with
      | None -> Error (Parent_not_found (path_parent_value path))
      | Some (File _) -> Error (Parent_is_file (path_parent_value path))
      | Some (Directory child) -> (
          match insert_entry child rest entry path with
          | Error error -> Error error
          | Ok child -> Ok (Component_map.add name (Directory child) tree)))

let rec replace_entry tree components replacement path =
  match components with
  | [] -> assert false
  | [ name ] ->
      if Component_map.mem name tree then
        Ok (Component_map.add name replacement tree)
      else Error (Path_not_found path)
  | name :: rest -> (
      match Component_map.find_opt name tree with
      | None -> Error (Path_not_found path)
      | Some (File _) -> Error (Path_not_found path)
      | Some (Directory child) -> (
          match replace_entry child rest replacement path with
          | Error error -> Error error
          | Ok child -> Ok (Component_map.add name (Directory child) tree)))

let rec remove_entry tree components path =
  match components with
  | [] -> assert false
  | [ name ] ->
      if Component_map.mem name tree then Ok (Component_map.remove name tree)
      else Error (Path_not_found path)
  | name :: rest -> (
      match Component_map.find_opt name tree with
      | None | Some (File _) -> Error (Path_not_found path)
      | Some (Directory child) -> (
          match remove_entry child rest path with
          | Error error -> Error error
          | Ok child -> Ok (Component_map.add name (Directory child) tree)))

let rec path_is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | prefix_component :: prefix_rest, path_component :: path_rest ->
      String.equal prefix_component path_component
      && path_is_prefix prefix_rest path_rest

module Snapshot = struct
  type t = tree

  let empty = Component_map.empty

  let compare_initial_entry left right =
    let left_path = initial_entry_path left in
    let right_path = initial_entry_path right in
    let by_depth =
      Int.compare
        (List.length (Path.to_components left_path))
        (List.length (Path.to_components right_path))
    in
    if by_depth <> 0 then by_depth else Path.compare left_path right_path

  let ensure_unique_paths entries =
    let paths = List.map initial_entry_path entries |> List.sort Path.compare in
    let rec find_duplicate = function
      | left :: right :: _ when Path.equal left right -> Some left
      | _ :: rest -> find_duplicate rest
      | [] -> None
    in
    match find_duplicate paths with
    | Some path -> Error (Duplicate_initial_path path)
    | None -> Ok ()

  let construction_error_of_transition = function
    | Parent_not_found path -> Missing_initial_parent path
    | Parent_is_file path -> Initial_parent_is_file path
    | Path_already_exists path -> Duplicate_initial_path path
    | Path_not_found _ | Expected_entry_mismatch _ | Expected_content_mismatch _
    | Expected_mode_mismatch _ | Move_into_descendant _ ->
        assert false

  let add_initial tree = function
    | Directory_path path ->
        insert_entry tree (Path.to_components path)
          (Directory Component_map.empty) path
    | File_path (path, file) ->
        insert_entry tree (Path.to_components path) (File file) path

  let of_entries entries =
    match ensure_unique_paths entries with
    | Error error -> Error error
    | Ok () ->
        let rec add tree = function
          | [] -> Ok tree
          | entry :: rest -> (
              match add_initial tree entry with
              | Error error -> Error (construction_error_of_transition error)
              | Ok tree -> add tree rest)
        in
        List.sort compare_initial_entry entries |> add empty

  let rec collect_entries prefix tree =
    Component_map.bindings tree
    |> List.concat_map (fun (name, entry) ->
        let path = path_from_components (prefix @ [ name ]) in
        match entry with
        | File file -> [ File_path (path, file) ]
        | Directory child ->
            Directory_path path :: collect_entries (prefix @ [ name ]) child)

  let entries snapshot =
    collect_entries [] snapshot
    |> List.sort (fun left right ->
        Path.compare (initial_entry_path left) (initial_entry_path right))

  let find snapshot path = find_entry snapshot (Path.to_components path)
  let equal left right = Component_map.equal entry_equal left right
  let mode_code = function Regular -> 0L | Executable -> 1L | Symlink -> 2L

  let value_array values =
    match Encoding.array values with
    | Ok value -> value
    | Error _ -> assert false

  let path_value path =
    Path.to_components path |> List.map Encoding.bytes |> value_array

  let initial_entry_value = function
    | Directory_path path ->
        value_array [ Encoding.integer 0L; path_value path ]
    | File_path (path, { mode; content }) ->
        value_array
          [
            Encoding.integer 1L;
            path_value path;
            Encoding.integer (mode_code mode);
            Encoding.bytes content;
          ]

  let canonical_bytes snapshot =
    let entry_values = entries snapshot |> List.map initial_entry_value in
    value_array [ Encoding.integer 1L; value_array entry_values ]
    |> Encoding.encode

  let decode_entry value =
    match canonical_array "snapshot entry" value with
    | Error error -> Error error
    | Ok (tag :: fields) -> (
        match canonical_integer "snapshot entry tag" tag with
        | Error error -> Error error
        | Ok 0L -> (
            match fields with
            | [ path ] ->
                canonical_path path
                |> Result.map (fun path -> Directory_path path)
            | _ ->
                Error
                  (Invalid_canonical_shape
                     "directory snapshot entry must contain two values"))
        | Ok 1L -> (
            match fields with
            | [ path; mode; content ] -> (
                match
                  ( canonical_path path,
                    canonical_mode mode,
                    canonical_bytes_value "file content" content )
                with
                | Ok path, Ok mode, Ok content ->
                    Ok (File_path (path, { mode; content }))
                | Error error, _, _ | _, Error error, _ | _, _, Error error ->
                    Error error)
            | _ ->
                Error
                  (Invalid_canonical_shape
                     "file snapshot entry must contain four values"))
        | Ok tag ->
            Error
              (Invalid_canonical_shape
                 (Printf.sprintf "unknown snapshot entry tag: %Ld" tag)))
    | Ok [] -> Error (Invalid_canonical_shape "snapshot entry is empty")

  let decode_entries_value value =
    match canonical_array "snapshot entries" value with
    | Error error -> Error error
    | Ok values ->
        let rec decode reversed = function
          | [] ->
              of_entries (List.rev reversed)
              |> Result.map_error (fun error ->
                  Invalid_canonical_snapshot error)
          | value :: rest -> (
              match decode_entry value with
              | Error error -> Error error
              | Ok entry -> decode (entry :: reversed) rest)
        in
        decode [] values

  let decode_canonical_bytes bytes =
    match canonical_value bytes with
    | Error error -> Error error
    | Ok value -> (
        match canonical_exact_array "snapshot" 2 value with
        | Error error -> Error error
        | Ok [ version; entries ] -> (
            match canonical_integer "snapshot version" version with
            | Error error -> Error error
            | Ok 1L -> (
                match decode_entries_value entries with
                | Error error -> Error error
                | Ok snapshot ->
                    if String.equal bytes (canonical_bytes snapshot) then
                      Ok snapshot
                    else Error Noncanonical_canonical_bytes)
            | Ok version -> Error (Unsupported_canonical_version version))
        | Ok _ -> assert false)

  let id snapshot =
    let digest =
      Hash.feed_string Hash.empty "yeokcham:snapshot:v1\000" |> fun context ->
      Hash.feed_string context (canonical_bytes snapshot)
      |> Hash.get |> Hash.to_raw_string
    in
    match Id.Snapshot_id.of_bytes digest with
    | Ok identity -> identity
    | Error _ -> assert false

  let apply_operation snapshot = function
    | Create_file { path; content; mode } ->
        insert_entry snapshot (Path.to_components path)
          (File { mode; content })
          path
    | Create_directory { path } ->
        insert_entry snapshot (Path.to_components path)
          (Directory Component_map.empty) path
    | Modify_file { path; expected_content; replacement_content } -> (
        match find snapshot path with
        | None -> Error (Path_not_found path)
        | Some (Directory _) -> Error (Expected_content_mismatch path)
        | Some (File file) ->
            if not (String.equal file.content expected_content) then
              Error (Expected_content_mismatch path)
            else
              replace_entry snapshot (Path.to_components path)
                (File { file with content = replacement_content })
                path)
    | Delete_path { path; prior } -> (
        match find snapshot path with
        | None -> Error (Path_not_found path)
        | Some entry ->
            if not (entry_equal entry prior) then
              Error (Expected_entry_mismatch path)
            else remove_entry snapshot (Path.to_components path) path)
    | Move_path { source; destination; prior } -> (
        if
          path_is_prefix
            (Path.to_components source)
            (Path.to_components destination)
        then Error (Move_into_descendant { source; destination })
        else
          match find snapshot source with
          | None -> Error (Path_not_found source)
          | Some entry -> (
              if not (entry_equal entry prior) then
                Error (Expected_entry_mismatch source)
              else
                match
                  remove_entry snapshot (Path.to_components source) source
                with
                | Error error -> Error error
                | Ok without_source ->
                    insert_entry without_source
                      (Path.to_components destination)
                      entry destination))
    | Change_mode { path; expected_mode; replacement_mode } -> (
        match find snapshot path with
        | None -> Error (Path_not_found path)
        | Some (Directory _) -> Error (Expected_mode_mismatch path)
        | Some (File file) ->
            if file.mode <> expected_mode then
              Error (Expected_mode_mismatch path)
            else
              replace_entry snapshot (Path.to_components path)
                (File { file with mode = replacement_mode })
                path)

  let apply_operations snapshot operations =
    let rec apply index snapshot = function
      | [] -> Ok snapshot
      | operation :: rest -> (
          match apply_operation snapshot operation with
          | Error cause -> Error { operation_index = index; cause }
          | Ok snapshot -> apply (index + 1) snapshot rest)
    in
    apply 0 snapshot operations
end

type scratch_event = {
  event_id : Id.Operation_id.t;
  event_parent : Id.Checkpoint_id.t;
  operations : scratch_operation list;
  observed_at : int64;
  source : observation_source;
}

type checkpoint = {
  checkpoint_id : Id.Checkpoint_id.t;
  checkpoint_parent : Id.Checkpoint_id.t option;
  checkpoint_snapshot : Snapshot.t;
  applied_event : Id.Operation_id.t option;
  checkpoint_created_at : int64;
  checkpoint_retention : retention_reason list;
}

type event_transition_error =
  | Event_parent_mismatch of {
      expected_parent : Id.Checkpoint_id.t;
      actual_parent : Id.Checkpoint_id.t;
    }
  | Event_operation_rejected of replay_error

let event_transition_error_to_string = function
  | Event_parent_mismatch { expected_parent; actual_parent } ->
      Printf.sprintf "event parent mismatch: expected %s, got %s"
        (Id.Checkpoint_id.short_hex expected_parent)
        (Id.Checkpoint_id.short_hex actual_parent)
  | Event_operation_rejected error ->
      Printf.sprintf "event operation rejected: %s"
        (replay_error_to_string error)

let value_array values =
  match Encoding.array values with Ok value -> value | Error _ -> assert false

let mode_value = function
  | Regular -> Encoding.integer 0L
  | Executable -> Encoding.integer 1L
  | Symlink -> Encoding.integer 2L

let path_value path =
  Path.to_components path |> List.map Encoding.bytes |> value_array

let rec tree_records prefix tree =
  Component_map.bindings tree
  |> List.concat_map (fun (name, entry) ->
      let path = prefix @ [ name ] in
      match entry with
      | File { mode; content } ->
          [
            value_array
              [
                Encoding.integer 1L;
                path |> List.map Encoding.bytes |> value_array;
                mode_value mode;
                Encoding.bytes content;
              ];
          ]
      | Directory child ->
          value_array
            [
              Encoding.integer 0L;
              path |> List.map Encoding.bytes |> value_array;
            ]
          :: tree_records path child)

let prior_entry_value = function
  | File { mode; content } ->
      value_array
        [ Encoding.integer 0L; mode_value mode; Encoding.bytes content ]
  | Directory tree ->
      value_array [ Encoding.integer 1L; value_array (tree_records [] tree) ]

let scratch_operation_value = function
  | Create_file { path; content; mode } ->
      value_array
        [
          Encoding.integer 0L;
          path_value path;
          Encoding.bytes content;
          mode_value mode;
        ]
  | Create_directory { path } ->
      value_array [ Encoding.integer 5L; path_value path ]
  | Modify_file { path; expected_content; replacement_content } ->
      value_array
        [
          Encoding.integer 1L;
          path_value path;
          Encoding.bytes expected_content;
          Encoding.bytes replacement_content;
        ]
  | Delete_path { path; prior } ->
      value_array
        [ Encoding.integer 2L; path_value path; prior_entry_value prior ]
  | Move_path { source; destination; prior } ->
      value_array
        [
          Encoding.integer 3L;
          path_value source;
          path_value destination;
          prior_entry_value prior;
        ]
  | Change_mode { path; expected_mode; replacement_mode } ->
      value_array
        [
          Encoding.integer 4L;
          path_value path;
          mode_value expected_mode;
          mode_value replacement_mode;
        ]

let source_value = function Explicit -> 0L | Scan -> 1L

let event_canonical_bytes ~parent ~operations ~observed_at ~source =
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Checkpoint_id.to_bytes parent);
      value_array (List.map scratch_operation_value operations);
      Encoding.integer observed_at;
      Encoding.integer (source_value source);
    ]
  |> Encoding.encode

let operation_id bytes =
  let digest = Hash.digest_string bytes |> Hash.to_raw_string in
  match Id.Operation_id.of_bytes digest with
  | Ok identity -> identity
  | Error _ -> assert false

let retention_value = function
  | User_pinned -> value_array [ Encoding.integer 0L ]
  | Capsule_boundary identity ->
      value_array
        [
          Encoding.integer 1L; Encoding.bytes (Id.Capsule_id.to_bytes identity);
        ]
  | Release_boundary identity ->
      value_array
        [
          Encoding.integer 2L; Encoding.bytes (Id.Release_id.to_bytes identity);
        ]
  | Validation_passed identity ->
      value_array
        [
          Encoding.integer 3L;
          Encoding.bytes (Id.Validation_id.to_bytes identity);
        ]
  | Periodic_retention -> value_array [ Encoding.integer 4L ]
  | Recent_window -> value_array [ Encoding.integer 5L ]
  | Conflict_reference identity ->
      value_array
        [
          Encoding.integer 6L; Encoding.bytes (Id.Conflict_id.to_bytes identity);
        ]

let retention_rank = function
  | User_pinned -> 0
  | Capsule_boundary _ -> 1
  | Release_boundary _ -> 2
  | Validation_passed _ -> 3
  | Periodic_retention -> 4
  | Recent_window -> 5
  | Conflict_reference _ -> 6

let compare_retention_reason left right =
  let by_rank = Int.compare (retention_rank left) (retention_rank right) in
  if by_rank <> 0 then by_rank
  else
    String.compare
      (Encoding.encode (retention_value left))
      (Encoding.encode (retention_value right))

let normalise_retention retention =
  List.sort_uniq compare_retention_reason retention

let checkpoint_canonical_bytes ~parent ~snapshot ~event ~created_at ~retention =
  value_array
    [
      Encoding.integer 1L;
      (match parent with
      | None -> Encoding.null
      | Some identity -> Encoding.bytes (Id.Checkpoint_id.to_bytes identity));
      Encoding.bytes (Id.Snapshot_id.to_bytes (Snapshot.id snapshot));
      (match event with
      | None -> Encoding.null
      | Some identity -> Encoding.bytes (Id.Operation_id.to_bytes identity));
      Encoding.integer created_at;
      value_array (List.map retention_value retention);
    ]
  |> Encoding.encode

let checkpoint_id ~parent ~snapshot ~event ~created_at ~retention =
  let bytes =
    checkpoint_canonical_bytes ~parent ~snapshot ~event ~created_at ~retention
  in
  let digest = Hash.digest_string bytes |> Hash.to_raw_string in
  match Id.Checkpoint_id.of_bytes digest with
  | Ok identity -> identity
  | Error _ -> assert false

let make_checkpoint ~parent ~snapshot ~event ~created_at ~retention =
  let retention = normalise_retention retention in
  let id = checkpoint_id ~parent ~snapshot ~event ~created_at ~retention in
  {
    checkpoint_id = id;
    checkpoint_parent = parent;
    checkpoint_snapshot = snapshot;
    applied_event = event;
    checkpoint_created_at = created_at;
    checkpoint_retention = retention;
  }

let canonical_prior_entry value =
  match canonical_array "prior entry" value with
  | Error error -> Error error
  | Ok (tag :: fields) -> (
      match canonical_integer "prior entry tag" tag with
      | Error error -> Error error
      | Ok 0L -> (
          match fields with
          | [ mode; content ] -> (
              match
                ( canonical_mode mode,
                  canonical_bytes_value "prior file content" content )
              with
              | Ok mode, Ok content -> Ok (File { mode; content })
              | Error error, _ | _, Error error -> Error error)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "file prior entry must contain three values"))
      | Ok 1L -> (
          match fields with
          | [ records ] ->
              Snapshot.decode_entries_value records
              |> Result.map (fun tree -> Directory tree)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "directory prior entry must contain two values"))
      | Ok tag ->
          Error
            (Invalid_canonical_shape
               (Printf.sprintf "unknown prior entry tag: %Ld" tag)))
  | Ok [] -> Error (Invalid_canonical_shape "prior entry is empty")

let canonical_operation value =
  match canonical_array "scratch operation" value with
  | Error error -> Error error
  | Ok (tag :: fields) -> (
      match canonical_integer "scratch operation tag" tag with
      | Error error -> Error error
      | Ok 0L -> (
          match fields with
          | [ path; content; mode ] -> (
              match
                ( canonical_path path,
                  canonical_bytes_value "created file content" content,
                  canonical_mode mode )
              with
              | Ok path, Ok content, Ok mode ->
                  Ok (Create_file { path; content; mode })
              | Error error, _, _ | _, Error error, _ | _, _, Error error ->
                  Error error)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "create operation must contain four values"))
      | Ok 1L -> (
          match fields with
          | [ path; expected_content; replacement_content ] -> (
              match
                ( canonical_path path,
                  canonical_bytes_value "expected file content" expected_content,
                  canonical_bytes_value "replacement file content"
                    replacement_content )
              with
              | Ok path, Ok expected_content, Ok replacement_content ->
                  Ok
                    (Modify_file { path; expected_content; replacement_content })
              | Error error, _, _ | _, Error error, _ | _, _, Error error ->
                  Error error)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "modify operation must contain four values"))
      | Ok 5L -> (
          match fields with
          | [ path ] ->
              canonical_path path
              |> Result.map (fun path -> Create_directory { path })
          | _ ->
              Error
                (Invalid_canonical_shape
                   "create-directory operation must contain two values"))
      | Ok 2L -> (
          match fields with
          | [ path; prior ] -> (
              match (canonical_path path, canonical_prior_entry prior) with
              | Ok path, Ok prior -> Ok (Delete_path { path; prior })
              | Error error, _ | _, Error error -> Error error)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "delete operation must contain three values"))
      | Ok 3L -> (
          match fields with
          | [ source; destination; prior ] -> (
              match
                ( canonical_path source,
                  canonical_path destination,
                  canonical_prior_entry prior )
              with
              | Ok source, Ok destination, Ok prior ->
                  Ok (Move_path { source; destination; prior })
              | Error error, _, _ | _, Error error, _ | _, _, Error error ->
                  Error error)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "move operation must contain four values"))
      | Ok 4L -> (
          match fields with
          | [ path; expected_mode; replacement_mode ] -> (
              match
                ( canonical_path path,
                  canonical_mode expected_mode,
                  canonical_mode replacement_mode )
              with
              | Ok path, Ok expected_mode, Ok replacement_mode ->
                  Ok (Change_mode { path; expected_mode; replacement_mode })
              | Error error, _, _ | _, Error error, _ | _, _, Error error ->
                  Error error)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "mode operation must contain four values"))
      | Ok tag ->
          Error
            (Invalid_canonical_shape
               (Printf.sprintf "unknown scratch operation tag: %Ld" tag)))
  | Ok [] -> Error (Invalid_canonical_shape "scratch operation is empty")

let canonical_operations value =
  match canonical_array "scratch operations" value with
  | Error error -> Error error
  | Ok values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest -> (
            match canonical_operation value with
            | Error error -> Error error
            | Ok operation -> decode (operation :: reversed) rest)
      in
      decode [] values

module Scratch_operation = struct
  let canonical_bytes operation =
    scratch_operation_value operation |> Encoding.encode

  let decode_canonical_bytes bytes =
    let ( let* ) = Result.bind in
    let* value = canonical_value bytes in
    let* operation = canonical_operation value in
    if String.equal bytes (canonical_bytes operation) then Ok operation
    else Error Noncanonical_canonical_bytes
end

let canonical_source value =
  match canonical_integer "scratch event source" value with
  | Error error -> Error error
  | Ok 0L -> Ok Explicit
  | Ok 1L -> Ok Scan
  | Ok source ->
      Error
        (Invalid_canonical_shape
           (Printf.sprintf "unknown scratch event source: %Ld" source))

module Scratch_event = struct
  let create ~parent ~operations ~observed_at ~source =
    let id =
      event_canonical_bytes ~parent ~operations ~observed_at ~source
      |> operation_id
    in
    { event_id = id; event_parent = parent; operations; observed_at; source }

  let id event = event.event_id
  let parent event = event.event_parent
  let operations (event : scratch_event) = event.operations
  let observed_at (event : scratch_event) = event.observed_at
  let source (event : scratch_event) = event.source

  let canonical_bytes event =
    event_canonical_bytes ~parent:event.event_parent
      ~operations:event.operations ~observed_at:event.observed_at
      ~source:event.source

  let decode_canonical_bytes bytes =
    let ( let* ) = Result.bind in
    let* value = canonical_value bytes in
    let* fields = canonical_exact_array "scratch event" 5 value in
    match fields with
    | [ version; parent; operations; observed_at; source ] ->
        let* version = canonical_integer "scratch event version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_canonical_version version)
        else
          let* parent = canonical_identity parent Id.Checkpoint_id.of_bytes in
          let* operations = canonical_operations operations in
          let* observed_at =
            canonical_integer "scratch event timestamp" observed_at
          in
          let* source = canonical_source source in
          let event = create ~parent ~operations ~observed_at ~source in
          if String.equal bytes (canonical_bytes event) then Ok event
          else Error Noncanonical_canonical_bytes
    | _ -> assert false
end

let canonical_retention_reason value =
  match canonical_array "retention reason" value with
  | Error error -> Error error
  | Ok (tag :: fields) -> (
      match canonical_integer "retention reason tag" tag with
      | Error error -> Error error
      | Ok 0L -> (
          match fields with
          | [] -> Ok User_pinned
          | _ ->
              Error
                (Invalid_canonical_shape
                   "user-pinned retention reason must contain one value"))
      | Ok 1L -> (
          match fields with
          | [ identity ] ->
              canonical_identity identity Id.Capsule_id.of_bytes
              |> Result.map (fun identity -> Capsule_boundary identity)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "capsule retention reason must contain two values"))
      | Ok 2L -> (
          match fields with
          | [ identity ] ->
              canonical_identity identity Id.Release_id.of_bytes
              |> Result.map (fun identity -> Release_boundary identity)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "release retention reason must contain two values"))
      | Ok 3L -> (
          match fields with
          | [ identity ] ->
              canonical_identity identity Id.Validation_id.of_bytes
              |> Result.map (fun identity -> Validation_passed identity)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "validation retention reason must contain two values"))
      | Ok 4L -> (
          match fields with
          | [] -> Ok Periodic_retention
          | _ ->
              Error
                (Invalid_canonical_shape
                   "periodic retention reason must contain one value"))
      | Ok 5L -> (
          match fields with
          | [] -> Ok Recent_window
          | _ ->
              Error
                (Invalid_canonical_shape
                   "recent retention reason must contain one value"))
      | Ok 6L -> (
          match fields with
          | [ identity ] ->
              canonical_identity identity Id.Conflict_id.of_bytes
              |> Result.map (fun identity -> Conflict_reference identity)
          | _ ->
              Error
                (Invalid_canonical_shape
                   "conflict retention reason must contain two values"))
      | Ok tag ->
          Error
            (Invalid_canonical_shape
               (Printf.sprintf "unknown retention reason tag: %Ld" tag)))
  | Ok [] -> Error (Invalid_canonical_shape "retention reason is empty")

let canonical_retention value =
  match canonical_array "checkpoint retention" value with
  | Error error -> Error error
  | Ok values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest -> (
            match canonical_retention_reason value with
            | Error error -> Error error
            | Ok reason -> decode (reason :: reversed) rest)
      in
      decode [] values

let canonical_optional_identity value of_bytes =
  match value with
  | Encoding.Null -> Ok None
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ ->
      canonical_identity value of_bytes |> Result.map Option.some

module Checkpoint = struct
  let create ~parent ~snapshot ~event ~created_at ~retention =
    make_checkpoint ~parent ~snapshot ~event ~created_at ~retention

  let initial ~snapshot ~created_at ~retention =
    create ~parent:None ~snapshot ~event:None ~created_at ~retention

  let id checkpoint = checkpoint.checkpoint_id
  let parent checkpoint = checkpoint.checkpoint_parent
  let snapshot checkpoint = checkpoint.checkpoint_snapshot
  let event checkpoint = checkpoint.applied_event
  let created_at checkpoint = checkpoint.checkpoint_created_at
  let retention checkpoint = checkpoint.checkpoint_retention

  let canonical_bytes checkpoint =
    checkpoint_canonical_bytes ~parent:checkpoint.checkpoint_parent
      ~snapshot:checkpoint.checkpoint_snapshot ~event:checkpoint.applied_event
      ~created_at:checkpoint.checkpoint_created_at
      ~retention:checkpoint.checkpoint_retention

  let decode_canonical_bytes ~snapshot bytes =
    let ( let* ) = Result.bind in
    let* value = canonical_value bytes in
    let* fields = canonical_exact_array "checkpoint" 6 value in
    match fields with
    | [ version; parent; snapshot_id; event; created_at; retention ] ->
        let* version = canonical_integer "checkpoint version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_canonical_version version)
        else
          let* parent =
            canonical_optional_identity parent Id.Checkpoint_id.of_bytes
          in
          let* snapshot_id =
            canonical_identity snapshot_id Id.Snapshot_id.of_bytes
          in
          let* event =
            canonical_optional_identity event Id.Operation_id.of_bytes
          in
          let* created_at =
            canonical_integer "checkpoint timestamp" created_at
          in
          let* retention = canonical_retention retention in
          if not (Id.Snapshot_id.equal snapshot_id (Snapshot.id snapshot)) then
            Error Canonical_snapshot_reference_mismatch
          else
            let checkpoint =
              create ~parent ~snapshot ~event ~created_at ~retention
            in
            if String.equal bytes (canonical_bytes checkpoint) then
              Ok checkpoint
            else Error Noncanonical_canonical_bytes
    | _ -> assert false
end

module Scratch = struct
  let apply_event ~parent ~created_at ~retention event =
    let expected_parent = Checkpoint.id parent in
    let actual_parent = Scratch_event.parent event in
    if not (Id.Checkpoint_id.equal expected_parent actual_parent) then
      Error (Event_parent_mismatch { expected_parent; actual_parent })
    else
      match
        Snapshot.apply_operations
          (Checkpoint.snapshot parent)
          (Scratch_event.operations event)
      with
      | Error error -> Error (Event_operation_rejected error)
      | Ok snapshot ->
          Ok
            (make_checkpoint ~parent:(Some expected_parent) ~snapshot
               ~event:(Some (Scratch_event.id event))
               ~created_at ~retention)
end

module Snapshot_map = Map.Make (struct
  type t = Id.Snapshot_id.t

  let compare = Id.Snapshot_id.compare
end)

module Event_map = Map.Make (struct
  type t = Id.Operation_id.t

  let compare = Id.Operation_id.compare
end)

module Checkpoint_map = Map.Make (struct
  type t = Id.Checkpoint_id.t

  let compare = Id.Checkpoint_id.compare
end)

type repository = {
  snapshots : Snapshot.t Snapshot_map.t;
  events : scratch_event Event_map.t;
  checkpoints : checkpoint Checkpoint_map.t;
  scratch_head : Id.Checkpoint_id.t option;
}

type repository_error =
  | Snapshot_identity_mismatch of {
      supplied : Id.Snapshot_id.t;
      computed : Id.Snapshot_id.t;
    }
  | Event_identity_mismatch of {
      supplied : Id.Operation_id.t;
      computed : Id.Operation_id.t;
    }
  | Checkpoint_identity_mismatch of {
      supplied : Id.Checkpoint_id.t;
      computed : Id.Checkpoint_id.t;
    }
  | Conflicting_snapshot of Id.Snapshot_id.t
  | Conflicting_event of Id.Operation_id.t
  | Conflicting_checkpoint of Id.Checkpoint_id.t
  | Missing_snapshot of Id.Snapshot_id.t
  | Missing_event of Id.Operation_id.t
  | Missing_checkpoint of Id.Checkpoint_id.t
  | Event_parent_missing of Id.Checkpoint_id.t
  | Incoherent_checkpoint of Id.Checkpoint_id.t
  | Replay_operation_rejected of replay_error
  | Target_not_descended_from of {
      ancestor : Id.Checkpoint_id.t;
      target : Id.Checkpoint_id.t;
    }

let repository_error_to_string = function
  | Snapshot_identity_mismatch { supplied; computed } ->
      Printf.sprintf "snapshot identity mismatch: supplied %s, computed %s"
        (Id.Snapshot_id.short_hex supplied)
        (Id.Snapshot_id.short_hex computed)
  | Event_identity_mismatch { supplied; computed } ->
      Printf.sprintf "event identity mismatch: supplied %s, computed %s"
        (Id.Operation_id.short_hex supplied)
        (Id.Operation_id.short_hex computed)
  | Checkpoint_identity_mismatch { supplied; computed } ->
      Printf.sprintf "checkpoint identity mismatch: supplied %s, computed %s"
        (Id.Checkpoint_id.short_hex supplied)
        (Id.Checkpoint_id.short_hex computed)
  | Conflicting_snapshot identity ->
      Printf.sprintf "conflicting snapshot: %s"
        (Id.Snapshot_id.short_hex identity)
  | Conflicting_event identity ->
      Printf.sprintf "conflicting event: %s"
        (Id.Operation_id.short_hex identity)
  | Conflicting_checkpoint identity ->
      Printf.sprintf "conflicting checkpoint: %s"
        (Id.Checkpoint_id.short_hex identity)
  | Missing_snapshot identity ->
      Printf.sprintf "missing snapshot: %s" (Id.Snapshot_id.short_hex identity)
  | Missing_event identity ->
      Printf.sprintf "missing event: %s" (Id.Operation_id.short_hex identity)
  | Missing_checkpoint identity ->
      Printf.sprintf "missing checkpoint: %s"
        (Id.Checkpoint_id.short_hex identity)
  | Event_parent_missing identity ->
      Printf.sprintf "event parent missing: %s"
        (Id.Checkpoint_id.short_hex identity)
  | Incoherent_checkpoint identity ->
      Printf.sprintf "incoherent checkpoint: %s"
        (Id.Checkpoint_id.short_hex identity)
  | Replay_operation_rejected error ->
      Printf.sprintf "replay operation rejected: %s"
        (replay_error_to_string error)
  | Target_not_descended_from { ancestor; target } ->
      Printf.sprintf "checkpoint %s does not descend from %s"
        (Id.Checkpoint_id.short_hex target)
        (Id.Checkpoint_id.short_hex ancestor)

let scratch_operation_equal left right =
  match (left, right) with
  | Create_file left, Create_file right ->
      Path.equal left.path right.path
      && String.equal left.content right.content
      && left.mode = right.mode
  | Create_directory left, Create_directory right ->
      Path.equal left.path right.path
  | Modify_file left, Modify_file right ->
      Path.equal left.path right.path
      && String.equal left.expected_content right.expected_content
      && String.equal left.replacement_content right.replacement_content
  | Delete_path left, Delete_path right ->
      Path.equal left.path right.path && entry_equal left.prior right.prior
  | Move_path left, Move_path right ->
      Path.equal left.source right.source
      && Path.equal left.destination right.destination
      && entry_equal left.prior right.prior
  | Change_mode left, Change_mode right ->
      Path.equal left.path right.path
      && left.expected_mode = right.expected_mode
      && left.replacement_mode = right.replacement_mode
  | ( ( Create_file _ | Create_directory _ | Modify_file _ | Delete_path _
      | Move_path _ | Change_mode _ ),
      _ ) ->
      false

let scratch_event_equal left right =
  Id.Operation_id.equal left.event_id right.event_id
  && Id.Checkpoint_id.equal left.event_parent right.event_parent
  && List.equal scratch_operation_equal left.operations right.operations
  && Int64.equal left.observed_at right.observed_at
  && left.source = right.source

let retention_equal left right =
  List.equal
    (fun left right -> compare_retention_reason left right = 0)
    left right

let checkpoint_equal left right =
  Id.Checkpoint_id.equal left.checkpoint_id right.checkpoint_id
  && Option.equal Id.Checkpoint_id.equal left.checkpoint_parent
       right.checkpoint_parent
  && Snapshot.equal left.checkpoint_snapshot right.checkpoint_snapshot
  && Option.equal Id.Operation_id.equal left.applied_event right.applied_event
  && Int64.equal left.checkpoint_created_at right.checkpoint_created_at
  && retention_equal left.checkpoint_retention right.checkpoint_retention

module Repository = struct
  type t = repository

  let empty =
    {
      snapshots = Snapshot_map.empty;
      events = Event_map.empty;
      checkpoints = Checkpoint_map.empty;
      scratch_head = None;
    }

  let scratch_head repository = repository.scratch_head

  let find_snapshot repository identity =
    Snapshot_map.find_opt identity repository.snapshots

  let find_event repository identity =
    Event_map.find_opt identity repository.events

  let find_checkpoint repository identity =
    Checkpoint_map.find_opt identity repository.checkpoints

  let insert_snapshot repository ~id snapshot =
    match find_snapshot repository id with
    | Some existing ->
        if Snapshot.equal existing snapshot then Ok repository
        else Error (Conflicting_snapshot id)
    | None ->
        let computed = Snapshot.id snapshot in
        if not (Id.Snapshot_id.equal id computed) then
          Error (Snapshot_identity_mismatch { supplied = id; computed })
        else
          Ok
            {
              repository with
              snapshots = Snapshot_map.add id snapshot repository.snapshots;
            }

  let add_snapshot repository snapshot =
    insert_snapshot repository ~id:(Snapshot.id snapshot) snapshot

  let insert_event repository ~id event =
    match find_event repository id with
    | Some existing ->
        if scratch_event_equal existing event then Ok repository
        else Error (Conflicting_event id)
    | None ->
        let computed = Scratch_event.id event in
        if not (Id.Operation_id.equal id computed) then
          Error (Event_identity_mismatch { supplied = id; computed })
        else
          let parent = Scratch_event.parent event in
          if Option.is_none (find_checkpoint repository parent) then
            Error (Event_parent_missing parent)
          else
            Ok
              {
                repository with
                events = Event_map.add id event repository.events;
              }

  let add_event repository event =
    insert_event repository ~id:(Scratch_event.id event) event

  let checkpoint_replays repository checkpoint =
    match (Checkpoint.parent checkpoint, Checkpoint.event checkpoint) with
    | None, None -> Ok ()
    | Some parent_id, Some event_id -> (
        match find_checkpoint repository parent_id with
        | None -> Error (Missing_checkpoint parent_id)
        | Some parent -> (
            match find_event repository event_id with
            | None -> Error (Missing_event event_id)
            | Some event -> (
                if
                  not
                    (Id.Checkpoint_id.equal
                       (Scratch_event.parent event)
                       parent_id)
                then Error (Incoherent_checkpoint (Checkpoint.id checkpoint))
                else
                  match
                    Snapshot.apply_operations
                      (Checkpoint.snapshot parent)
                      (Scratch_event.operations event)
                  with
                  | Error error -> Error (Replay_operation_rejected error)
                  | Ok replayed ->
                      if
                        Snapshot.equal replayed (Checkpoint.snapshot checkpoint)
                      then Ok ()
                      else
                        Error (Incoherent_checkpoint (Checkpoint.id checkpoint))
                )))
    | None, Some _ | Some _, None ->
        Error (Incoherent_checkpoint (Checkpoint.id checkpoint))

  let insert_checkpoint repository ~id checkpoint =
    match find_checkpoint repository id with
    | Some existing ->
        if checkpoint_equal existing checkpoint then Ok repository
        else Error (Conflicting_checkpoint id)
    | None -> (
        let computed = Checkpoint.id checkpoint in
        if not (Id.Checkpoint_id.equal id computed) then
          Error (Checkpoint_identity_mismatch { supplied = id; computed })
        else
          let snapshot_id = Snapshot.id (Checkpoint.snapshot checkpoint) in
          if Option.is_none (find_snapshot repository snapshot_id) then
            Error (Missing_snapshot snapshot_id)
          else
            match checkpoint_replays repository checkpoint with
            | Error error -> Error error
            | Ok () ->
                Ok
                  {
                    repository with
                    checkpoints =
                      Checkpoint_map.add id checkpoint repository.checkpoints;
                    scratch_head = Some id;
                  })

  let add_checkpoint repository checkpoint =
    insert_checkpoint repository ~id:(Checkpoint.id checkpoint) checkpoint

  let replay repository ~ancestor ~target =
    match find_checkpoint repository ancestor with
    | None -> Error (Missing_checkpoint ancestor)
    | Some ancestor_checkpoint -> (
        let rec event_path checkpoint_id links =
          if Id.Checkpoint_id.equal checkpoint_id ancestor then Ok links
          else
            match find_checkpoint repository checkpoint_id with
            | None -> Error (Missing_checkpoint checkpoint_id)
            | Some checkpoint -> (
                match
                  (Checkpoint.parent checkpoint, Checkpoint.event checkpoint)
                with
                | Some parent, Some event ->
                    event_path parent ((event, checkpoint) :: links)
                | None, None ->
                    Error (Target_not_descended_from { ancestor; target })
                | None, Some _ | Some _, None ->
                    Error (Incoherent_checkpoint checkpoint_id))
        in
        match event_path target [] with
        | Error error -> Error error
        | Ok events ->
            let rec apply snapshot = function
              | [] -> Ok snapshot
              | (event_id, expected_checkpoint) :: rest -> (
                  match find_event repository event_id with
                  | None -> Error (Missing_event event_id)
                  | Some event -> (
                      match
                        Snapshot.apply_operations snapshot
                          (Scratch_event.operations event)
                      with
                      | Error error -> Error (Replay_operation_rejected error)
                      | Ok snapshot ->
                          if
                            Snapshot.equal snapshot
                              (Checkpoint.snapshot expected_checkpoint)
                          then apply snapshot rest
                          else
                            Error
                              (Incoherent_checkpoint
                                 (Checkpoint.id expected_checkpoint))))
            in
            apply (Checkpoint.snapshot ancestor_checkpoint) events)
end
