module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service

let fail message =
  prerr_endline message;
  exit 2

let usage () =
  fail
    "usage:\n\
    \  yeokcham-v4 init [--root PATH] --device ID --draft ID --title TITLE\n\
    \  yeokcham-v4 save [--root PATH]\n\
    \  yeokcham-v4 status [--root PATH]\n\
    \  yeokcham-v4 timeline [--root PATH]\n\
    \  yeokcham-v4 restore [--root PATH] --checkpoint ID --destination PATH\n\
    \  yeokcham-v4 draft new [--root PATH] --id ID --title TITLE\n\
    \  yeokcham-v4 share [--root PATH] --change ID --revision ID\n\
    \  yeokcham-v4 withdraw [--root PATH] --change ID\n\
    \  yeokcham-v4 resolve [--root PATH] --decision ID --change ID --revision ID\n\
    \  yeokcham-v4 deliver [--root PATH] --id ID --draft ID --title TITLE"

let require_ok render = function
  | Ok value -> value
  | Error error -> fail (render error)

let default_root = Sys.getcwd ()

let parse_root = function
  | [] -> default_root
  | [ "--root"; root ] -> root
  | _ -> usage ()

let parse_identifier name parser value =
  parser value
  |> require_ok (fun error -> name ^ ": " ^ Model.error_to_string error)

let render_status status =
  Printf.printf "saved %s\n"
    (Model.Snapshot_id.to_string status.Service.checkpoint);
  Printf.printf "draft %s %s\n"
    (Model.Draft_id.to_string status.Service.active_draft.Model.draft_id)
    status.Service.active_draft.Model.title;
  Printf.printf "shared %d\n" status.Service.shared_change_count;
  List.iter
    (fun change ->
      Printf.printf "change %s\n"
        (Model.Change_id.to_string change.Model.change_id))
    status.Service.shared_changes;
  Printf.printf "needs-decision %d\n"
    (List.length status.Service.open_decisions);
  List.iter
    (fun decision ->
      Printf.printf "decision %s\n"
        (Model.Decision_id.to_string decision.Model.decision_id))
    status.Service.open_decisions;
  Printf.printf "delivered %d\n" status.Service.delivery_count;
  List.iter
    (fun delivery ->
      Printf.printf "delivery %s\n"
        (Model.Delivery_id.to_string delivery.Model.delivery_id))
    status.Service.deliveries

let parse_init arguments =
  let rec loop root creator draft title = function
    | [] -> (
        match (creator, draft, title) with
        | Some creator, Some draft, Some title ->
            (Option.value root ~default:default_root, creator, draft, title)
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) creator draft title rest
    | "--device" :: value :: rest when Option.is_none creator ->
        loop root (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root creator (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root creator draft (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_new_draft arguments =
  let rec loop root id title = function
    | [] -> (
        match (id, title) with
        | Some id, Some title ->
            (Option.value root ~default:default_root, id, title)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id title rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root id (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_restore arguments =
  let rec loop root checkpoint destination = function
    | [] -> (
        match (checkpoint, destination) with
        | Some checkpoint, Some destination ->
            (Option.value root ~default:default_root, checkpoint, destination)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) checkpoint destination rest
    | "--checkpoint" :: value :: rest when Option.is_none checkpoint ->
        loop root (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root checkpoint (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_init arguments =
  let root, creator, draft, title = parse_init arguments in
  let creator =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      creator
  in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  Service.init ~root ~creator ~initial_draft ~title
  |> require_ok Service.error_to_string
  |> render_status

let run_save arguments =
  let root = parse_root arguments in
  Service.save ~root |> require_ok Service.error_to_string |> function
  | Service.Unchanged status ->
      print_endline "save unchanged";
      render_status status
  | Service.Saved status ->
      print_endline "save recorded";
      render_status status

let run_status arguments =
  let root = parse_root arguments in
  Service.status ~root |> require_ok Service.error_to_string |> render_status

let run_timeline arguments =
  let root = parse_root arguments in
  Service.status ~root |> require_ok Service.error_to_string |> fun status ->
  List.iter
    (fun checkpoint ->
      Printf.printf "checkpoint %s\n"
        (Model.Snapshot_id.to_string checkpoint.Model.checkpoint_snapshot))
    status.Service.checkpoints

let run_restore arguments =
  let root, checkpoint, destination = parse_restore arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.restore ~root ~checkpoint ~destination
  |> require_ok Service.error_to_string;
  Printf.printf "restored %s to %s\n"
    (Model.Snapshot_id.to_string checkpoint)
    destination

let parse_share arguments =
  let rec loop root change revision = function
    | [] -> (
        match (change, revision) with
        | Some change, Some revision ->
            (Option.value root ~default:default_root, change, revision)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) change revision rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root (Some value) revision rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root change (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_withdraw arguments =
  let rec loop root change = function
    | [] -> (
        match change with
        | Some change -> (Option.value root ~default:default_root, change)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) change rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_resolve arguments =
  let rec loop root decision change revision = function
    | [] -> (
        match (decision, change, revision) with
        | Some decision, Some change, Some revision ->
            (Option.value root ~default:default_root, decision, change, revision)
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision change revision rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) change revision rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root decision (Some value) revision rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root decision change (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_deliver arguments =
  let rec loop root id draft title = function
    | [] -> (
        match (id, draft, title) with
        | Some id, Some draft, Some title ->
            (Option.value root ~default:default_root, id, draft, title)
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id draft title rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root id (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root id draft (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_new_draft arguments =
  let root, id, title = parse_new_draft arguments in
  let id =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string id
  in
  Service.new_draft ~root ~id ~title
  |> require_ok Service.error_to_string
  |> render_status

let run_share arguments =
  let root, change, revision = parse_share arguments in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  Service.share ~root ~change ~revision
  |> require_ok Service.error_to_string
  |> render_status

let run_withdraw arguments =
  let root, change = parse_withdraw arguments in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  Service.withdraw ~root ~change
  |> require_ok Service.error_to_string
  |> render_status

let run_resolve arguments =
  let root, decision, change, revision = parse_resolve arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  Service.resolve ~root ~decision ~change ~revision
  |> require_ok Service.error_to_string
  |> render_status

let run_deliver arguments =
  let root, id, draft, title = parse_deliver arguments in
  let id =
    parse_identifier "invalid delivery identifier" Model.Delivery_id.of_string
      id
  in
  let next_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  Service.deliver ~root ~id ~next_draft ~next_title:title
  |> require_ok Service.error_to_string
  |> render_status

let () =
  match Array.to_list Sys.argv with
  | _ :: "init" :: arguments -> run_init arguments
  | _ :: "save" :: arguments -> run_save arguments
  | _ :: "status" :: arguments -> run_status arguments
  | _ :: "timeline" :: arguments -> run_timeline arguments
  | _ :: "restore" :: arguments -> run_restore arguments
  | _ :: "draft" :: "new" :: arguments -> run_new_draft arguments
  | _ :: "share" :: arguments -> run_share arguments
  | _ :: "withdraw" :: arguments -> run_withdraw arguments
  | _ :: "resolve" :: arguments -> run_resolve arguments
  | _ :: "deliver" :: arguments -> run_deliver arguments
  | _ -> usage ()
