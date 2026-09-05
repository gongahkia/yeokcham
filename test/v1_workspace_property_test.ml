module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust
module Workspace = Yeokcham_v1_workspace
module Bootstrap = Yeokcham_v1_bootstrap
module Package = Yeokcham_v1_package
module Recovery = Yeokcham_v1_recovery
module Service = Yeokcham_v1_local_service
module Store = Yeokcham_v1_store

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let identifier character = String.make 64 character
let snapshot value = Model.Snapshot_id.of_string value |> Result.get_ok

let basis tree =
  Workspace.make_projection_basis ~repository
    ~imported_basis_id:(identifier 'a')
    ~snapshot:(snapshot "snapshot-projected")
    ~canonical_tree:tree ~source_fingerprint:tree
  |> Result.get_ok

let activated tree =
  Workspace.activate
    ~basis:(Some (basis tree))
    ~closure:Workspace.Closure_complete ~destination:Workspace.Destination_empty
  |> Result.get_ok

let observed tree =
  Workspace.make_observed_tree ~canonical_tree:tree ~source_fingerprint:tree
  |> Result.get_ok

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_directory prefix run =
  let directory = Filename.temp_file prefix "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree directory)
    (fun () -> run directory)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let read_file root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> Result.get_ok

let device capability =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key |> Result.get_ok

let username value = Model.Username.of_string value |> Result.get_ok
let draft value = Model.Draft_id.of_string value |> Result.get_ok

let root_certificate authority =
  Trust.certificates (Trust.authority_membership authority)
  |> List.find (fun certificate -> Trust.certificate_issuer certificate = None)

let bootstrap_into_empty_root ~populate run =
  with_directory "v1-workspace-property-" (fun parent ->
      let source = Filename.concat parent "source" in
      let target = Filename.concat parent "target" in
      let package = Filename.concat parent "package" in
      Unix.mkdir source 0o700;
      Unix.mkdir target 0o700;
      populate source;
      let administrator_capability = capability 'a' in
      let administrator = device administrator_capability in
      let recovery_capability = capability 'r' in
      let recovery_device = device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root:source
           ~username:(username "alice") ~initial_draft:(draft "source-draft")
           ~title:"source" ~repository ~device:administrator
           ~signing_capability:administrator_capability ~recovery_device
           ~recovery_capability
        |> Result.get_ok);
      let outbound =
        Service.prepare_bootstrap_outbound ~root:source
          ~signing_capability:administrator_capability
        |> Result.get_ok
      in
      Package.materialize_artifact ~destination:package
        outbound.Service.bootstrap_artifact
      |> Result.get_ok;
      let source_repository =
        Store.open_repository ~root:source |> Result.get_ok
      in
      let source_state = Store.load source_repository |> Result.get_ok in
      let authority =
        match source_state.Store.collaboration with
        | Some collaboration -> Store.authority collaboration |> Option.get
        | None -> failwith "source lacks authority"
      in
      let certificate = root_certificate authority |> Trust.certificate_id in
      ignore
        (Service.bootstrap_from_package ~root:target ~repository ~package
           ~basis:(Bootstrap.encode outbound.Service.bootstrap_basis)
           ~verify_phrase:
             (Recovery.verification_phrase (root_certificate authority))
           ~username:(username "alice") ~initial_draft:(draft "target-draft")
           ~title:"target" ~device:administrator ~local_certificate:certificate
        |> Result.get_ok);
      run target)

let update_never_discards_a_dirty_tree_without_replace =
  QCheck2.Test.make ~count:300
    ~name:
      "V1 workspace update only plans dirty replacement after explicit \
       --replace"
    QCheck2.Gen.(pair (int_range 0 3) bool)
    (fun (tree_selector, replace) ->
      let projected = identifier 'b' in
      let current =
        match tree_selector with
        | 0 -> projected
        | 1 -> identifier 'c'
        | 2 -> identifier 'd'
        | _ -> identifier 'e'
      in
      let basis = basis projected in
      let receipt = Workspace.plan_receipt (activated projected) in
      match
        Workspace.plan_update ~basis:(Some basis) ~receipt:(Some receipt)
          ~closure:Workspace.Closure_complete ~observed:(observed current)
          ~replace
      with
      | Error Workspace.Dirty_workspace ->
          (not replace) && not (String.equal current projected)
      | Ok (Workspace.Already_current _) -> String.equal current projected
      | Ok (Workspace.Update plan) ->
          replace
          && (not (String.equal current projected))
          && Workspace.plan_requires_safety_checkpoint plan
      | Error
          ( Workspace.Missing_closure | Workspace.No_verified_basis
          | Workspace.Receipt_mismatch | Workspace.Unsafe_path
          | Workspace.Nonempty_destination ) ->
          false)

let receipt_generation_is_monotonic_for_verified_projection_updates =
  QCheck2.Test.make ~count:300
    ~name:
      "V1 workspace receipt generations increase exactly once per projected \
       tree update"
    QCheck2.Gen.(int_range 0 3)
    (fun selector ->
      let initial_tree = identifier 'b' in
      let next_tree = identifier (Char.chr (Char.code 'c' + selector)) in
      let receipt = Workspace.plan_receipt (activated initial_tree) in
      let next_basis = basis next_tree in
      match
        Workspace.plan_update ~basis:(Some next_basis) ~receipt:(Some receipt)
          ~closure:Workspace.Closure_complete ~observed:(observed initial_tree)
          ~replace:false
      with
      | Ok (Workspace.Update plan) ->
          Int64.equal
            (Workspace.receipt_activation_generation
               (Workspace.plan_receipt plan))
            (Int64.succ (Workspace.receipt_activation_generation receipt))
      | Ok (Workspace.Already_current _) -> String.equal initial_tree next_tree
      | Error
          ( Workspace.Dirty_workspace | Workspace.Missing_closure
          | Workspace.No_verified_basis | Workspace.Receipt_mismatch
          | Workspace.Unsafe_path | Workspace.Nonempty_destination ) ->
          false)

let generated_exact_snapshots_activate_with_file_mode_and_symlink_fidelity =
  QCheck2.Test.make ~count:30
    ~name:
      "V1 workspace activation preserves generated exact file, mode, and \
       symlink entries"
    QCheck2.Gen.(triple (int_range 0 1_000_000) bool bool)
    (fun (seed, executable, link) ->
      try
        let contents = Printf.sprintf "generated-%d\n" seed in
        bootstrap_into_empty_root
          ~populate:(fun source ->
            write_file source "main.txt" contents;
            write_file source "run.sh" "#!/bin/sh\necho generated\n";
            if executable then
              Unix.chmod (Filename.concat source "run.sh") 0o755;
            if link then
              Unix.symlink "main.txt" (Filename.concat source "main-link"))
          (fun target ->
            let before =
              Store.open_repository ~root:target
              |> Result.get_ok |> Store.load |> Result.get_ok
            in
            match Service.workspace_activate ~root:target with
            | Error _ -> false
            | Ok _ -> (
                String.equal (read_file target "main.txt") contents
                && (if executable then
                      (Unix.lstat (Filename.concat target "run.sh"))
                        .Unix.st_perm land 0o111
                      <> 0
                    else
                      (Unix.lstat (Filename.concat target "run.sh"))
                        .Unix.st_perm land 0o111
                      = 0)
                &&
                if link then
                  String.equal
                    (Unix.readlink (Filename.concat target "main-link"))
                    "main.txt"
                else
                  (not (Sys.file_exists (Filename.concat target "main-link")))
                  &&
                  match
                    Service.workspace_update ~root:target ~replace:false
                  with
                  | Ok (Service.Workspace_already_current _) ->
                      let after =
                        Store.open_repository ~root:target
                        |> Result.get_ok |> Store.load |> Result.get_ok
                      in
                      Yeokcham_store.Stored_object_id.equal
                        before.Store.object_id after.Store.object_id
                  | Ok (Service.Workspace_updated _) | Error _ -> false))
      with _ -> false)

let empty_and_missing_projection_closures_do_not_materialize_source () =
  let empty =
    bootstrap_into_empty_root
      ~populate:(fun _ -> ())
      (fun target ->
        match Service.workspace_activate ~root:target with
        | Error _ -> false
        | Ok _ -> Sys.readdir target |> Array.to_list = [ ".yeokcham" ])
  in
  let missing =
    bootstrap_into_empty_root
      ~populate:(fun source -> write_file source "main.txt" "present\n")
      (fun target ->
        let basis =
          Workspace.read_basis ~root:target |> Result.get_ok |> Option.get
        in
        let snapshot =
          Model.Snapshot_id.to_string (Workspace.basis_snapshot basis)
        in
        let object_path =
          Filename.concat
            (Filename.concat
               (Filename.concat (Filename.concat target ".yeokcham") "objects")
               (String.sub snapshot 0 2))
            (Filename.concat (String.sub snapshot 2 2)
               (String.sub snapshot 4 60))
        in
        Unix.unlink object_path;
        Result.is_error (Service.workspace_activate ~root:target)
        && not (Sys.file_exists (Filename.concat target "main.txt")))
  in
  Alcotest.(check bool) "empty verified projection activates exactly" true empty;
  Alcotest.(check bool)
    "missing closure refuses without source mutation" true missing

let () =
  Alcotest.run "V1 workspace properties"
    [
      ( "workspace",
        [
          QCheck_alcotest.to_alcotest
            update_never_discards_a_dirty_tree_without_replace;
          QCheck_alcotest.to_alcotest
            receipt_generation_is_monotonic_for_verified_projection_updates;
          QCheck_alcotest.to_alcotest
            generated_exact_snapshots_activate_with_file_mode_and_symlink_fidelity;
          Alcotest.test_case
            "empty and missing closures preserve source boundary" `Quick
            empty_and_missing_projection_closures_do_not_materialize_source;
        ] );
    ]
