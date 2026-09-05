(** One complete, explicit WS-001 measurement journey.

    The source fixture is scanned only by the authorised source initialisation.
    Bootstrap writes local V4 metadata only; this executable refuses to call
    workspace activation until it has observed that no ordinary source entry is
    present at the target. *)

module Bootstrap = Yeokcham_v4_bootstrap
module Model = Yeokcham_v4_model
module Package = Yeokcham_v4_package
module Recovery = Yeokcham_v4_recovery
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_v4_store
module Trust = Yeokcham_v4_trust

let fail message =
  prerr_endline ("evidence-workspace-scenario: " ^ message);
  exit 2

let require_ok render = function
  | Ok value -> value
  | Error error -> fail (render error)

let require_absolute label path =
  if String.length path = 0 || not (Char.equal path.[0] '/') then
    fail (label ^ " must be absolute")

let require_empty_directory label path =
  try
    if (Unix.lstat path).Unix.st_kind <> Unix.S_DIR then
      fail (label ^ " is not a directory")
    else if Array.length (Sys.readdir path) <> 0 then
      fail (label ^ " is not empty")
  with Unix.Unix_error (error, _, _) ->
    fail (label ^ " is unavailable: " ^ Unix.error_message error)

let require_directory label path =
  try
    if (Unix.lstat path).Unix.st_kind <> Unix.S_DIR then
      fail (label ^ " is not a directory")
  with Unix.Unix_error (error, _, _) ->
    fail (label ^ " is unavailable: " ^ Unix.error_message error)

let elapsed operation =
  let started = Unix.gettimeofday () in
  let value = operation () in
  (value, Unix.gettimeofday () -. started)

let report_phase phase =
  Printf.eprintf "evidence-workspace-scenario: phase=%s\n%!" phase

let device capability =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let root_certificate authority =
  Trust.certificates (Trust.authority_membership authority)
  |> List.find (fun certificate -> Trust.certificate_issuer certificate = None)

let parse_arguments () =
  let source = ref None in
  let target = ref None in
  let package = ref None in
  let specification =
    [
      ( "--source",
        Arg.String (fun value -> source := Some value),
        "absolute generated fixture directory" );
      ( "--target",
        Arg.String (fun value -> target := Some value),
        "absolute empty workspace directory" );
      ( "--package",
        Arg.String (fun value -> package := Some value),
        "absolute absent temporary bootstrap package directory" );
    ]
  in
  Arg.parse specification
    (fun argument -> fail ("unexpected argument " ^ argument))
    "evidence_workspace_scenario --source ROOT --target ROOT --package \
     DIRECTORY";
  let require option = function
    | Some value -> value
    | None -> fail (option ^ " is required")
  in
  ( require "--source" !source,
    require "--target" !target,
    require "--package" !package )

let () =
  let source, target, package = parse_arguments () in
  require_absolute "--source" source;
  require_absolute "--target" target;
  require_absolute "--package" package;
  require_directory "--source" source;
  require_empty_directory "--target" target;
  if Sys.file_exists package then fail "--package already exists";
  let administrator_capability =
    String.make 32 'a' |> Trust.signing_capability_of_private_key
    |> require_ok Trust.error_to_string
  in
  let administrator = device administrator_capability in
  let recovery_capability =
    String.make 32 'r' |> Trust.signing_capability_of_private_key
    |> require_ok Trust.error_to_string
  in
  let recovery_device = device recovery_capability in
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> require_ok Fun.id
  in
  let username =
    Model.Username.of_string "evidence-admin"
    |> require_ok Model.error_to_string
  in
  let initial_draft =
    Model.Draft_id.of_string "evidence-source"
    |> require_ok Model.error_to_string
  in
  report_phase "source-init:start";
  let (source_status, _), source_init_seconds =
    elapsed (fun () ->
        Service.init_signed_with_recovery ~root:source ~username ~initial_draft
          ~title:"EVIDENCE-001 source" ~repository ~device:administrator
          ~signing_capability:administrator_capability ~recovery_device
          ~recovery_capability
        |> require_ok Service.error_to_string)
  in
  report_phase "source-init:complete";
  let source_repository =
    Store.open_repository ~root:source |> require_ok Store.error_to_string
  in
  let source_state =
    Store.load source_repository |> require_ok Store.error_to_string
  in
  let collaboration =
    match source_state.Store.collaboration with
    | Some value -> value
    | None -> fail "source initialisation did not create collaboration state"
  in
  let authority =
    match Store.authority collaboration with
    | Some value -> value
    | None -> fail "source initialisation did not create authority state"
  in
  let local_certificate = Store.local_certificate collaboration in
  report_phase "bootstrap-prepare:start";
  let outbound, package_seconds =
    elapsed (fun () ->
        Service.prepare_bootstrap_outbound ~root:source
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string)
  in
  report_phase "bootstrap-prepare:complete";
  report_phase "package-materialize:start";
  let _, materialize_package_seconds =
    Fun.protect
      ~finally:(fun () ->
        Package.dispose_artifact outbound.Service.bootstrap_artifact)
      (fun () ->
        elapsed (fun () ->
            Package.materialize_artifact ~destination:package
              outbound.Service.bootstrap_artifact
            |> require_ok Package.error_to_string))
  in
  report_phase "package-materialize:complete";
  let basis = Bootstrap.encode outbound.Service.bootstrap_basis in
  let phrase = Recovery.verification_phrase (root_certificate authority) in
  report_phase "bootstrap:start";
  let _, bootstrap_seconds =
    elapsed (fun () ->
        Service.bootstrap_from_package ~root:target ~repository ~package ~basis
          ~verify_phrase:phrase
          ~username:
            (Model.Username.of_string "evidence-target"
            |> require_ok Model.error_to_string)
          ~initial_draft:
            (Model.Draft_id.of_string "evidence-target"
            |> require_ok Model.error_to_string)
          ~title:"EVIDENCE-001 target" ~device:administrator ~local_certificate
        |> require_ok Service.error_to_string)
  in
  report_phase "bootstrap:complete";
  let source_entries =
    Sys.readdir target |> Array.to_list
    |> List.filter (fun name -> not (String.equal name ".yeokcham"))
  in
  if source_entries <> [] then
    fail "bootstrap materialised ordinary source before workspace activation";
  report_phase "workspace-activate:start";
  let _, workspace_activate_seconds =
    elapsed (fun () ->
        Service.workspace_activate ~root:target
        |> require_ok Service.error_to_string)
  in
  report_phase "workspace-activate:complete";
  if not (Sys.file_exists (Filename.concat target ".yeokcham")) then
    fail "workspace activation lost target V4 metadata";
  Printf.printf
    "schema_version=1\n\
     source_checkpoint=%s\n\
     source_init_seconds=%.6f\n\
     bootstrap_prepare_seconds=%.6f\n\
     package_materialize_seconds=%.6f\n\
     bootstrap_seconds=%.6f\n\
     workspace_activate_seconds=%.6f\n"
    (Model.Snapshot_id.to_string source_status.Service.checkpoint)
    source_init_seconds package_seconds materialize_package_seconds
    bootstrap_seconds workspace_activate_seconds
