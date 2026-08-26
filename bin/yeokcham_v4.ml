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
    \  yeokcham-v4 draft new [--root PATH] --id ID --title TITLE"

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
  Printf.printf "needs-decision %d\n"
    (List.length status.Service.open_decisions);
  Printf.printf "delivered %d\n" status.Service.delivery_count

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

let run_new_draft arguments =
  let root, id, title = parse_new_draft arguments in
  let id =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string id
  in
  Service.new_draft ~root ~id ~title
  |> require_ok Service.error_to_string
  |> render_status

let () =
  match Array.to_list Sys.argv with
  | _ :: "init" :: arguments -> run_init arguments
  | _ :: "save" :: arguments -> run_save arguments
  | _ :: "status" :: arguments -> run_status arguments
  | _ :: "draft" :: "new" :: arguments -> run_new_draft arguments
  | _ -> usage ()
