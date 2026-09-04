module Health = Yeokcham_v4_health
module Health_repository = Yeokcham_v4_health_repository
module Envelope = Yeokcham_envelope
module Gc = Yeokcham_v4_gc
module Model = Yeokcham_v4_model
module Package = Yeokcham_v4_package
module Repair = Yeokcham_v4_repair
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_store
module Trust = Yeokcham_v4_trust
module V4_store = Yeokcham_v4_store

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
  Out_channel.with_open_bin (Filename.concat root name) (fun output ->
      Out_channel.output_string output contents)

let write_bytes path contents =
  Out_channel.with_open_bin path (fun output ->
      Out_channel.output_string output contents)

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let package_authority () =
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> Result.get_ok
  in
  let root_capability = capability 'a' in
  let root_device =
    Trust.signing_public_key root_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let root_certificate =
    Trust.root_certificate ~repository ~device:root_device root_capability
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  let recovery_device =
    capability 'r' |> Trust.signing_public_key |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device root_capability
    |> require_ok Trust.error_to_string
  in
  Trust.verify_authority ~membership [ root_epoch ]
  |> require_ok Trust.error_to_string

let initialize root =
  Service.init ~root
    ~creator:(Model.Device_id.of_string "device-alice" |> Result.get_ok)
    ~username:(Model.Username.of_string "alice" |> Result.get_ok)
    ~initial_draft:(Model.Draft_id.of_string "draft-one" |> Result.get_ok)
    ~title:"repair work"
  |> require_ok Service.error_to_string

let initialized_pair run =
  with_directory "v4-repair-target-" (fun root ->
      with_directory "v4-repair-backup-" (fun backup ->
          write_file root "main.ml" "let version = 1\n";
          write_file backup "main.ml" "let version = 1\n";
          let target_status = initialize root in
          ignore (initialize backup);
          run root backup target_status))

let checkpoint_object root status =
  let repository =
    V4_store.open_repository ~root |> require_ok V4_store.error_to_string
  in
  let store = V4_store.underlying_store repository in
  let snapshot =
    Model.Snapshot_id.to_string status.Service.checkpoint
    |> Store.Stored_object_id.of_hex |> Result.get_ok
  in
  (store, snapshot)

let delete_checkpoint root status =
  let store, snapshot = checkpoint_object root status in
  Unix.unlink (Store.object_path store snapshot);
  Store.Stored_object_id.to_hex snapshot

let candidate plan =
  match Health.plan_candidates plan with
  | [ candidate ] -> candidate
  | _ -> Alcotest.fail "expected one exact repair candidate"

let stage_exact_snapshot_in_quarantine root status =
  let repository =
    V4_store.open_repository ~root |> require_ok V4_store.error_to_string
  in
  let loaded =
    V4_store.load repository |> require_ok V4_store.error_to_string
  in
  let store = V4_store.underlying_store repository in
  let snapshot =
    Model.Snapshot_id.to_string status.Service.checkpoint
    |> Store.Stored_object_id.of_hex |> Result.get_ok
  in
  let envelope = Store.get store snapshot |> require_ok Store.error_to_string in
  let bytes = Envelope.encode envelope in
  let state =
    {
      Store.id = loaded.V4_store.object_id;
      object_type = Envelope.V4_project_state;
      stored_bytes =
        (Unix.stat (Store.object_path store loaded.V4_store.object_id))
          .Unix.st_size;
    }
  in
  let object_ =
    {
      Store.id = snapshot;
      object_type = Envelope.object_type envelope;
      stored_bytes = String.length bytes;
    }
  in
  let plan =
    Gc.classify ~state_head:loaded.V4_store.object_id
      ~objects:[ state; object_ ] ~reachable:[]
    |> require_ok Gc.error_to_string
  in
  let transaction = Gc.make_transaction plan |> require_ok Gc.error_to_string in
  let gc = Filename.concat (Filename.concat root ".yeokcham") "gc" in
  Unix.mkdir gc 0o700;
  let directory =
    Filename.concat gc ("v4-gc-" ^ Gc.transaction_id transaction)
  in
  Unix.mkdir directory 0o700;
  write_bytes
    (Filename.concat directory "transaction.cbor")
    (Gc.encode_transaction transaction |> require_ok Gc.error_to_string);
  write_bytes
    (Filename.concat directory (Store.Stored_object_id.to_hex snapshot))
    bytes;
  Gc.transaction_id transaction

let assert_missing root =
  let report = Health_repository.verify ~root in
  Alcotest.(check bool)
    "target remains damaged" false
    (Health.report_is_clean report)

let backup_repair_is_explicit_exact_and_source_safe () =
  initialized_pair (fun root backup status ->
      let missing = delete_checkpoint root status in
      let target_before =
        In_channel.with_open_bin
          (Filename.concat root "main.ml")
          In_channel.input_all
      in
      let backup_before =
        In_channel.with_open_bin
          (Filename.concat backup "main.ml")
          In_channel.input_all
      in
      let plan =
        Repair.plan_from_backup ~root ~backup ~created_at:10L ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      Alcotest.(check string)
        "candidate names exactly the missing object" missing
        (Health.candidate_object_id candidate);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_backup ~root ~plan_id:(Health.plan_id plan) ~selection
          ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Applied _ -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal));
      Alcotest.(check string)
        "repair never materialises target source" target_before
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all);
      Alcotest.(check string)
        "repair never alters backup source" backup_before
        (In_channel.with_open_bin
           (Filename.concat backup "main.ml")
           In_channel.input_all);
      Alcotest.(check bool)
        "repaired closure is clean" true
        (Health_repository.verify ~root |> Health.report_is_clean))

let[@warning "-4"] disappearing_backup_refuses_without_publication () =
  initialized_pair (fun root backup status ->
      let missing = delete_checkpoint root status in
      let plan =
        Repair.plan_from_backup ~root ~backup ~created_at:10L ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      let backup_store, backup_snapshot = checkpoint_object backup status in
      Unix.unlink (Store.object_path backup_store backup_snapshot);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_backup ~root ~plan_id:(Health.plan_id plan) ~selection
          ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Refused Health.Candidate_changed -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal)
      | Repair.Applied _ -> Alcotest.fail "vanished backup object was published");
      let target_store, target_snapshot = checkpoint_object root status in
      Alcotest.(check bool)
        "missing object remains absent" false
        (Sys.file_exists (Store.object_path target_store target_snapshot));
      Alcotest.(check string)
        "expected missing object" missing
        (Store.Stored_object_id.to_hex target_snapshot);
      assert_missing root)

let[@warning "-4"] changed_state_head_refuses_stale_approval () =
  initialized_pair (fun root backup status ->
      ignore (delete_checkpoint root status);
      let plan =
        Repair.plan_from_backup ~root ~backup ~created_at:10L ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let loaded =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      let project =
        Model.register_username loaded.V4_store.project
          ~device:(Model.Device_id.of_string "device-bob" |> Result.get_ok)
          ~username:(Model.Username.of_string "bob" |> Result.get_ok)
        |> require_ok Model.error_to_string
      in
      ignore
        (V4_store.save repository ~expected:loaded.V4_store.head ~project
        |> require_ok V4_store.error_to_string);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_backup ~root ~plan_id:(Health.plan_id plan) ~selection
          ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Refused Health.State_head_changed -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal)
      | Repair.Applied _ -> Alcotest.fail "stale plan published an object");
      assert_missing root)

let quarantine_source_is_read_only_and_exact () =
  initialized_pair (fun root _backup status ->
      let transaction_id = stage_exact_snapshot_in_quarantine root status in
      let target_before =
        In_channel.with_open_bin
          (Filename.concat root "main.ml")
          In_channel.input_all
      in
      let missing = delete_checkpoint root status in
      let plan =
        Repair.plan_from_gc_quarantine ~root ~transaction_id ~created_at:10L
          ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      Alcotest.(check string)
        "quarantine candidate names missing object" missing
        (Health.candidate_object_id candidate);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_gc_quarantine ~root ~plan_id:(Health.plan_id plan)
          ~selection ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Applied _ -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal));
      Alcotest.(check string)
        "quarantine repair never materialises source" target_before
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all);
      Alcotest.(check bool)
        "quarantine candidate repaired closure" true
        (Health_repository.verify ~root |> Health.report_is_clean))

let offline_package_source_is_verified_without_receipt () =
  initialized_pair (fun root _backup status ->
      let store, snapshot = checkpoint_object root status in
      let package = Filename.concat root "offline-package" in
      Package.create_bootstrap_with_authority ~source:store ~destination:package
        ~authority:(package_authority ()) ~revisions:[] ~authorizations:[]
        ~adoptions:[]
        ~extra_snapshots:
          [
            Model.Snapshot_id.of_string (Store.Stored_object_id.to_hex snapshot)
            |> Result.get_ok;
          ]
      |> require_ok Package.error_to_string;
      let target_before =
        In_channel.with_open_bin
          (Filename.concat root "main.ml")
          In_channel.input_all
      in
      let missing = delete_checkpoint root status in
      let plan =
        Repair.plan_from_offline_package ~root ~package ~created_at:10L
          ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      Alcotest.(check string)
        "package candidate names missing object" missing
        (Health.candidate_object_id candidate);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_offline_package ~root ~plan_id:(Health.plan_id plan)
          ~selection ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Applied _ -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal));
      Alcotest.(check string)
        "package repair is not package receipt" target_before
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all);
      Alcotest.(check bool)
        "package candidate repaired closure" true
        (Health_repository.verify ~root |> Health.report_is_clean))

let () =
  Alcotest.run "V4 repair"
    [
      ( "backup",
        [
          Alcotest.test_case "exact repair preserves ordinary sources" `Quick
            backup_repair_is_explicit_exact_and_source_safe;
          Alcotest.test_case "disappearing source refuses" `Quick
            disappearing_backup_refuses_without_publication;
          Alcotest.test_case "changed state head refuses" `Quick
            changed_state_head_refuses_stale_approval;
          Alcotest.test_case "quarantine source is exact and source-safe" `Quick
            quarantine_source_is_read_only_and_exact;
          Alcotest.test_case "offline package source is verified and no-receipt"
            `Quick offline_package_source_is_verified_without_receipt;
        ] );
    ]
