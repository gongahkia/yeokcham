module Model = Yeokcham_v4_model
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_v4_store

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Model_error of Model.error

type save_outcome = Unchanged of status | Saved of status

and status = {
  active_draft : Model.draft;
  checkpoint : Model.Snapshot_id.t;
  shared_change_count : int;
  open_decisions : Model.decision list;
  delivery_count : int;
}

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Model_error error -> Model.error_to_string error

let ( let* ) = Result.bind

let snapshot_id identity =
  identity |> Snapshot.Snapshot.stored_object_id
  |> Yeokcham_store.Stored_object_id.to_hex |> Model.Snapshot_id.of_string
  |> Result.map_error (fun error -> Model_error error)

let capture ~root store =
  let* identity, _ =
    Snapshot.scan ~root ~store
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
