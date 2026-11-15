(* test-only process exits at actual service boundaries; never installed. *)
module S = Yeokcham_v1_store
module L = S.Local
module C = Yeokcham_v1_model.Core
module T = Yeokcham_v1_trust
module I = Yeokcham_v1_local_service.Integrate
module Snapshot = Yeokcham_snapshot
module Composition = Yeokcham_v1_composition

[@@@warning "-42"]

let ok render = function
  | Ok value -> value
  | Error error ->
      prerr_endline (render error);
      exit 2

let fixture () =
  if Sys.getenv_opt "YEOKCHAM_V1_TEST_SIGNER_DIRECTORY" = None then (
    prerr_endline "explicit disposable test signer required";
    exit 2)

let stop root selected seen =
  if selected = seen then (
    let repository = S.open_repository ~root |> ok S.error_to_string in
    let loaded = S.load repository |> ok S.error_to_string in
    let operation = L.operations (Option.get loaded.S.local) |> List.hd in
    Printf.printf "%s %s\n%!"
      (C.Operation_id.to_hex operation.L.Operation.token)
      (C.Plan_id.to_hex operation.L.Operation.plan);
    Unix._exit 73)

let boundary recovery = function
  | "prepared" -> if recovery then I.Recovery_prepared_root else I.Prepared_root
  | "materialized" ->
      if recovery then I.Recovery_materialized_root else I.Materialized_root
  | "committed" ->
      if recovery then I.Recovery_committed_root else I.Committed_root
  | "after-file" ->
      if recovery then
        I.Recovery_mutation (Yeokcham_v1_local_service.Safe_apply.After_sync, [])
      else I.Mutation (Yeokcham_v1_local_service.Safe_apply.After_sync, [])
  | _ -> exit 2

let[@warning "-4"] observe root selected seen =
  match (selected, seen) with
  | I.Mutation (a, _), I.Mutation (b, _) when a = b ->
      stop root selected selected
  | I.Recovery_mutation (a, _), I.Recovery_mutation (b, _) when a = b ->
      stop root selected selected
  | _ -> stop root selected seen

let start root selected =
  let repository = S.open_repository ~root |> ok S.error_to_string in
  let loaded = S.load repository |> ok S.error_to_string in
  let local = Option.get loaded.S.local in
  let collaboration = Option.get loaded.S.collaboration in
  let authority = Option.get (S.authority collaboration) in
  let certificate = S.local_certificate collaboration in
  let member =
    T.certificates (S.membership collaboration)
    |> List.find (fun member -> T.certificate_id member = certificate)
  in
  let device = T.certificate_subject member in
  let directory = Sys.getenv "YEOKCHAM_V1_TEST_SIGNER_DIRECTORY" in
  let key_path =
    Filename.concat directory
      (Yeokcham_v1_model.Device_id.to_string (T.device_id device))
  in
  let private_bytes =
    Yeokcham_store.read_file_bounded ~path:key_path ~max_bytes:32
    |> ok Yeokcham_store.error_to_string
  in
  let signer =
    T.signing_capability_of_private_key private_bytes |> ok T.error_to_string
  in
  if T.signing_public_key signer <> T.device_public_key device then exit 2;
  let store = S.underlying_store repository in
  let content =
    Snapshot.Content.store store "received shared D\n"
    |> ok Snapshot.error_to_string
  in
  let result =
    Composition.tree
      [
        ( [ "incoming.txt" ],
          Composition.File { mode = Snapshot.Regular; content } );
      ]
    |> ok Composition.error_to_string
    |> Composition.store store
    |> ok Composition.error_to_string
  in
  let scope =
    Composition.Scope.store store [ [ "incoming.txt" ] ]
    |> ok Composition.error_to_string
  in
  let local, revision =
    L.prepare_revision ~store ~authority ~certificate ~signing_capability:signer
      ~change:None ~previous_revisions:[]
      ~base_snapshot:(L.empty_snapshot local) ~result_snapshot:result
      ~edit_scope_root:scope ~dependencies:[] local
    |> ok Fun.id
  in
  S.save_collaborative ~local repository ~expected:loaded.S.head
    ~project:loaded.S.project ~collaboration
  |> ok S.error_to_string |> ignore;
  let plan =
    I.prepare ~root ~selected_revisions:[ revision ] ~reconcile_heads:None
    |> ok I.error_to_string
  in
  I.For_test.apply ~observe:(observe root selected) ~root
    ~plan:(Yeokcham_v1_integration.id plan)
    ~signing_capability:(Some signer)
  |> ok I.error_to_string |> ignore

let () =
  fixture ();
  match Array.to_list Sys.argv with
  | [ _; "start"; root; stage ] -> start root (boundary false stage)
  | [ _; "recover"; root; token; stage ] ->
      let operation = C.Operation_id.of_hex token |> ok C.error_to_string in
      I.For_test.recover
        ~observe:(observe root (boundary true stage))
        ~root ~operation ~dry_run:false ~mode:None ~replan:false
        ~expected_plan:None
      |> ok I.error_to_string |> ignore
  | _ -> exit 2
