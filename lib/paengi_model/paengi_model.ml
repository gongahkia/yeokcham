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
