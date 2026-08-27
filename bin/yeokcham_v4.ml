module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service

let fail message =
  prerr_endline message;
  exit 2

let usage () =
  fail
    "usage:\n\
    \  yeokcham-v4 init [--root PATH] --device ID --username NAME --draft ID \
     --title TITLE\n\
    \  yeokcham-v4 save [--root PATH]\n\
    \  yeokcham-v4 status [--root PATH]\n\
    \  yeokcham-v4 user register [--root PATH] --device ID --username NAME\n\
    \  yeokcham-v4 timeline [--root PATH]\n\
    \  yeokcham-v4 restore [--root PATH] --checkpoint ID [--destination PATH]\n\
    \  yeokcham-v4 draft new [--root PATH] --id ID --title TITLE\n\
    \  yeokcham-v4 share [--root PATH] --change ID --revision ID\n\
    \  yeokcham-v4 withdraw [--root PATH] --change ID\n\
    \  yeokcham-v4 resolve [--root PATH] --decision ID --change ID --revision \
     ID [--tree PATH]\n\
    \  yeokcham-v4 decision show [--root PATH] --decision ID\n\
    \  yeokcham-v4 decision inspect [--root PATH] --decision ID\n\
    \  yeokcham-v4 decision diff [--root PATH] --decision ID --candidate REV \
     [--against base|REV]\n\
    \  yeokcham-v4 decision materialize [--root PATH] --decision ID \
     --destination PATH\n\
    \  yeokcham-v4 deliver [--root PATH] --id ID --draft ID --title TITLE\n\
    \  yeokcham-v4 pin [--root PATH] --checkpoint ID\n\
    \  yeokcham-v4 unpin [--root PATH] --checkpoint ID\n\
    \  yeokcham-v4 compact [--root PATH] [--keep N] [--dry-run] [--explain]\n\
    \  yeokcham-v4 watch [--root PATH]"

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
    status.Service.deliveries;
  Printf.printf "users %d\n" (List.length status.Service.usernames);
  status.Service.usernames
  |> List.sort (fun left right ->
      Model.Device_id.compare left.Model.username_device
        right.Model.username_device)
  |> List.iter (fun registration ->
      Printf.printf "user %s %s\n"
        (Model.Device_id.to_string registration.Model.username_device)
        (Model.Username.to_string registration.Model.username));
  print_endline "capture command";
  Printf.printf "uncaptured %s\n"
    (if status.Service.uncaptured then "yes" else "no")

let parse_init arguments =
  let rec loop root creator username draft title = function
    | [] -> (
        match (creator, username, draft, title) with
        | Some creator, Some username, Some draft, Some title ->
            ( Option.value root ~default:default_root,
              creator,
              username,
              draft,
              title )
        | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None ->
            usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) creator username draft title rest
    | "--device" :: value :: rest when Option.is_none creator ->
        loop root (Some value) username draft title rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root creator (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root creator username (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root creator username draft (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None arguments

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
        match checkpoint with
        | Some checkpoint ->
            (Option.value root ~default:default_root, checkpoint, destination)
        | None -> usage ())
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
  let root, creator, username, draft, title = parse_init arguments in
  let creator =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      creator
  in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  Service.init ~root ~creator ~username ~initial_draft ~title
  |> require_ok Service.error_to_string
  |> render_status

let parse_user_register arguments =
  let rec loop root device username = function
    | [] -> (
        match (device, username) with
        | Some device, Some username ->
            (Option.value root ~default:default_root, device, username)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device username rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) username rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root device (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_user_register arguments =
  let root, device, username = parse_user_register arguments in
  let device =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  Service.register_username ~root ~device ~username
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
  match destination with
  | Some destination ->
      Service.restore ~root ~checkpoint ~destination
      |> require_ok Service.error_to_string;
      Printf.printf "restored %s to %s\n"
        (Model.Snapshot_id.to_string checkpoint)
        destination
  | None ->
      let restored =
        Service.restore_in_place ~root ~checkpoint
        |> require_ok Service.error_to_string
      in
      Printf.printf "safety %s\n"
        (Model.Snapshot_id.to_string restored.Service.safety_checkpoint);
      Printf.printf "restored %s in-place%s\n"
        (Model.Snapshot_id.to_string restored.Service.restored_checkpoint)
        (if restored.Service.resumed then " (resumed)" else "")

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
  let rec loop root decision change revision tree = function
    | [] -> (
        match (decision, change, revision) with
        | Some decision, Some change, Some revision ->
            ( Option.value root ~default:default_root,
              decision,
              change,
              revision,
              tree )
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision change revision tree rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) change revision tree rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root decision (Some value) revision tree rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root decision change (Some value) tree rest
    | "--tree" :: value :: rest when Option.is_none tree ->
        loop root decision change revision (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None arguments

let parse_decision_show arguments =
  let rec loop root decision = function
    | [] -> (
        match decision with
        | Some decision -> (Option.value root ~default:default_root, decision)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_decision_materialize arguments =
  let rec loop root decision destination = function
    | [] -> (
        match (decision, destination) with
        | Some decision, Some destination ->
            (Option.value root ~default:default_root, decision, destination)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision destination rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root decision (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_decision_diff arguments =
  let rec loop root decision candidate against = function
    | [] -> (
        match (decision, candidate) with
        | Some decision, Some candidate ->
            ( Option.value root ~default:default_root,
              decision,
              candidate,
              Option.value against ~default:"base" )
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision candidate against rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) candidate against rest
    | "--candidate" :: value :: rest when Option.is_none candidate ->
        loop root decision (Some value) against rest
    | "--against" :: value :: rest when Option.is_none against ->
        loop root decision candidate (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let decision_kind_name = function
  | Model.Stale_base -> "stale-base"
  | Model.Edit_overlap -> "edit-overlap"

let edit_kind_name = function
  | Model.Whole_path -> "whole-path"
  | Model.Text span ->
      Printf.sprintf "text:%d-%d" span.Model.start_byte span.Model.end_byte

let render_decision (inspection : Service.decision_inspection) =
  let decision = inspection.Service.inspected_decision in
  Printf.printf "decision %s\n"
    (Model.Decision_id.to_string decision.Model.decision_id);
  Printf.printf "kind %s\n" (decision_kind_name decision.Model.decision_kind);
  List.iter
    (fun path -> Printf.printf "path %s\n" (Model.Path.to_string path))
    decision.Model.decision_paths;
  List.iter
    (fun candidate ->
      let revision = candidate.Service.inspected_revision in
      let username =
        match candidate.Service.inspected_username with
        | None -> "unregistered"
        | Some username -> Model.Username.to_string username
      in
      Printf.printf
        "candidate %s change %s author %s username %s base %s snapshot %s\n"
        (Model.Revision_id.to_string revision.Model.revision)
        (Model.Change_id.to_string revision.Model.change)
        (Model.Device_id.to_string revision.Model.revision_author)
        username
        (Model.Snapshot_id.to_string revision.Model.base_snapshot)
        (Model.Snapshot_id.to_string revision.Model.result_snapshot))
    inspection.Service.inspected_candidates;
  List.iter
    (fun candidate ->
      let revision = candidate.Model.candidate_revision in
      Printf.printf "edit %s %d %s %s\n"
        (Model.Revision_id.to_string revision.Model.revision)
        candidate.Model.candidate_edit_index
        (Model.Path.to_string candidate.Model.candidate_edit.Model.edit_path)
        (edit_kind_name candidate.Model.candidate_edit.Model.edit_kind))
    decision.Model.candidates

let run_decision_show arguments =
  let root, decision = parse_decision_show arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  Service.inspect_decision ~root ~decision
  |> require_ok Service.error_to_string
  |> render_decision

let snapshot_entry_kind_name = function
  | Service.File -> "file"
  | Service.Directory -> "directory"

let snapshot_mode_name = function
  | Yeokcham_snapshot.Regular -> "regular"
  | Yeokcham_snapshot.Executable -> "executable"
  | Yeokcham_snapshot.Symlink -> "symlink"

let render_snapshot_entry = function
  | None -> "missing"
  | Some entry -> (
      let kind = snapshot_entry_kind_name entry.Service.kind in
      let mode = Option.map snapshot_mode_name entry.Service.mode in
      match (mode, entry.Service.content) with
      | None, None -> kind
      | Some mode, Some content -> kind ^ " " ^ mode ^ " " ^ content
      | Some mode, None -> kind ^ " " ^ mode
      | None, Some content -> kind ^ " " ^ content)

let run_decision_diff arguments =
  let root, decision, candidate, against = parse_decision_diff arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let candidate =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      candidate
  in
  let against =
    if String.equal against "base" then Service.Baseline
    else
      Service.Candidate
        (parse_identifier "invalid revision identifier"
           Model.Revision_id.of_string against)
  in
  let comparison =
    Service.compare_decision ~root ~decision ~candidate ~against
    |> require_ok Service.error_to_string
  in
  Printf.printf "decision %s\n"
    (Model.Decision_id.to_string
       comparison.Service.compared_decision.Model.decision_id);
  Printf.printf "candidate %s\n"
    (Model.Revision_id.to_string
       comparison.Service.compared_candidate.Model.revision);
  Printf.printf "against %s\n"
    (Model.Snapshot_id.to_string comparison.Service.against);
  List.iter
    (fun difference ->
      Printf.printf "diff %s before %s after %s\n"
        (Model.Path.to_string difference.Service.path)
        (render_snapshot_entry difference.Service.before)
        (render_snapshot_entry difference.Service.after))
    comparison.Service.differences

let run_decision_materialize arguments =
  let root, decision, destination = parse_decision_materialize arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let candidates =
    Service.materialize_decision ~root ~decision ~destination
    |> require_ok Service.error_to_string
  in
  List.iter
    (fun candidate ->
      let username =
        match candidate.Service.username with
        | Some username -> Model.Username.to_string username
        | None -> "unregistered"
      in
      Printf.printf "materialized %s author %s username %s tree %s\n"
        (Model.Revision_id.to_string candidate.Service.revision)
        (Model.Device_id.to_string candidate.Service.author)
        username candidate.Service.directory)
    candidates

let run_resolve arguments =
  let root, decision, change, revision, tree = parse_resolve arguments in
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
  Service.resolve ~root ~decision ~change ~revision ~tree
  |> require_ok Service.error_to_string
  |> render_status

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

let parse_pin arguments =
  let rec loop root checkpoint = function
    | [] -> (
        match checkpoint with
        | Some checkpoint ->
            (Option.value root ~default:default_root, checkpoint)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) checkpoint rest
    | "--checkpoint" :: value :: rest when Option.is_none checkpoint ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_compact arguments =
  let rec loop root keep dry_run explain = function
    | [] -> (Option.value root ~default:default_root, keep, dry_run, explain)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) keep dry_run explain rest
    | "--keep" :: value :: rest when Option.is_none keep -> (
        match int_of_string_opt value with
        | Some parsed when parsed >= 0 ->
            loop root (Some parsed) dry_run explain rest
        | Some _ | None -> usage ())
    | "--dry-run" :: rest when not dry_run -> loop root keep true explain rest
    | "--explain" :: rest when not explain -> loop root keep dry_run true rest
    | _ -> usage ()
  in
  loop None None false false arguments

let run_pin arguments =
  let root, checkpoint = parse_pin arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.pin ~root ~checkpoint
  |> require_ok Service.error_to_string
  |> render_status

let run_unpin arguments =
  let root, checkpoint = parse_pin arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.unpin ~root ~checkpoint
  |> require_ok Service.error_to_string
  |> render_status

let render_compact report explain =
  if explain then (
    List.iter
      (fun keep ->
        Printf.printf "keep %s %s\n"
          (Model.Snapshot_id.to_string keep.Model.snapshot)
          (keep.Model.reasons
          |> List.map Model.protection_reason_to_string
          |> String.concat ","))
      report.Service.kept;
    List.iter
      (fun snapshot ->
        Printf.printf "drop %s\n" (Model.Snapshot_id.to_string snapshot))
      report.Service.dropped;
    List.iter
      (fun operation -> Printf.printf "journal-prune %s\n" operation)
      report.Service.pruned_journals);
  Printf.printf "kept %d\n" (List.length report.Service.kept);
  Printf.printf "dropped %d\n" (List.length report.Service.dropped);
  render_status report.Service.status

let run_compact arguments =
  let root, keep, dry_run, explain = parse_compact arguments in
  let keep_recent = Option.value keep ~default:Model.default_keep_recent in
  Service.compact ~root ~keep_recent ~dry_run
  |> require_ok Service.error_to_string
  |> fun report -> render_compact report explain

let run_watch arguments =
  let root = parse_root arguments in
  V4_watch.run ~root

let () =
  match Array.to_list Sys.argv with
  | _ :: "init" :: arguments -> run_init arguments
  | _ :: "save" :: arguments -> run_save arguments
  | _ :: "status" :: arguments -> run_status arguments
  | _ :: "user" :: "register" :: arguments -> run_user_register arguments
  | _ :: "timeline" :: arguments -> run_timeline arguments
  | _ :: "restore" :: arguments -> run_restore arguments
  | _ :: "draft" :: "new" :: arguments -> run_new_draft arguments
  | _ :: "share" :: arguments -> run_share arguments
  | _ :: "withdraw" :: arguments -> run_withdraw arguments
  | _ :: "resolve" :: arguments -> run_resolve arguments
  | _ :: "decision" :: "show" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "inspect" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "diff" :: arguments -> run_decision_diff arguments
  | _ :: "decision" :: "materialize" :: arguments ->
      run_decision_materialize arguments
  | _ :: "deliver" :: arguments -> run_deliver arguments
  | _ :: "pin" :: arguments -> run_pin arguments
  | _ :: "unpin" :: arguments -> run_unpin arguments
  | _ :: "compact" :: arguments -> run_compact arguments
  | _ :: "watch" :: arguments -> run_watch arguments
  | _ -> usage ()
