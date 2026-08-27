module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Package = Yeokcham_v4_package
module Store = Yeokcham_store
module Snapshot = Yeokcham_snapshot

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

let id parser value = parser value |> Result.get_ok
let draft value = id Model.Draft_id.of_string value
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let username value = id Model.Username.of_string value

let snapshot_id identity =
  identity |> Snapshot.Snapshot.stored_object_id
  |> Store.Stored_object_id.to_hex |> Model.Snapshot_id.of_string
  |> Result.get_ok

let scan root store =
  Snapshot.scan_excluding_root_names ~excluded_root_names:[ ".yeokcham" ] ~root
    ~store
  |> require_ok Snapshot.error_to_string
  |> fst |> snapshot_id

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let device capability =
  capability |> Trust.signing_public_key |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let setup root =
  let source_root = Filename.concat root "source" in
  Unix.mkdir source_root 0o700;
  write_file source_root "main.ml" "let version = 1\n";
  let source =
    Store.init ~root:source_root |> require_ok Store.error_to_string
  in
  let baseline = scan source_root source in
  write_file source_root "main.ml" "let version = 2\n";
  let result = scan source_root source in
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> Result.get_ok
  in
  let root_capability = capability 'a' in
  let root_device = device root_capability in
  let root_certificate =
    Trust.root_certificate ~repository ~device:root_device root_capability
    |> require_ok Trust.error_to_string
  in
  let initial_membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  let author_capability = capability 'b' in
  let author = device author_capability in
  let author_certificate =
    Trust.enroll initial_membership
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~subject:author ~role:Trust.Member
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ root_certificate; author_certificate ]
    |> require_ok Trust.error_to_string
  in
  let revision =
    Model.make_change_revision ~change:(change "change-one")
      ~revision:(revision "revision-one") ~parent:None
      ~author:(Trust.device_id author) ~base:baseline ~result
      ~edits:
        [
          {
            Model.edit_path =
              Model.Path.of_components [ "main.ml" ] |> Result.get_ok;
            edit_kind = Model.Whole_path;
          };
        ]
    |> require_ok Model.error_to_string
  in
  let signed =
    Trust.sign_revision membership
      ~certificate:(Trust.certificate_id author_certificate)
      author_capability revision
    |> require_ok Trust.error_to_string
  in
  (source_root, source, baseline, repository, root_device, membership, signed)

let package_verifies_before_import_and_preserves_model_visibility () =
  with_directory "yeokcham-v4-package-" (fun root ->
      let ( source_root,
            source,
            baseline,
            repository,
            root_device,
            membership,
            signed ) =
        setup root
      in
      let package = Filename.concat root "offline-package" in
      Package.create ~source ~destination:package ~membership
        ~revisions:[ signed ]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      write_file destination_root "live.txt" "do not touch\n";
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let imported =
        Package.verify_and_import ~destination ~package ~repository
        |> require_ok Package.error_to_string
      in
      Alcotest.(check int)
        "one signed revision is verified" 1
        (List.length (Package.revisions imported));
      Alcotest.(check string)
        "package leaves a working tree untouched" "do not touch\n"
        (In_channel.with_open_bin
           (Filename.concat destination_root "live.txt")
           In_channel.input_all);
      let project =
        Model.init
          ~creator:(Trust.device_id root_device)
          ~username:(username "root") ~initial_snapshot:baseline
          ~initial_draft:(draft "draft-one") ~title:"receiver"
      in
      let project =
        Package.apply_revisions project imported
        |> require_ok Package.error_to_string
      in
      Alcotest.(check int)
        "receive exposes the imported shared change" 1
        (List.length (Model.shared_changes project));
      Alcotest.(check bool)
        "source working tree remains unchanged" true
        (Sys.file_exists (Filename.concat source_root "main.ml")))

let wrong_repository_is_rejected_before_object_import () =
  with_directory "yeokcham-v4-package-reject-" (fun root ->
      let _, source, _, _, _, membership, signed = setup root in
      let package = Filename.concat root "offline-package" in
      Package.create ~source ~destination:package ~membership
        ~revisions:[ signed ]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let other_repository =
        Trust.Repository_id.of_string
          "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        |> Result.get_ok
      in
      match
        Package.verify_and_import ~destination ~package
          ~repository:other_repository
      with
      | Error error ->
          Alcotest.(check string)
            "repository binding is checked first"
            "invalid V4 package: package repository does not match destination"
            (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "wrong repository package was imported")

let () =
  Alcotest.run "V4 package"
    [
      ( "offline receive",
        [
          Alcotest.test_case "verified package is model-visible only" `Quick
            package_verifies_before_import_and_preserves_model_visibility;
          Alcotest.test_case "wrong repository is rejected before import" `Quick
            wrong_repository_is_rejected_before_object_import;
        ] );
    ]
