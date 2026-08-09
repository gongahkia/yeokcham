module Model = Yeokcham_model

module Path_map = Map.Make (struct
  type t = Model.Path.t

  let compare = Model.Path.compare
end)

type action =
  | Remove_file of Model.Path.t
  | Remove_directory of Model.Path.t
  | Ensure_directory of Model.Path.t
  | Write_file of {
      path : Model.Path.t;
      content : string;
      mode : Model.file_mode;
    }
  | Create_symlink of { path : Model.Path.t; target : string }
  | Set_file_mode of { path : Model.Path.t; mode : Model.file_mode }

type t = {
  observed : Model.Snapshot.t;
  target : Model.Snapshot.t;
  safety_snapshot : Model.Snapshot.t option;
  actions : action list;
}

type replay_error = Invalid_action of string

let replay_error_to_string = function
  | Invalid_action detail -> "invalid V2 restore plan action: " ^ detail

let path_to_string = Model.Path.to_string

let mode_to_string = function
  | Model.Regular -> "regular"
  | Model.Executable -> "executable"
  | Model.Symlink -> "symlink"

let action_to_string = function
  | Remove_file path -> "remove-file " ^ path_to_string path
  | Remove_directory path -> "remove-directory " ^ path_to_string path
  | Ensure_directory path -> "ensure-directory " ^ path_to_string path
  | Write_file { path; content; mode } ->
      Printf.sprintf "write-file %s %s %S" (path_to_string path)
        (mode_to_string mode) content
  | Create_symlink { path; target } ->
      Printf.sprintf "create-symlink %s %S" (path_to_string path) target
  | Set_file_mode { path; mode } ->
      Printf.sprintf "set-file-mode %s %s" (path_to_string path)
        (mode_to_string mode)

let entry_map snapshot =
  Model.Snapshot.entries snapshot
  |> List.fold_left
       (fun entries entry ->
         let path =
           match entry with
           | Model.Directory_path path | Model.File_path (path, _) -> path
         in
         Path_map.add path entry entries)
       Path_map.empty

let entry_at entries path =
  Path_map.find_opt path entries
  |> Option.map (function
    | Model.Directory_path _ -> `Directory
    | Model.File_path (_, entry) -> `File entry)

let initial_entry path = function
  | `Directory -> Model.Directory_path path
  | `File entry -> Model.File_path (path, entry)

let path_depth path = List.length (Model.Path.to_components path)

let compare_shallowest_first left right =
  match Int.compare (path_depth left) (path_depth right) with
  | 0 -> Model.Path.compare left right
  | comparison -> comparison

let compare_deepest_first left right =
  match Int.compare (path_depth right) (path_depth left) with
  | 0 -> Model.Path.compare left right
  | comparison -> comparison

let is_symlink entry = entry.Model.mode = Model.Symlink

let removal_action path = function
  | `Directory -> Remove_directory path
  | `File _ -> Remove_file path

let source_requires_removal source target =
  match (source, target) with
  | `Directory, Some `Directory -> false
  | `File source, Some (`File target) ->
      is_symlink source <> is_symlink target
      || is_symlink source
         && not (String.equal source.Model.content target.Model.content)
  | `Directory, Some (`File _) | `File _, Some `Directory | _, None -> true

let target_file_action path target source =
  if target.Model.mode = Model.Symlink then
    match source with
    | Some (`File source)
      when source.Model.mode = Model.Symlink
           && String.equal source.Model.content target.Model.content ->
        None
    | None | Some `Directory | Some (`File _) ->
        Some (Create_symlink { path; target = target.Model.content })
  else
    match source with
    | Some (`File source) when source.Model.mode <> Model.Symlink ->
        if String.equal source.Model.content target.Model.content then
          if source.Model.mode = target.Model.mode then None
          else Some (Set_file_mode { path; mode = target.Model.mode })
        else
          Some
            (Write_file
               {
                 path;
                 content = target.Model.content;
                 mode = target.Model.mode;
               })
    | None | Some `Directory | Some (`File _) ->
        Some
          (Write_file
             { path; content = target.Model.content; mode = target.Model.mode })

let action_path = function
  | Remove_file path | Remove_directory path | Ensure_directory path -> path
  | Write_file { path; _ }
  | Create_symlink { path; _ }
  | Set_file_mode { path; _ } ->
      path

let build ~observed ~target =
  if Model.Snapshot.equal observed target then
    { observed; target; safety_snapshot = None; actions = [] }
  else
    let source_entries = entry_map observed in
    let target_entries = entry_map target in
    let removals =
      Path_map.fold
        (fun path source actions ->
          let source =
            match source with
            | Model.Directory_path _ -> `Directory
            | Model.File_path (_, entry) -> `File entry
          in
          let target = entry_at target_entries path in
          if source_requires_removal source target then
            (path, removal_action path source) :: actions
          else actions)
        source_entries []
      |> List.sort (fun (left, _) (right, _) ->
          compare_deepest_first left right)
      |> List.map snd
    in
    let directories, files =
      Path_map.fold
        (fun path target (directories, files) ->
          match target with
          | Model.Directory_path _ -> (
              match entry_at source_entries path with
              | Some `Directory -> (directories, files)
              | None | Some (`File _) ->
                  (Ensure_directory path :: directories, files))
          | Model.File_path (_, target) ->
              let action =
                target_file_action path target (entry_at source_entries path)
              in
              let files =
                match action with
                | None -> files
                | Some action -> action :: files
              in
              (directories, files))
        target_entries ([], [])
    in
    let directories =
      List.sort
        (fun left right ->
          compare_shallowest_first (action_path left) (action_path right))
        directories
    in
    let files =
      List.sort
        (fun left right ->
          Model.Path.compare (action_path left) (action_path right))
        files
    in
    {
      observed;
      target;
      safety_snapshot = Some observed;
      actions = removals @ directories @ files;
    }

let observed plan = plan.observed
let target plan = plan.target
let safety_snapshot plan = plan.safety_snapshot
let actions plan = plan.actions
let is_noop plan = plan.actions = []

let parent_path path =
  match List.rev (Model.Path.to_components path) with
  | [] -> assert false
  | [ _ ] -> None
  | _ :: parent ->
      Model.Path.of_components (List.rev parent) |> Result.to_option

let is_descendant ~parent path =
  let rec has_prefix prefix path =
    match (prefix, path) with
    | [], _ -> true
    | prefix :: prefix_rest, path :: path_rest ->
        String.equal prefix path && has_prefix prefix_rest path_rest
    | _ :: _, [] -> false
  in
  let parent_components = Model.Path.to_components parent in
  let path_components = Model.Path.to_components path in
  List.length path_components > List.length parent_components
  && has_prefix parent_components path_components

let parent_is_directory entries path =
  match parent_path path with
  | None -> true
  | Some parent -> (
      match entry_at entries parent with Some `Directory -> true | _ -> false)

let replay_actions plan actions =
  let error detail = Error (Invalid_action detail) in
  let apply entries = function
    | Remove_file path -> (
        match entry_at entries path with
        | Some (`File _) -> Ok (Path_map.remove path entries)
        | Some `Directory -> error ("expected file at " ^ path_to_string path)
        | None -> error ("missing file at " ^ path_to_string path))
    | Remove_directory path -> (
        match entry_at entries path with
        | Some `Directory ->
            if
              Path_map.exists
                (fun child _ -> is_descendant ~parent:path child)
                entries
            then error ("directory remains nonempty: " ^ path_to_string path)
            else Ok (Path_map.remove path entries)
        | Some (`File _) ->
            error ("expected directory at " ^ path_to_string path)
        | None -> error ("missing directory at " ^ path_to_string path))
    | Ensure_directory path -> (
        if not (parent_is_directory entries path) then
          error ("missing directory parent for " ^ path_to_string path)
        else
          match entry_at entries path with
          | None -> Ok (Path_map.add path (Model.Directory_path path) entries)
          | Some _ -> error ("existing path at " ^ path_to_string path))
    | Write_file { path; content; mode } -> (
        if mode = Model.Symlink then
          error ("write-file cannot create symlink " ^ path_to_string path)
        else if not (parent_is_directory entries path) then
          error ("missing directory parent for " ^ path_to_string path)
        else
          match entry_at entries path with
          | None ->
              Ok
                (Path_map.add path
                   (Model.File_path (path, { Model.mode; content }))
                   entries)
          | Some (`File current) ->
              if current.Model.mode = Model.Symlink then
                error ("symlink requires removal at " ^ path_to_string path)
              else
                Ok
                  (Path_map.add path
                     (Model.File_path (path, { Model.mode; content }))
                     entries)
          | Some `Directory ->
              error ("directory requires removal at " ^ path_to_string path))
    | Create_symlink { path; target } -> (
        if not (parent_is_directory entries path) then
          error ("missing directory parent for " ^ path_to_string path)
        else
          match entry_at entries path with
          | None ->
              Ok
                (Path_map.add path
                   (Model.File_path
                      (path, { Model.mode = Model.Symlink; content = target }))
                   entries)
          | Some _ -> error ("existing path at " ^ path_to_string path))
    | Set_file_mode { path; mode } -> (
        match entry_at entries path with
        | Some (`File current) ->
            if current.Model.mode = Model.Symlink || mode = Model.Symlink then
              error ("symlink mode transition at " ^ path_to_string path)
            else
              Ok
                (Path_map.add path
                   (Model.File_path
                      (path, { Model.mode; content = current.Model.content }))
                   entries)
        | Some `Directory -> error ("expected file at " ^ path_to_string path)
        | None -> error ("missing file at " ^ path_to_string path))
  in
  let rec run entries = function
    | [] ->
        Path_map.bindings entries
        |> List.map (fun (path, entry) ->
            match entry with
            | Model.Directory_path _ -> initial_entry path `Directory
            | Model.File_path (_, file) -> initial_entry path (`File file))
        |> Model.Snapshot.of_entries
        |> Result.map_error (fun error ->
            Invalid_action (Model.construction_error_to_string error))
    | action :: rest ->
        Result.bind (apply entries action) (fun entries -> run entries rest)
  in
  run (entry_map plan.observed) actions

let replay plan = replay_actions plan plan.actions

let rec take count values =
  match (count, values) with
  | 0, _ -> []
  | _, [] -> []
  | count, value :: rest -> value :: take (count - 1) rest

let replay_prefix plan ~completed_actions =
  let action_count = List.length plan.actions in
  if completed_actions < 0 || completed_actions > action_count then
    Error
      (Invalid_action
         (Printf.sprintf "completed action count %d is outside 0..%d"
            completed_actions action_count))
  else replay_actions plan (take completed_actions plan.actions)
