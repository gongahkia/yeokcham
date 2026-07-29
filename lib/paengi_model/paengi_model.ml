module Encoding = Paengi_encoding
module Hash = Paengi_hash.Sha256
module Id = Paengi_id

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

  let id snapshot =
    let digest =
      Hash.feed_string Hash.empty "paengi:snapshot:v1\000" |> fun context ->
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
end

module Checkpoint = struct
  let initial ~snapshot ~created_at ~retention =
    make_checkpoint ~parent:None ~snapshot ~event:None ~created_at ~retention

  let id checkpoint = checkpoint.checkpoint_id
  let parent checkpoint = checkpoint.checkpoint_parent
  let snapshot checkpoint = checkpoint.checkpoint_snapshot
  let event checkpoint = checkpoint.applied_event
  let created_at checkpoint = checkpoint.checkpoint_created_at
  let retention checkpoint = checkpoint.checkpoint_retention
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
