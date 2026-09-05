module Bootstrap = Yeokcham_v1_bootstrap
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v1_model
module Package = Yeokcham_v1_package
module Recovery = Yeokcham_v1_recovery
module Service = Yeokcham_v1_local_service
module Store = Yeokcham_v1_store
module Trust = Yeokcham_v1_trust
module Workspace = Yeokcham_v1_workspace

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let read_file root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let id parser value = parser value |> Result.get_ok
let draft value = id Model.Draft_id.of_string value
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let delivery value = id Model.Delivery_id.of_string value
let username value = id Model.Username.of_string value

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let device capability =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> require_ok Fun.id

let root_certificate authority =
  Trust.certificates (Trust.authority_membership authority)
  |> List.find (fun certificate -> Trust.certificate_issuer certificate = None)

let bootstrap_imports_shared_delivery_without_source_scratch () =
  with_directory "yeokcham-v1-bootstrap-" (fun parent ->
      let source = Filename.concat parent "source" in
      let target = Filename.concat parent "target" in
      let staged = Filename.concat parent "bootstrap-package" in
      Unix.mkdir source 0o700;
      Unix.mkdir target 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file target "keep.txt" "untouched local file\n";
      let administrator_capability = capability 'a' in
      let administrator = device administrator_capability in
      let recovery_capability = capability 'r' in
      let recovery_device = device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root:source
           ~username:(username "alice") ~initial_draft:(draft "source-draft")
           ~title:"source scratch" ~repository ~device:administrator
           ~signing_capability:administrator_capability ~recovery_device
           ~recovery_capability
        |> require_ok Service.error_to_string);
      let member_capability = capability 'b' in
      let member = device member_capability in
      ignore
        (Service.enroll_device ~parent:None ~root:source ~subject:member
           ~role:Trust.Member ~username:(username "bob")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      write_file source "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(change "source-change")
           ~revision:(revision "source-revision")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      ignore
        (Service.deliver ~root:source
           ~id:(delivery "source-delivery")
           ~next_draft:(draft "source-after-delivery")
           ~next_title:"next source work"
        |> require_ok Service.error_to_string);
      let outbound =
        Service.prepare_bootstrap_outbound ~root:source
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string
      in
      Package.materialize_artifact ~destination:staged
        outbound.Service.bootstrap_artifact
      |> require_ok Package.error_to_string;
      let basis = Bootstrap.encode outbound.Service.bootstrap_basis in
      let source_repository =
        Store.open_repository ~root:source |> require_ok Store.error_to_string
      in
      let source_state =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let source_authority =
        match source_state.Store.collaboration with
        | Some collaboration -> (
            match Store.authority collaboration with
            | Some authority -> authority
            | None -> Alcotest.fail "source lacks authority")
        | None -> Alcotest.fail "source lacks collaboration"
      in
      let member_certificate =
        Trust.certificates (Trust.authority_membership source_authority)
        |> List.find (fun certificate ->
            Trust.device_equal (Trust.certificate_subject certificate) member)
        |> Trust.certificate_id
      in
      let phrase =
        Recovery.verification_phrase (root_certificate source_authority)
      in
      (match
         Service.bootstrap_from_package ~root:target ~repository ~package:staged
           ~basis ~verify_phrase:"wrong phrase" ~username:(username "bob")
           ~initial_draft:(draft "target-draft") ~title:"target scratch"
           ~device:member ~local_certificate:member_certificate
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "bootstrap accepted a wrong root phrase");
      Alcotest.(check bool)
        "failed bootstrap leaves no destination repository" false
        (Sys.file_exists (Filename.concat target ".yeokcham"));
      let received =
        Service.bootstrap_from_package ~root:target ~repository ~package:staged
          ~basis ~verify_phrase:phrase ~username:(username "bob")
          ~initial_draft:(draft "target-draft") ~title:"target scratch"
          ~device:member ~local_certificate:member_certificate
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "delivery history is imported" 1 received.Service.delivery_count;
      Alcotest.(check int)
        "source scratch shared change is consumed" 0
        received.Service.shared_change_count;
      Alcotest.(check string)
        "target owns a new active draft" "target-draft"
        (Model.Draft_id.to_string received.Service.active_draft.Model.draft_id);
      Alcotest.(check (list string))
        "source usernames are not imported" [ "bob" ]
        (received.Service.usernames
        |> List.map (fun registration ->
            Model.Username.to_string registration.Model.username));
      Alcotest.(check string)
        "bootstrap does not materialize the working tree"
        "untouched local file\n"
        (read_file target "keep.txt");
      let nonempty_activation = Service.workspace_activate ~root:target in
      Alcotest.(check bool)
        "activation refuses an ordinary nonempty destination" true
        (Result.is_error nonempty_activation);
      Alcotest.(check string)
        "nonempty activation refusal preserves ordinary bytes"
        "untouched local file\n"
        (read_file target "keep.txt");
      let restored = Filename.concat target "explicit-restore" in
      Unix.mkdir restored 0o700;
      Service.restore ~root:target ~checkpoint:received.Service.checkpoint
        ~destination:restored
      |> require_ok Service.error_to_string;
      Alcotest.(check string)
        "only an explicit later restore materializes shared history"
        "let version = 2\n"
        (read_file restored "main.ml"))

let bootstrap_basis_rejects_a_wrong_repository_before_import () =
  with_directory "yeokcham-v1-bootstrap-repository-" (fun parent ->
      let source = Filename.concat parent "source" in
      Unix.mkdir source 0o700;
      write_file source "main.ml" "let version = 1\n";
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
        |> require_ok Service.error_to_string);
      let outbound =
        Service.prepare_bootstrap_outbound ~root:source
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string
      in
      let encoded = Bootstrap.encode outbound.Service.bootstrap_basis in
      let expected =
        Golden.refresh_lower_hex_file
          (golden_path "v1/bootstrap-basis-v1.cbor.hex")
          encoded
        |> require_ok Fun.id
      in
      Alcotest.(check string)
        "bootstrap basis bytes are stable" expected encoded;
      let decoded =
        Bootstrap.decode encoded |> require_ok Bootstrap.error_to_string
      in
      Alcotest.(check string)
        "bootstrap basis decoder is canonical" encoded
        (Bootstrap.encode decoded);
      let package = Filename.concat parent "package" in
      Package.materialize_artifact ~destination:package
        outbound.Service.bootstrap_artifact
      |> require_ok Package.error_to_string;
      let other_repository =
        Trust.Repository_id.of_string
          "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        |> Result.get_ok
      in
      match
        Bootstrap.verify ~repository:other_repository ~package
          ~bytes:(Bootstrap.encode outbound.Service.bootstrap_basis)
      with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail "bootstrap accepted a package for another repository")

let bootstrap_into_an_empty_root_requires_explicit_workspace_activation () =
  with_directory "yeokcham-v1-bootstrap-workspace-" (fun parent ->
      let source = Filename.concat parent "source" in
      let target = Filename.concat parent "target" in
      let package = Filename.concat parent "package" in
      Unix.mkdir source 0o700;
      Unix.mkdir target 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file source "run.sh" "#!/bin/sh\necho projected\n";
      Unix.chmod (Filename.concat source "run.sh") 0o755;
      Unix.symlink "main.ml" (Filename.concat source "main-link");
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
        |> require_ok Service.error_to_string);
      let outbound =
        Service.prepare_bootstrap_outbound ~root:source
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string
      in
      Package.materialize_artifact ~destination:package
        outbound.Service.bootstrap_artifact
      |> require_ok Package.error_to_string;
      let source_repository =
        Store.open_repository ~root:source |> require_ok Store.error_to_string
      in
      let source_state =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let source_authority =
        match source_state.Store.collaboration with
        | Some collaboration -> (
            match Store.authority collaboration with
            | Some authority -> authority
            | None -> Alcotest.fail "source lacks authority")
        | None -> Alcotest.fail "source lacks collaboration"
      in
      let certificate =
        root_certificate source_authority |> Trust.certificate_id
      in
      let phrase =
        Recovery.verification_phrase (root_certificate source_authority)
      in
      ignore
        (Service.bootstrap_from_package ~root:target ~repository ~package
           ~basis:(Bootstrap.encode outbound.Service.bootstrap_basis)
           ~verify_phrase:phrase ~username:(username "alice")
           ~initial_draft:(draft "target-draft") ~title:"target"
           ~device:administrator ~local_certificate:certificate
        |> require_ok Service.error_to_string);
      let stored_basis =
        Workspace.read_basis ~root:target
        |> require_ok Workspace.error_to_string
      in
      Alcotest.(check string)
        "bootstrap basis marker binds its immutable signed basis"
        (Bootstrap.id outbound.Service.bootstrap_basis)
        (stored_basis |> Option.get |> Workspace.basis_imported_basis_id);
      Alcotest.(check (list string))
        "bootstrap creates only V1 metadata" [ ".yeokcham" ]
        (Sys.readdir target |> Array.to_list |> List.sort String.compare);
      let workspace_directory =
        Workspace.basis_path ~root:target |> Filename.dirname
      in
      let receipt_stage_failure =
        Unix.chmod workspace_directory 0o500;
        Fun.protect
          ~finally:(fun () -> Unix.chmod workspace_directory 0o700)
          (fun () -> Service.workspace_activate ~root:target)
      in
      Alcotest.(check bool)
        "receipt-stage failure refuses before source materialisation" true
        (Result.is_error receipt_stage_failure);
      Alcotest.(check bool)
        "receipt-stage failure leaves ordinary source absent" false
        (Sys.file_exists (Filename.concat target "main.ml"));
      let before =
        Store.open_repository ~root:target
        |> require_ok Store.error_to_string
        |> Store.load
        |> require_ok Store.error_to_string
      in
      let pending_receipt =
        Workspace.activate ~basis:stored_basis
          ~closure:Workspace.Closure_complete
          ~destination:Workspace.Destination_empty
        |> require_ok Workspace.refusal_to_string
        |> Workspace.plan_receipt
      in
      ignore
        (Workspace.stage_receipt ~root:target pending_receipt
        |> require_ok Workspace.error_to_string);
      write_file target "main.ml" "partial activation output\n";
      Alcotest.(check bool)
        "prepared activation leaves a resumable local marker" true
        (Sys.file_exists (Workspace.pending_receipt_path ~root:target));
      let activated =
        Service.workspace_activate ~root:target
        |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "activation records a local receipt" true
        (Sys.file_exists (Workspace.receipt_path ~root:target));
      Alcotest.(check bool)
        "resumed activation publishes and clears its pending receipt" false
        (Sys.file_exists (Workspace.pending_receipt_path ~root:target));
      Alcotest.(check string)
        "explicit activation materialises exact baseline bytes"
        "let version = 1\n"
        (read_file target "main.ml");
      Alcotest.(check bool)
        "activation preserves executable mode" true
        ((Unix.lstat (Filename.concat target "run.sh")).Unix.st_perm land 0o111
        <> 0);
      Alcotest.(check string)
        "activation preserves exact symlink target" "main.ml"
        (Unix.readlink (Filename.concat target "main-link"));
      let after =
        Store.open_repository ~root:target
        |> require_ok Store.error_to_string
        |> Store.load
        |> require_ok Store.error_to_string
      in
      Alcotest.(check (list string))
        "activation does not change signed shared history"
        (match before.Store.collaboration with
        | Some collaboration ->
            Store.signed_revisions collaboration
            |> List.map (fun signed ->
                Trust.signed_revision_id signed |> Model.Revision_id.to_string)
        | None -> [])
        (match after.Store.collaboration with
        | Some collaboration ->
            Store.signed_revisions collaboration
            |> List.map (fun signed ->
                Trust.signed_revision_id signed |> Model.Revision_id.to_string)
        | None -> []);
      Alcotest.(check bool)
        "activation and clean replay do not advance the project state" true
        (Yeokcham_store.Stored_object_id.equal before.Store.object_id
           after.Store.object_id);
      let verified_basis = Option.get stored_basis in
      let stale_basis =
        Workspace.make_projection_basis
          ~repository:(Workspace.basis_repository verified_basis)
          ~imported_basis_id:(String.make 64 'f')
          ~snapshot:(Workspace.basis_snapshot verified_basis)
          ~canonical_tree:(Workspace.basis_canonical_tree verified_basis)
          ~source_fingerprint:
            (Workspace.basis_source_fingerprint verified_basis)
        |> require_ok Workspace.error_to_string
      in
      let stale_receipt =
        Workspace.activate ~basis:(Some stale_basis)
          ~closure:Workspace.Closure_complete
          ~destination:Workspace.Destination_empty
        |> require_ok Workspace.refusal_to_string
        |> Workspace.plan_receipt
      in
      Workspace.write_receipt ~root:target stale_receipt
      |> require_ok Workspace.error_to_string;
      Alcotest.(check bool)
        "stale receipt is refused without changing source" true
        (Result.is_error (Service.workspace_update ~root:target ~replace:false));
      Alcotest.(check string)
        "stale receipt refusal preserves exact source bytes" "let version = 1\n"
        (read_file target "main.ml");
      Workspace.write_receipt ~root:target pending_receipt
      |> require_ok Workspace.error_to_string;
      (match Service.workspace_update ~root:target ~replace:false with
      | Ok (Service.Workspace_already_current receipt) ->
          Alcotest.(check int64)
            "clean update leaves receipt generation stable" 1L
            (Workspace.receipt_activation_generation receipt)
      | Ok (Service.Workspace_updated _) ->
          Alcotest.fail "clean workspace update materialised unexpectedly"
      | Error error -> Alcotest.fail (Service.error_to_string error));
      write_file target "main.ml" "let local = 2\n";
      let dirty_update = Service.workspace_update ~root:target ~replace:false in
      Alcotest.(check bool)
        "dirty default update refuses" true
        (Result.is_error dirty_update);
      Alcotest.(check string)
        "dirty refusal preserves ordinary bytes" "let local = 2\n"
        (read_file target "main.ml");
      let updated =
        Service.workspace_update ~root:target ~replace:true
        |> require_ok Service.error_to_string
      in
      let materialized =
        match updated with
        | Service.Workspace_updated materialized -> materialized
        | Service.Workspace_already_current _ ->
            Alcotest.fail "explicit replace did not materialise the basis"
      in
      let safety =
        match materialized.Service.workspace_safety_checkpoint with
        | Some checkpoint -> checkpoint
        | None -> Alcotest.fail "replace did not retain a safety checkpoint"
      in
      Alcotest.(check bool)
        "replace reports a durable restore proof" true
        (Option.is_some materialized.Service.workspace_restore_proof);
      Alcotest.(check string)
        "replace materialises verified baseline bytes" "let version = 1\n"
        (read_file target "main.ml");
      let recovered = Filename.concat parent "recovered-local-edit" in
      Unix.mkdir recovered 0o700;
      Service.restore ~root:target ~checkpoint:safety ~destination:recovered
      |> require_ok Service.error_to_string;
      Alcotest.(check string)
        "replace safety checkpoint restores the discarded local bytes"
        "let local = 2\n"
        (read_file recovered "main.ml");
      ignore activated)

let () =
  Alcotest.run "V1 bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case
            "imports delivery history into a fresh local draft without \
             touching files"
            `Quick bootstrap_imports_shared_delivery_without_source_scratch;
          Alcotest.test_case "rejects wrong repository before import" `Quick
            bootstrap_basis_rejects_a_wrong_repository_before_import;
          Alcotest.test_case
            "requires explicit projection activation and explicit replacement"
            `Quick
            bootstrap_into_an_empty_root_requires_explicit_workspace_activation;
        ] );
    ]
