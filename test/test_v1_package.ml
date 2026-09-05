module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust
module Package = Yeokcham_v1_package
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

let receiver_project ~creator ~baseline =
  Model.init ~creator:(Trust.device_id creator) ~username:(username "receiver")
    ~initial_snapshot:baseline ~initial_draft:(draft "draft-receiver")
    ~title:"receiver"

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

let root_authority ~membership ~root_device =
  let root_certificate =
    Trust.certificates membership
    |> List.find (fun certificate ->
        Trust.device_equal (Trust.certificate_subject certificate) root_device)
  in
  let recovery_device = device (capability 'r') in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device (capability 'a')
    |> require_ok Trust.error_to_string
  in
  let root_authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  let active_epoch =
    Trust.successor_epoch root_authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates:(Trust.certificates membership)
      ~revoked:[] ~frontier:[] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      (capability 'a')
    |> require_ok Trust.error_to_string
  in
  Trust.extend_authority root_authority [ active_epoch ]
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
  let authority = root_authority ~membership ~root_device in
  let signed =
    Trust.sign_revision_at authority
      ~epoch:(List.hd (Trust.authority_heads authority))
      ~certificate:(Trust.certificate_id author_certificate)
      author_capability revision
    |> require_ok Trust.error_to_string
  in
  (source_root, source, baseline, repository, root_device, membership, signed)

let authority_setup root =
  let ( source_root,
        source,
        baseline,
        _repository,
        root_device,
        membership,
        signed ) =
    setup root
  in
  let root_capability = capability 'a' in
  let root_certificate =
    Trust.certificates membership
    |> List.find (fun certificate ->
        Trust.device_equal (Trust.certificate_subject certificate) root_device)
  in
  let recovery_capability = capability 'r' in
  let recovery_device = device recovery_capability in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device root_capability
    |> require_ok Trust.error_to_string
  in
  let root_authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  let enrolled_epoch =
    Trust.successor_epoch root_authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates:(Trust.certificates membership)
      ~revoked:[] ~frontier:[] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.extend_authority root_authority [ enrolled_epoch ]
    |> require_ok Trust.error_to_string
  in
  let signed =
    Trust.sign_revision_at authority
      ~epoch:(Trust.epoch_id enrolled_epoch)
      ~certificate:(Trust.signed_revision_certificate signed)
      (capability 'b')
      (Trust.signed_revision_value signed)
    |> require_ok Trust.error_to_string
  in
  ( source_root,
    source,
    baseline,
    root_device,
    root_capability,
    root_certificate,
    recovery_device,
    authority,
    signed )

let package_verifies_before_import_and_preserves_model_visibility () =
  with_directory "yeokcham-v1-package-" (fun root ->
      let ( source_root,
            source,
            baseline,
            _repository,
            root_device,
            membership,
            signed ) =
        setup root
      in
      let authority = root_authority ~membership ~root_device in
      let package = Filename.concat root "offline-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed ] ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      write_file destination_root "live.txt" "do not touch\n";
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let project = receiver_project ~creator:root_device ~baseline in
      let imported, project =
        Package.verify_and_import_with_authority ~destination ~package
          ~authority ~known_adoptions:[] ~project
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
      Alcotest.(check int)
        "receive exposes the imported shared change" 1
        (List.length (Model.shared_changes project));
      Alcotest.(check bool)
        "source working tree remains unchanged" true
        (Sys.file_exists (Filename.concat source_root "main.ml")))

let signed_resolution_receives_as_a_resolution_not_shared_work () =
  with_directory "yeokcham-v1-package-resolution-" (fun root ->
      let ( source_root,
            source,
            baseline,
            root_device,
            _root_capability,
            _root_certificate,
            _recovery_device,
            authority,
            first_signed ) =
        authority_setup root
      in
      let first = Trust.signed_revision_value first_signed in
      let author_capability = capability 'b' in
      let author = device author_capability in
      let second =
        Model.make_change_revision ~change:(change "change-two")
          ~revision:(revision "revision-two") ~parent:None
          ~author:(Trust.device_id author) ~base:baseline
          ~result:first.Model.result_snapshot
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
      let authority_epoch = List.hd (Trust.authority_heads authority) in
      let second_signed =
        Trust.sign_revision_at authority ~epoch:authority_epoch
          ~certificate:(Trust.signed_revision_certificate first_signed)
          author_capability second
        |> require_ok Trust.error_to_string
      in
      let source_project =
        receiver_project ~creator:root_device ~baseline |> fun project ->
        Model.receive project first |> require_ok Model.error_to_string
        |> fun project ->
        Model.receive project second |> require_ok Model.error_to_string
      in
      let decision =
        Model.projection source_project |> fun projection ->
        List.hd projection.Model.decisions
      in
      let replacement =
        Model.make_change_revision
          ~change:(change "change-resolution")
          ~revision:(revision "revision-resolution")
          ~parent:None ~author:(Trust.device_id author) ~base:baseline
          ~result:first.Model.result_snapshot
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
      let signed_resolution =
        Trust.sign_resolution_at authority ~epoch:authority_epoch
          ~certificate:(Trust.signed_revision_certificate first_signed)
          author_capability ~decision:decision.Model.decision_id replacement
        |> require_ok Trust.error_to_string
      in
      let package = Filename.concat root "resolution-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ first_signed; second_signed; signed_resolution ]
        ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let _, received =
        Package.verify_and_import_with_authority ~destination ~package
          ~authority ~known_adoptions:[]
          ~project:(receiver_project ~creator:root_device ~baseline)
        |> require_ok Package.error_to_string
      in
      Alcotest.(check int)
        "only the two incoming shared changes are shared work" 2
        (List.length (Model.shared_changes received));
      Alcotest.(check int)
        "the decision has one explicit resolution" 1
        (List.length (Model.resolutions received));
      Alcotest.(check int)
        "receipt leaves no open conflict decision" 0
        (List.length (Model.projection received).Model.decisions);
      let resolved = List.hd (Model.resolutions received) in
      Alcotest.(check string)
        "the signed record binds receipt to the original decision"
        (Model.Decision_id.to_string decision.Model.decision_id)
        (Model.Decision_id.to_string resolved.Model.resolved_decision);
      Alcotest.(check bool)
        "package source remains a local immutable object store" true
        (Sys.file_exists (Filename.concat source_root "main.ml")))

let signed_resolution_without_its_target_decision_is_rejected_atomically () =
  with_directory "yeokcham-v1-package-orphan-resolution-" (fun root ->
      let ( _source_root,
            source,
            baseline,
            root_device,
            _root_capability,
            _root_certificate,
            _recovery_device,
            authority,
            first_signed ) =
        authority_setup root
      in
      let first = Trust.signed_revision_value first_signed in
      let author_capability = capability 'b' in
      let author = device author_capability in
      let replacement =
        Model.make_change_revision
          ~change:(change "change-resolution")
          ~revision:(revision "revision-resolution")
          ~parent:None ~author:(Trust.device_id author) ~base:baseline
          ~result:first.Model.result_snapshot
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
      let signed_resolution =
        Trust.sign_resolution_at authority
          ~epoch:(List.hd (Trust.authority_heads authority))
          ~certificate:(Trust.signed_revision_certificate first_signed)
          author_capability
          ~decision:(id Model.Decision_id.of_string "decision-absent")
          replacement
        |> require_ok Trust.error_to_string
      in
      let package = Filename.concat root "orphan-resolution-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed_resolution ] ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      (match
         Package.verify_and_import_with_authority ~destination ~package
           ~authority ~known_adoptions:[]
           ~project:(receiver_project ~creator:root_device ~baseline)
       with
      | Error error ->
          Alcotest.(check string)
            "an orphaned signed resolution is not received as shared work"
            "unknown decision"
            (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "received a resolution with no target decision");
      Alcotest.(check int)
        "rejected resolution imports no immutable objects" 0
        (Store.list_objects destination
        |> require_ok Store.error_to_string
        |> List.length))

let wrong_repository_is_rejected_before_object_import () =
  with_directory "yeokcham-v1-package-reject-" (fun root ->
      let _, source, baseline, _, root_device, membership, signed =
        setup root
      in
      let authority = root_authority ~membership ~root_device in
      let package = Filename.concat root "offline-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed ] ~authorizations:[] ~adoptions:[]
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
      let other_capability = capability 'c' in
      let other_device = device other_capability in
      let other_root =
        Trust.root_certificate ~repository:other_repository ~device:other_device
          other_capability
        |> require_ok Trust.error_to_string
      in
      let other_membership =
        Trust.verify_membership ~repository:other_repository [ other_root ]
        |> require_ok Trust.error_to_string
      in
      let other_recovery = device (capability 'r') in
      let other_epoch =
        Trust.root_epoch ~membership:other_membership
          ~root_certificate:(Trust.certificate_id other_root)
          ~recovery_device:other_recovery other_capability
        |> require_ok Trust.error_to_string
      in
      let other_authority =
        Trust.verify_authority ~membership:other_membership [ other_epoch ]
        |> require_ok Trust.error_to_string
      in
      let project = receiver_project ~creator:root_device ~baseline in
      match
        Package.verify_and_import_with_authority ~destination ~package
          ~authority:other_authority ~known_adoptions:[] ~project
      with
      | Error error ->
          Alcotest.(check string)
            "repository binding is checked first"
            "invalid V1 package: package repository does not match destination"
            (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "wrong repository package was imported")

let alternate_root_for_the_same_repository_is_rejected_before_import () =
  with_directory "yeokcham-v1-package-root-" (fun root ->
      let _, source, baseline, repository, root_device, membership, signed =
        setup root
      in
      let authority = root_authority ~membership ~root_device in
      let package = Filename.concat root "offline-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed ] ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let rogue_capability = capability 'c' in
      let rogue_device = device rogue_capability in
      let rogue_root =
        Trust.root_certificate ~repository ~device:rogue_device rogue_capability
        |> require_ok Trust.error_to_string
      in
      let rogue_membership =
        Trust.verify_membership ~repository [ rogue_root ]
        |> require_ok Trust.error_to_string
      in
      let rogue_epoch =
        Trust.root_epoch ~membership:rogue_membership
          ~root_certificate:(Trust.certificate_id rogue_root)
          ~recovery_device:(device (capability 'r'))
          rogue_capability
        |> require_ok Trust.error_to_string
      in
      let rogue_authority =
        Trust.verify_authority ~membership:rogue_membership [ rogue_epoch ]
        |> require_ok Trust.error_to_string
      in
      let project = receiver_project ~creator:root_device ~baseline in
      (match
         Package.verify_and_import_with_authority ~destination ~package
           ~authority:rogue_authority ~known_adoptions:[] ~project
       with
      | Error error ->
          Alcotest.(check bool)
            "a second root cannot join a repository merely by using its ID" true
            (String.starts_with ~prefix:"V1 root certificate"
               (Package.error_to_string error))
      | Ok _ -> Alcotest.fail "package introduced a second repository root");
      let object_count =
        Store.list_objects destination
        |> require_ok Store.error_to_string
        |> List.length
      in
      Alcotest.(check int) "rejected package imports no objects" 0 object_count)

let missing_closure_object_is_rejected_without_importing_a_partial_package () =
  with_directory "yeokcham-v1-package-closure-" (fun root ->
      let _, source, baseline, _, root_device, membership, signed =
        setup root
      in
      let authority = root_authority ~membership ~root_device in
      let package = Filename.concat root "offline-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed ] ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let object_directory = Filename.concat package "objects" in
      let victim = Sys.readdir object_directory |> Array.to_list |> List.hd in
      Unix.unlink (Filename.concat object_directory victim);
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let project = receiver_project ~creator:root_device ~baseline in
      (match
         Package.verify_and_import_with_authority ~destination ~package
           ~authority ~known_adoptions:[] ~project
       with
      | Error error ->
          Alcotest.(check string)
            "manifest/object mismatch is explicit"
            "invalid V1 package: object files differ from manifest"
            (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "accepted a package with a missing closure object");
      let object_count =
        Store.list_objects destination
        |> require_ok Store.error_to_string
        |> List.length
      in
      Alcotest.(check int)
        "failed verification imports no objects" 0 object_count)

let duplicate_revision_is_rejected_before_a_package_is_created () =
  with_directory "yeokcham-v1-package-duplicate-" (fun root ->
      let _, source, _, _, root_device, membership, signed = setup root in
      let authority = root_authority ~membership ~root_device in
      let package = Filename.concat root "offline-package" in
      match
        Package.create_with_authority ~source ~destination:package ~authority
          ~revisions:[ signed; signed ] ~authorizations:[] ~adoptions:[]
      with
      | Error error ->
          Alcotest.(check string)
            "duplicate revision is explicit"
            "invalid V1 package: manifest contains the same revision more than \
             once"
            (Package.error_to_string error);
          Alcotest.(check bool)
            "no package directory was created" false (Sys.file_exists package)
      | Ok () -> Alcotest.fail "created a package with duplicate revisions")

let missing_causal_parent_is_rejected_before_object_import () =
  with_directory "yeokcham-v1-package-parent-" (fun root ->
      let _, source, baseline, repository, root_device, membership, _ =
        setup root
      in
      let authority = root_authority ~membership ~root_device in
      let root_capability = capability 'a' in
      let root_certificate =
        Trust.root_certificate ~repository ~device:root_device root_capability
        |> require_ok Trust.error_to_string
      in
      let child =
        Model.make_change_revision ~change:(change "change-one")
          ~revision:(revision "revision-child")
          ~parent:(Some (revision "revision-missing"))
          ~author:(Trust.device_id root_device)
          ~base:baseline ~result:baseline
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
      let signed_child =
        Trust.sign_revision_at authority
          ~epoch:(List.hd (Trust.authority_heads authority))
          ~certificate:(Trust.certificate_id root_certificate)
          root_capability child
        |> require_ok Trust.error_to_string
      in
      let package = Filename.concat root "offline-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed_child ] ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let local_initial =
        Model.make_change_revision ~change:(change "change-one")
          ~revision:(revision "revision-existing")
          ~parent:None
          ~author:(Trust.device_id root_device)
          ~base:baseline ~result:baseline
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
      let project =
        receiver_project ~creator:root_device ~baseline |> fun project ->
        Model.share_active project local_initial
        |> require_ok Model.error_to_string
      in
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      (match
         Package.verify_and_import_with_authority ~destination ~package
           ~authority ~known_adoptions:[] ~project
       with
      | Error error ->
          Alcotest.(check string)
            "missing parent is explicit"
            "revision parent is not the current revision"
            (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "imported a revision with a missing parent");
      let object_count =
        Store.list_objects destination
        |> require_ok Store.error_to_string
        |> List.length
      in
      Alcotest.(check int) "missing parent imports no objects" 0 object_count)

let late_revision_from_a_revoked_device_requires_current_head_adoption () =
  with_directory "yeokcham-v1-package-late-revision-" (fun root ->
      let ( _source_root,
            source,
            baseline,
            root_device,
            root_capability,
            root_certificate,
            recovery_device,
            authority,
            signed ) =
        authority_setup root
      in
      let author =
        Trust.signed_revision_value signed |> fun revision ->
        revision.Model.revision_author
      in
      let current = List.hd (Trust.authority_heads authority) in
      let revoked_epoch =
        Trust.successor_epoch authority ~parents:[ current ]
          ~certificates:
            (Trust.certificates (Trust.authority_membership authority))
          ~revoked:[ author ] ~frontier:[] ~recovery_device
          ~issuer:(Trust.certificate_id root_certificate)
          root_capability
        |> require_ok Trust.error_to_string
      in
      let revoked_authority =
        Trust.extend_authority authority [ revoked_epoch ]
        |> require_ok Trust.error_to_string
      in
      let rejected_package = Filename.concat root "unreviewed-package" in
      Package.create_with_authority ~source ~destination:rejected_package
        ~authority:revoked_authority ~revisions:[ signed ] ~authorizations:[]
        ~adoptions:[]
      |> require_ok Package.error_to_string;
      let destination_root = Filename.concat root "destination" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let project = receiver_project ~creator:root_device ~baseline in
      (match
         Package.verify_and_import_with_authority ~destination
           ~package:rejected_package ~authority ~known_adoptions:[] ~project
       with
      | Error error ->
          Alcotest.(check string)
            "revocation makes a newly arrived old record require review"
            "invalid V1 package: late revision from a revoked device requires \
             one current-head adoption"
            (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "accepted an unreviewed late revision");
      let object_count =
        Store.list_objects destination
        |> require_ok Store.error_to_string
        |> List.length
      in
      Alcotest.(check int) "review rejection imports no objects" 0 object_count;
      let adoption =
        Trust.make_adoption revoked_authority
          ~epoch:(Trust.epoch_id revoked_epoch)
          ~issuer:(Trust.certificate_id root_certificate)
          root_capability ~signed_revision:signed
        |> require_ok Trust.error_to_string
      in
      let adopted_package = Filename.concat root "adopted-package" in
      Package.create_with_authority ~source ~destination:adopted_package
        ~authority:revoked_authority ~revisions:[ signed ] ~authorizations:[]
        ~adoptions:[ adoption ]
      |> require_ok Package.error_to_string;
      let _, imported =
        Package.verify_and_import_with_authority ~destination
          ~package:adopted_package ~authority ~known_adoptions:[] ~project
        |> require_ok Package.error_to_string
      in
      Alcotest.(check int)
        "a current-head adoption accepts exactly that record" 1
        (List.length (Model.shared_changes imported)))

let on_disk_artifact_defers_object_payloads_to_the_iterator () =
  with_directory "yeokcham-v1-package-streaming-" (fun root ->
      let _, source, _, _, root_device, membership, signed = setup root in
      let authority = root_authority ~membership ~root_device in
      let package = Filename.concat root "offline-package" in
      Package.create_with_authority ~source ~destination:package ~authority
        ~revisions:[ signed ] ~authorizations:[] ~adoptions:[]
      |> require_ok Package.error_to_string;
      let artifact =
        Package.read_artifact ~package |> require_ok Package.error_to_string
      in
      let object_name =
        Sys.readdir (Filename.concat package "objects")
        |> Array.to_list |> List.hd
      in
      let object_path =
        Filename.concat (Filename.concat package "objects") object_name
      in
      Out_channel.with_open_bin object_path (fun channel ->
          Out_channel.output_string channel "malformed after artifact read");
      match Package.iter_artifact_objects artifact ~f:(fun _ _ -> Ok ()) with
      | Error _ -> ()
      | Ok () ->
          Alcotest.fail
            "artifact iteration accepted an object changed after manifest read")

let () =
  Alcotest.run "V1 package"
    [
      ( "offline receive",
        [
          Alcotest.test_case "verified package is model-visible only" `Quick
            package_verifies_before_import_and_preserves_model_visibility;
          Alcotest.test_case
            "signed resolution receives as a resolution, not shared work" `Quick
            signed_resolution_receives_as_a_resolution_not_shared_work;
          Alcotest.test_case
            "signed resolution without its target decision is rejected" `Quick
            signed_resolution_without_its_target_decision_is_rejected_atomically;
          Alcotest.test_case "wrong repository is rejected before import" `Quick
            wrong_repository_is_rejected_before_object_import;
          Alcotest.test_case "alternate root is rejected before import" `Quick
            alternate_root_for_the_same_repository_is_rejected_before_import;
          Alcotest.test_case "missing closure object is rejected before import"
            `Quick
            missing_closure_object_is_rejected_without_importing_a_partial_package;
          Alcotest.test_case "duplicate revision is rejected" `Quick
            duplicate_revision_is_rejected_before_a_package_is_created;
          Alcotest.test_case "missing causal parent is rejected before import"
            `Quick missing_causal_parent_is_rejected_before_object_import;
          Alcotest.test_case
            "late revoked revision needs a current-head adoption" `Quick
            late_revision_from_a_revoked_device_requires_current_head_adoption;
          Alcotest.test_case "on-disk artifacts defer payloads to the iterator"
            `Quick on_disk_artifact_defers_object_payloads_to_the_iterator;
        ] );
    ]
