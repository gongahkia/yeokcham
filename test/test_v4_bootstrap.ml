module Bootstrap = Yeokcham_v4_bootstrap
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v4_model
module Package = Yeokcham_v4_package
module Recovery = Yeokcham_v4_recovery
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_v4_store
module Trust = Yeokcham_v4_trust

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
  with_directory "yeokcham-v4-bootstrap-" (fun parent ->
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
  with_directory "yeokcham-v4-bootstrap-repository-" (fun parent ->
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
      Alcotest.(check string)
        "bootstrap basis bytes are stable"
        (read_golden "v4/bootstrap-basis-v1.cbor.hex")
        encoded;
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

let () =
  Alcotest.run "V4 bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case
            "imports delivery history into a fresh local draft without \
             touching files"
            `Quick bootstrap_imports_shared_delivery_without_source_scratch;
          Alcotest.test_case "rejects wrong repository before import" `Quick
            bootstrap_basis_rejects_a_wrong_repository_before_import;
        ] );
    ]
