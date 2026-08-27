module Model = Yeokcham_v4_model
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_v4_store

module Path_map = Map.Make (struct
  type t = string list

  let compare = List.compare String.compare
end)

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Materialize_error of Snapshot.Materialize.error
  | Model_error of Model.error
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Model.Snapshot_id.t
  | Unchanged_share of Model.Snapshot_id.t

type save_outcome = Unchanged of status | Saved of status

and status = {
  active_draft : Model.draft;
  checkpoint : Model.Snapshot_id.t;
  shared_changes : Model.shared_change list;
  shared_change_count : int;
  open_decisions : Model.decision list;
  deliveries : Model.delivery list;
  delivery_count : int;
  checkpoints : Model.checkpoint list;
}

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Materialize_error error -> Snapshot.Materialize.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Invalid_checkpoint_id value ->
      "invalid saved checkpoint identifier: " ^ value
  | Unknown_checkpoint id ->
      "checkpoint is not retained by this project: "
      ^ Model.Snapshot_id.to_string id
  | Unchanged_share snapshot ->
      "share would not publish a new snapshot: "
      ^ Model.Snapshot_id.to_string snapshot

let ( let* ) = Result.bind

let snapshot_id identity =
  identity |> Snapshot.Snapshot.stored_object_id
  |> Yeokcham_store.Stored_object_id.to_hex |> Model.Snapshot_id.of_string
  |> Result.map_error (fun error -> Model_error error)

let capture ~root store =
  let* identity, _ =
    Snapshot.scan_excluding_root_names
      ~excluded_root_names:[ ".yeokcham"; ".git" ] ~root ~store
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  snapshot_id identity

let status_of_project project =
  let active_draft = Model.active_draft project in
  let projection = Model.projection project in
  let shared_changes = Model.shared_changes project in
  let deliveries = Model.deliveries project in
  {
    active_draft;
    checkpoint = active_draft.Model.latest_checkpoint;
    shared_changes;
    shared_change_count = List.length shared_changes;
    open_decisions = projection.Model.decisions;
    deliveries;
    delivery_count = List.length deliveries;
    checkpoints = Model.checkpoints project;
  }

let load_snapshot store snapshot =
  let text = Model.Snapshot_id.to_string snapshot in
  let* object_id =
    Yeokcham_store.Stored_object_id.of_hex text
    |> Result.map_error (fun _ -> Invalid_checkpoint_id text)
  in
  Snapshot.Snapshot.load store (Snapshot.Snapshot.of_stored_object_id object_id)
  |> Result.map_error (fun error -> Snapshot_error error)

let rec collect_leaves store prefix tree_id acc =
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec walk acc = function
    | [] -> Ok acc
    | (name, entry) :: rest ->
        let path = prefix @ [ name ] in
        let* acc =
          match entry with
          | Snapshot.Tree.File { mode; content } ->
              Ok (Path_map.add path (mode, content) acc)
          | Snapshot.Tree.Directory child -> collect_leaves store path child acc
        in
        walk acc rest
  in
  walk acc (Snapshot.Tree.entries tree)

let leaves_of_snapshot store snapshot_id =
  let* snapshot = load_snapshot store snapshot_id in
  collect_leaves store [] (Snapshot.Snapshot.root snapshot) Path_map.empty

let entry_equal (left_mode, left_content) (right_mode, right_content) =
  left_mode = right_mode && Snapshot.Content.equal_id left_content right_content

let differing_paths left right =
  Path_map.merge
    (fun _ left right ->
      match (left, right) with
      | Some left, Some right when entry_equal left right -> None
      | None, None -> None
      | _ -> Some ())
    left right
  |> Path_map.bindings |> List.map fst

let whole_path_edits paths =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | components :: rest ->
        let* path =
          Model.Path.of_components components
          |> Result.map_error (fun error -> Model_error error)
        in
        loop
          (Model.{ edit_path = path; edit_kind = Whole_path } :: reversed)
          rest
  in
  loop [] paths

let edits_between store ~baseline ~result =
  let* baseline_leaves = leaves_of_snapshot store baseline in
  let* result_leaves = leaves_of_snapshot store result in
  differing_paths baseline_leaves result_leaves |> whole_path_edits

let persist repository loaded project =
  Store.save repository ~expected:loaded.Store.head ~project
  |> Result.map (fun saved -> status_of_project saved.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let checkpoint_observed project observed =
  let active = Model.active_draft project in
  if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
    project
  else Model.checkpoint project ~snapshot:observed

let with_repository ~root f =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  f repository loaded

let init ~root ~creator ~initial_draft ~title =
  let* repository =
    Store.init_with ~root ~bootstrap:(fun underlying_store ->
        let* initial_snapshot =
          capture ~root underlying_store |> Result.map_error error_to_string
        in
        Ok (Model.init ~creator ~initial_snapshot ~initial_draft ~title))
    |> Result.map_error (fun error -> Store_error error)
  in
  Store.load repository
  |> Result.map (fun loaded -> status_of_project loaded.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let status ~root =
  with_repository ~root (fun _ loaded ->
      Ok (status_of_project loaded.Store.project))

let save ~root =
  with_repository ~root (fun repository loaded ->
      let* observed = capture ~root (Store.underlying_store repository) in
      let active = Model.active_draft loaded.Store.project in
      if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
        Ok (Unchanged (status_of_project loaded.Store.project))
      else
        let project =
          Model.checkpoint loaded.Store.project ~snapshot:observed
        in
        persist repository loaded project
        |> Result.map (fun status -> Saved status))

let restore ~root ~checkpoint ~destination =
  with_repository ~root (fun repository loaded ->
      if
        not
          (List.exists
             (fun candidate ->
               Model.Snapshot_id.equal candidate.Model.checkpoint_snapshot
                 checkpoint)
             (Model.checkpoints loaded.Store.project))
      then Error (Unknown_checkpoint checkpoint)
      else
        let* snapshot =
          load_snapshot (Store.underlying_store repository) checkpoint
        in
        Snapshot.Materialize.write ~destination
          (Store.underlying_store repository)
          snapshot
        |> Result.map_error (fun error -> Materialize_error error))

let new_draft ~root ~id ~title =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.new_draft loaded.Store.project ~id ~title
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let make_revision project ~change ~revision ~parent ~base ~result ~edits =
  Model.make_change_revision ~change ~revision ~parent
    ~author:(Model.creator project) ~base ~result ~edits
  |> Result.map_error (fun error -> Model_error error)

let share ~root ~change ~revision =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let baseline = (Model.projection project).Model.projection_baseline in
      let active = Model.active_draft project in
      let* () =
        match active.Model.shared_change with
        | None -> Ok ()
        | Some change_id -> (
            match
              List.find_opt
                (fun candidate ->
                  Model.Change_id.equal candidate.Model.change_id change_id)
                (Model.shared_changes project)
            with
            | None -> Ok ()
            | Some shared -> (
                match shared.Model.revisions with
                | latest :: _
                  when Model.Snapshot_id.equal latest.Model.result_snapshot
                         observed ->
                    Error (Unchanged_share observed)
                | _ -> Ok ()))
      in
      let* edits = edits_between store ~baseline ~result:observed in
      let* recorded =
        match active.Model.shared_change with
        | None ->
            let* recorded =
              make_revision project ~change ~revision ~parent:None
                ~base:baseline ~result:observed ~edits
            in
            Model.share_active project recorded
            |> Result.map_error (fun error -> Model_error error)
        | Some change_id ->
            let parent =
              match
                List.find_opt
                  (fun candidate ->
                    Model.Change_id.equal candidate.Model.change_id change_id)
                  (Model.shared_changes project)
              with
              | Some shared -> (
                  match shared.Model.revisions with
                  | latest :: _ -> Some latest.Model.revision
                  | [] -> None)
              | None -> None
            in
            let* recorded =
              make_revision project ~change ~revision ~parent ~base:baseline
                ~result:observed ~edits
            in
            Model.amend_active project recorded
            |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded recorded)

let withdraw ~root ~change =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.withdraw loaded.Store.project ~change
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let resolve ~root ~decision ~change ~revision =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let projection = Model.projection project in
      match
        List.find_opt
          (fun candidate ->
            Model.Decision_id.equal candidate.Model.decision_id decision)
          projection.Model.decisions
      with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some resolved ->
          let* edits =
            resolved.Model.decision_paths
            |> List.map Model.Path.components
            |> whole_path_edits
          in
          let* replacement =
            make_revision project ~change ~revision ~parent:None
              ~base:projection.Model.projection_baseline ~result:observed ~edits
          in
          let* project =
            Model.resolve project ~decision ~replacement
            |> Result.map_error (fun error -> Model_error error)
          in
          persist repository loaded project)

let deliver ~root ~id ~next_draft ~next_title =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let included =
        List.map
          (fun revision -> revision.Model.revision)
          (Model.projection project).Model.applied
      in
      let created_at = Int64.of_float (Unix.gettimeofday ()) in
      let* project =
        Model.deliver project ~id ~author:(Model.creator project)
          ~snapshot:observed ~included ~next_draft ~next_title ~created_at
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)
