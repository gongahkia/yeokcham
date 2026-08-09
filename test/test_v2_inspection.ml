module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Inspection = Yeokcham_v2_inspection
module Model = Yeokcham_model
module Object_store = Yeokcham_v2_object_store
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository_id =
  V2_model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok V2_model.identity_error_to_string

let device_id =
  V2_model.Device_id.of_bytes (String.make 32 'd')
  |> require_ok V2_model.identity_error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let signing_key =
  Mirage_crypto_ec.Ed25519.priv_of_octets
    (String.init 32 (fun index -> Char.chr (index + 1)))
  |> require_ok (fun error ->
      Format.asprintf "%a" Mirage_crypto_ec.pp_error error)

let capability =
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> require_ok Bootstrap.error_to_string

let key_handle =
  Bootstrap.Key_handle.of_bytes (String.make 32 'h')
  |> require_ok V2_model.identity_error_to_string

let bootstrap =
  Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
    ~mandatory_features:0L
  |> require_ok Bootstrap.error_to_string

let nonce character =
  Envelope.nonce_of_bytes (String.make 12 character)
  |> require_ok Envelope.error_to_string

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

let with_repository run =
  let root = Filename.temp_file "yeokcham-v2-inspection-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      ignore
        (Bootstrap_store.initialize ~root bootstrap
        |> require_ok Bootstrap_store.error_to_string);
      let bootstrap_repository =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let scratch =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      run root bootstrap_repository scratch)

let snapshot content =
  let path =
    Model.Path.of_components [ "work" ] |> require_ok Model.Path.error_to_string
  in
  Model.Snapshot.of_entries
    [ Model.File_path (path, { Model.mode = Model.Regular; content }) ]
  |> require_ok Model.construction_error_to_string

let publish scratch content =
  Scratch.publish scratch ~snapshot:(snapshot content)
    ~snapshot_nonce:(nonce '1') ~ledger_nonce:(nonce '2')
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Published checkpoint -> checkpoint
  | Scratch.Unchanged _ -> Alcotest.fail "initial snapshot was unchanged"

let rec inventory path =
  let stat = Unix.lstat path in
  match stat.Unix.st_kind with
  | Unix.S_DIR ->
      let children =
        Sys.readdir path |> Array.to_list |> List.sort String.compare
        |> List.concat_map (fun name -> inventory (Filename.concat path name))
      in
      (path, "directory", stat.Unix.st_perm, "") :: children
  | Unix.S_REG ->
      [
        ( path,
          "regular",
          stat.Unix.st_perm,
          In_channel.with_open_bin path In_channel.input_all );
      ]
  | Unix.S_LNK -> [ (path, "symlink", stat.Unix.st_perm, Unix.readlink path) ]
  | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Alcotest.fail "unexpected special file in repository inventory"

let empty_repository_has_no_derived_state () =
  with_repository (fun root bootstrap_repository _ ->
      let status =
        Inspection.status ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check bool)
        "status has repository identity" true
        (V2_model.Repository_id.equal status.Inspection.repository_id
           repository_id);
      Alcotest.(check bool)
        "status has device identity" true
        (V2_model.Device_id.equal status.Inspection.device_id device_id);
      Alcotest.(check bool)
        "scratch starts without a checkpoint" true
        (status.Inspection.scratch = Inspection.No_checkpoint);
      Alcotest.(check int)
        "no restore journal records" 0 status.Inspection.journal_record_count;
      let storage =
        Inspection.storage ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "no encrypted objects" 0 storage.Inspection.encrypted_objects;
      Alcotest.(check int64)
        "no encrypted bytes" 0L storage.Inspection.encrypted_bytes;
      let report =
        Inspection.verify ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "no verified objects" 0 report.Inspection.Verification.verified_objects)

let published_scratch_is_reported_and_verified () =
  with_repository (fun root bootstrap_repository scratch ->
      let expected = publish scratch "target\000bytes" in
      let status =
        Inspection.status ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string
      in
      (match status.Inspection.scratch with
      | Inspection.Checkpoint actual ->
          Alcotest.(check string)
            "checkpoint event is exact"
            (Scratch.Ledger.Event_id.to_hex expected.Scratch.event_id)
            (Scratch.Ledger.Event_id.to_hex actual.Inspection.event_id);
          Alcotest.(check string)
            "checkpoint snapshot reference is exact"
            (V2_model.Opaque_object_ref.to_hex expected.Scratch.snapshot_ref)
            (V2_model.Opaque_object_ref.to_hex actual.Inspection.snapshot_ref);
          Alcotest.(check string)
            "checkpoint snapshot id is exact"
            (Yeokcham_id.Snapshot_id.to_hex
               (Model.Snapshot.id expected.Scratch.snapshot))
            (Yeokcham_id.Snapshot_id.to_hex actual.Inspection.snapshot_id);
          Alcotest.(check int)
            "one snapshot entry" 1 actual.Inspection.entry_count
      | Inspection.No_checkpoint -> Alcotest.fail "checkpoint was not reported"
      | Inspection.Divergent _ -> Alcotest.fail "single checkpoint diverged");
      let storage =
        Inspection.storage ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "two encrypted objects" 2 storage.Inspection.encrypted_objects;
      Alcotest.(check bool)
        "encrypted bytes are counted" true
        (storage.Inspection.encrypted_bytes > 0L);
      Alcotest.(check int) "one ledger frame" 1 storage.Inspection.ledger_frames;
      Alcotest.(check int)
        "one scratch snapshot frame" 1
        storage.Inspection.scratch_snapshot_frames;
      let report =
        Inspection.verify ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "two verified objects" 2 report.Inspection.Verification.verified_objects;
      Alcotest.(check int)
        "one verified event" 1 report.Inspection.Verification.verified_events;
      Alcotest.(check int)
        "one verified scope" 1 report.Inspection.Verification.verified_refs;
      Alcotest.(check int)
        "one causal head" 1 report.Inspection.Verification.causal_heads)

let inspection_writes_no_index_or_repository_state () =
  with_repository (fun root bootstrap_repository scratch ->
      ignore (publish scratch "target");
      let metadata = Filename.concat root ".yeokcham" in
      let before = inventory metadata in
      ignore
        (Inspection.status ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string);
      ignore
        (Inspection.storage ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string);
      ignore
        (Inspection.verify ~root ~bootstrap_repository
        |> require_ok Inspection.error_to_string);
      Alcotest.(check bool)
        "inspection leaves canonical bytes unchanged" true
        (before = inventory metadata))

let corrupt_canonical_object_is_rejected_by_storage () =
  with_repository (fun root bootstrap_repository scratch ->
      ignore (publish scratch "target");
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      let object_ref =
        Object_store.list_object_refs objects
        |> require_ok Object_store.error_to_string
        |> List.hd
      in
      let path = Object_store.object_path objects object_ref in
      Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel "invalid");
      match Inspection.storage ~root ~bootstrap_repository with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "corrupt canonical object was accepted")

let () =
  Alcotest.run "V2 read-only inspection"
    [
      ( "unit",
        [
          Alcotest.test_case "empty repository has no derived state" `Quick
            empty_repository_has_no_derived_state;
          Alcotest.test_case "published scratch is reported and verified" `Quick
            published_scratch_is_reported_and_verified;
          Alcotest.test_case "inspection does not write an index" `Quick
            inspection_writes_no_index_or_repository_state;
          Alcotest.test_case "storage rejects corrupt canonical object" `Quick
            corrupt_canonical_object_is_rejected_by_storage;
        ] );
    ]
