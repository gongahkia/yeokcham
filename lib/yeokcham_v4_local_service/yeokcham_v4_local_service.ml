module Model = Yeokcham_v4_model
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_v4_store

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Materialize_error of Snapshot.Materialize.error
  | Model_error of Model.error
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Model.Snapshot_id.t

type save_outcome = Unchanged of status | Saved of status

and status = {
  active_draft : Model.draft;
  checkpoint : Model.Snapshot_id.t;
  shared_change_count : int;
  open_decisions : Model.decision list;
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
  {
    active_draft;
    checkpoint = active_draft.Model.latest_checkpoint;
    shared_change_count = List.length (Model.shared_changes project);
    open_decisions = projection.Model.decisions;
    delivery_count = List.length (Model.deliveries project);
    checkpoints = Model.checkpoints project;
  }

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
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  Store.load repository
  |> Result.map (fun loaded -> status_of_project loaded.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let save ~root =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  let* observed = capture ~root (Store.underlying_store repository) in
  let active = Model.active_draft loaded.Store.project in
  if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
    Ok (Unchanged (status_of_project loaded.Store.project))
  else
    let project = Model.checkpoint loaded.Store.project ~snapshot:observed in
    Store.save repository ~expected:loaded.Store.head ~project
    |> Result.map (fun saved -> Saved (status_of_project saved.Store.project))
    |> Result.map_error (fun error -> Store_error error)

let restore ~root ~checkpoint ~destination =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  if
    not
      (List.exists
         (fun candidate ->
           Model.Snapshot_id.equal candidate.Model.checkpoint_snapshot
             checkpoint)
         (Model.checkpoints loaded.Store.project))
  then Error (Unknown_checkpoint checkpoint)
  else
    let checkpoint_text = Model.Snapshot_id.to_string checkpoint in
    let* object_id =
      Yeokcham_store.Stored_object_id.of_hex checkpoint_text
      |> Result.map_error (fun _ -> Invalid_checkpoint_id checkpoint_text)
    in
    let* snapshot =
      Snapshot.Snapshot.load
        (Store.underlying_store repository)
        (Snapshot.Snapshot.of_stored_object_id object_id)
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    Snapshot.Materialize.write ~destination
      (Store.underlying_store repository)
      snapshot
    |> Result.map_error (fun error -> Materialize_error error)

let new_draft ~root ~id ~title =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  let* project =
    Model.new_draft loaded.Store.project ~id ~title
    |> Result.map_error (fun error -> Model_error error)
  in
  Store.save repository ~expected:loaded.Store.head ~project
  |> Result.map (fun saved -> status_of_project saved.Store.project)
  |> Result.map_error (fun error -> Store_error error)
