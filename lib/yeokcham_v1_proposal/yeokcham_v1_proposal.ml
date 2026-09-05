module Model = Yeokcham_v1_model

let ( let* ) = Result.bind

module Path_map = Map.Make (struct
  type t = Model.Path.t

  let compare = Model.Path.compare
end)

module Path_set = Set.Make (struct
  type t = Model.Path.t

  let compare = Model.Path.compare
end)

type entry =
  | File of { mode : Yeokcham_snapshot.file_mode; content : string }
  | Directory

type tree = entry Path_map.t
type source = Base | Left | Right

type conflict =
  | Competing_creation
  | Delete_modify
  | File_directory
  | Mode_mismatch
  | Content_mismatch
  | Mode_and_content_mismatch

type path_outcome =
  | Select of { source : source; entry : entry option }
  | Conflict of conflict
  | Unassessed_without_common_base

type path = {
  path : Model.Path.t;
  base : entry option;
  left : entry option;
  right : entry option;
  outcome : path_outcome;
}

type provenance = {
  decision : Model.Decision_id.t;
  current_baseline : Model.Snapshot_id.t;
  left_revision : Model.Revision_id.t;
  left_base : Model.Snapshot_id.t;
  left_result : Model.Snapshot_id.t;
  right_revision : Model.Revision_id.t;
  right_base : Model.Snapshot_id.t;
  right_result : Model.Snapshot_id.t;
}

type refusal =
  | Same_candidate
  | Incompatible_bases of {
      left_base : Model.Snapshot_id.t;
      right_base : Model.Snapshot_id.t;
    }
  | Stale_base of {
      proposal_base : Model.Snapshot_id.t;
      current_baseline : Model.Snapshot_id.t;
    }
  | Conflicting_paths of Model.Path.t list

type readiness = Ready | Refused of refusal list
type confidence = Exact_source | No_confidence

type t = {
  provenance : provenance;
  readiness : readiness;
  confidence : confidence;
  paths : path list;
}

type tree_error = Duplicate_path of Model.Path.t

let tree_of_entries entries =
  List.fold_left
    (fun tree (path, entry) ->
      let* tree = tree in
      if Path_map.mem path tree then Error (Duplicate_path path)
      else Ok (Path_map.add path entry tree))
    (Ok Path_map.empty) entries

let source_to_string = function
  | Base -> "base"
  | Left -> "left"
  | Right -> "right"

let conflict_to_string = function
  | Competing_creation -> "competing-creation"
  | Delete_modify -> "delete-modify"
  | File_directory -> "file-directory"
  | Mode_mismatch -> "mode-mismatch"
  | Content_mismatch -> "content-mismatch"
  | Mode_and_content_mismatch -> "mode-and-content-mismatch"

let refusal_to_string = function
  | Same_candidate -> "the two named revisions are the same candidate"
  | Incompatible_bases { left_base; right_base } ->
      Printf.sprintf "candidates have different bases: %s and %s"
        (Model.Snapshot_id.to_string left_base)
        (Model.Snapshot_id.to_string right_base)
  | Stale_base { proposal_base; current_baseline } ->
      Printf.sprintf "candidate base %s is not the current baseline %s"
        (Model.Snapshot_id.to_string proposal_base)
        (Model.Snapshot_id.to_string current_baseline)
  | Conflicting_paths paths ->
      Printf.sprintf "exact composition is refused for %d path(s)"
        (List.length paths)

let tree_error_to_string = function
  | Duplicate_path path ->
      "proposal tree contains the same path twice: " ^ Model.Path.to_string path

let entry_equal left right =
  match (left, right) with
  | None, None -> true
  | Some Directory, Some Directory -> true
  | Some (File left), Some (File right) ->
      left.mode = right.mode && String.equal left.content right.content
  | None, Some _
  | Some _, None
  | Some Directory, Some (File _)
  | Some (File _), Some Directory ->
      false

let changed_from base candidate = not (entry_equal base candidate)

type entry_shape =
  | Missing
  | Directory_entry
  | File_entry of Yeokcham_snapshot.file_mode * string

let entry_shape = function
  | None -> Missing
  | Some Directory -> Directory_entry
  | Some (File { mode; content }) -> File_entry (mode, content)

let[@warning "-4"] conflict_of_entries ~base ~left ~right =
  match (entry_shape base, entry_shape left, entry_shape right) with
  | Missing, File_entry _, File_entry _
  | Missing, Directory_entry, Directory_entry ->
      Competing_creation
  | (File_entry _ | Directory_entry), Missing, (File_entry _ | Directory_entry)
  | (File_entry _ | Directory_entry), (File_entry _ | Directory_entry), Missing
    ->
      Delete_modify
  | _, Directory_entry, File_entry _ | _, File_entry _, Directory_entry ->
      File_directory
  | ( _,
      File_entry (left_mode, left_content),
      File_entry (right_mode, right_content) ) ->
      let mode_differs = left_mode <> right_mode in
      let content_differs = not (String.equal left_content right_content) in
      if mode_differs && content_differs then Mode_and_content_mismatch
      else if mode_differs then Mode_mismatch
      else Content_mismatch
  | _ -> invalid_arg "proposal conflict requested for a non-conflicting path"

let path_set base left right =
  let add_paths tree paths =
    Path_map.fold (fun path _ paths -> Path_set.add path paths) tree paths
  in
  Path_set.empty |> add_paths base |> add_paths left |> add_paths right

let classify_path ~common_base base left right =
  if not common_base then Unassessed_without_common_base
  else if entry_equal left right then Select { source = Left; entry = left }
  else if entry_equal base left then Select { source = Right; entry = right }
  else if entry_equal base right then Select { source = Left; entry = left }
  else if changed_from base left && changed_from base right then
    Conflict (conflict_of_entries ~base ~left ~right)
  else invalid_arg "proposal path classification is incomplete"

let classify ~decision ~current_baseline ~left ~right ~base ~left_tree
    ~right_tree =
  let left, right, left_tree, right_tree =
    if Model.Revision_id.compare left.Model.revision right.Model.revision <= 0
    then (left, right, left_tree, right_tree)
    else (right, left, right_tree, left_tree)
  in
  let provenance =
    {
      decision;
      current_baseline;
      left_revision = left.Model.revision;
      left_base = left.Model.base_snapshot;
      left_result = left.Model.result_snapshot;
      right_revision = right.Model.revision;
      right_base = right.Model.base_snapshot;
      right_result = right.Model.result_snapshot;
    }
  in
  let common_base =
    Model.Snapshot_id.equal left.Model.base_snapshot right.Model.base_snapshot
  in
  let paths =
    path_set base left_tree right_tree
    |> Path_set.elements
    |> List.map (fun path ->
        let base_entry = Path_map.find_opt path base in
        let left_entry = Path_map.find_opt path left_tree in
        let right_entry = Path_map.find_opt path right_tree in
        {
          path;
          base = base_entry;
          left = left_entry;
          right = right_entry;
          outcome = classify_path ~common_base base_entry left_entry right_entry;
        })
  in
  let refusals =
    let base_refusals =
      if not common_base then
        [
          Incompatible_bases
            {
              left_base = left.Model.base_snapshot;
              right_base = right.Model.base_snapshot;
            };
        ]
      else if
        not (Model.Snapshot_id.equal left.Model.base_snapshot current_baseline)
      then
        [
          Stale_base
            { proposal_base = left.Model.base_snapshot; current_baseline };
        ]
      else []
    in
    let same_candidate =
      if Model.Revision_id.equal left.Model.revision right.Model.revision then
        [ Same_candidate ]
      else []
    in
    let conflicts =
      paths
      |> List.filter_map (fun path ->
          match path.outcome with
          | Conflict _ -> Some path.path
          | Select _ | Unassessed_without_common_base -> None)
    in
    let conflict_refusals =
      match conflicts with [] -> [] | _ -> [ Conflicting_paths conflicts ]
    in
    base_refusals @ same_candidate @ conflict_refusals
  in
  let readiness = match refusals with [] -> Ready | _ -> Refused refusals in
  let confidence =
    match readiness with Ready -> Exact_source | Refused _ -> No_confidence
  in
  { provenance; readiness; confidence; paths }

let selected proposal =
  match proposal.readiness with
  | Refused _ -> None
  | Ready ->
      proposal.paths
      |> List.fold_left
           (fun selected path ->
             match (selected, path.outcome) with
             | Some selected, Select { source; entry } ->
                 Some ((path.path, source, entry) :: selected)
             | Some _, Conflict _ | Some _, Unassessed_without_common_base ->
                 None
             | None, _ -> None)
           (Some [])
      |> Option.map List.rev
