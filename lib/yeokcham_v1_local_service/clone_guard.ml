module Store = Yeokcham_v1_store
module Core = Yeokcham_v1_model.Core
module Clone = Yeokcham_v1_transport.Core_clone

[@@@warning "-42"]

let ( let* ) = Result.bind

let intent loaded =
  Option.bind loaded.Store.collaboration (fun collaboration ->
      Clone.find (Store.transport collaboration))

let recovered loaded intent =
  match
    Option.bind loaded.Store.local (fun local ->
        Option.bind (Clone.plan intent) (fun plan ->
            Store.Local.find_operation local ~plan))
  with
  | None -> false
  | Some operation -> Store.Local.Operation.recovered operation

let pending loaded =
  Option.exists
    (fun clone -> (not (Clone.complete clone)) && not (recovered loaded clone))
    (intent loaded)

let require_normal loaded =
  if pending loaded then
    Error
      "clone is incomplete; resume this workspace with clone --resume DIRECTORY"
  else Ok ()

let check_plan loaded plan =
  if
    pending loaded
    && not
         (Option.exists
            (fun clone -> Clone.plan clone = Some plan)
            (intent loaded))
  then Error "clone is incomplete; only its recorded application plan may run"
  else Ok ()

let check_preparation loaded request =
  let* clone =
    intent loaded
    |> Option.to_result ~none:"workspace has no durable clone intent"
  in
  let* id =
    Clone.id clone |> Result.map_error Yeokcham_v1_transport.error_to_string
  in
  if
    id <> Core.Digest.to_hex request
    || Clone.complete clone || recovered loaded clone
  then
    Error
      "clone request is complete, recovered, or does not match this workspace"
  else
    let* local =
      loaded.Store.local
      |> Option.to_result ~none:"clone lacks local branch state"
    in
    let selected = Store.Local.selected local in
    let* branch =
      List.find_opt
        (fun branch ->
          Core.Branch_id.equal branch.Core.branch_id (Clone.branch clone))
        (Store.Local.branches local)
      |> Option.to_result ~none:"clone branch is unavailable"
    in
    if
      (not
         (Core.Branch_id.equal selected.Store.Local.branch (Clone.branch clone)))
      || branch.Core.accepted_heads <> [ Clone.accepted clone ]
      || branch.Core.event_heads <> Clone.events clone
    then
      Error
        "clone shared heads changed before application; its frozen version \
         cannot be retargeted implicitly"
    else Ok ()
