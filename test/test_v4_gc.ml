module Envelope = Yeokcham_envelope
module Gc = Yeokcham_v4_gc
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
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
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let id character =
  Store.Stored_object_id.of_hex (String.make 64 character) |> Result.get_ok

let info character object_type bytes =
  { Store.id = id character; object_type; stored_bytes = bytes }

let snapshot value = Model.Snapshot_id.of_string value |> Result.get_ok

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let pure_classification_keeps_reachable_objects_and_unsupported_types () =
  let state_head = id 'a' in
  let checkpoint = id 'b' in
  let content = id 'c' in
  let legacy = id 'd' in
  let checkpoint_snapshot = snapshot (String.make 64 'b') in
  let plan =
    Gc.classify ~state_head
      ~objects:
        [
          info 'a' Envelope.V4_project_state 10;
          info 'b' Envelope.Snapshot 20;
          info 'c' Envelope.Content 30;
          info 'd' Envelope.Git_mapping 40;
        ]
      ~reachable:
        [
          ( checkpoint,
            [ Gc.Checkpoint { snapshot = checkpoint_snapshot; reasons = [ Model.Pin ] } ] );
          ( content,
            [ Gc.Checkpoint { snapshot = checkpoint_snapshot; reasons = [ Model.Pin ] } ] );
        ]
    |> require_ok Gc.error_to_string
  in
  let disposition object_id =
    List.find (fun object_ -> Store.Stored_object_id.equal object_.Gc.object_id object_id)
      plan.Gc.objects
    |> fun object_ -> object_.Gc.disposition
  in
  (match disposition state_head with
  | Gc.Retain reasons
    when List.exists
           (fun reason -> String.equal (Gc.root_reason_to_string reason) "state-head")
           reasons ->
      ()
  | Gc.Retain _ | Gc.Collect -> Alcotest.fail "state head was not retained");
  (match disposition content with
  | Gc.Retain _ -> ()
  | Gc.Collect -> Alcotest.fail "reachable content was collectable");
  (match disposition legacy with
  | Gc.Retain reasons
    when List.exists
           (fun reason ->
             String.equal (Gc.root_reason_to_string reason)
               (Printf.sprintf "unsupported-object-type:%d"
                  (Envelope.object_type_code Envelope.Git_mapping)))
           reasons ->
      ()
  | Gc.Retain _ | Gc.Collect ->
      Alcotest.fail "unsupported object category was not retained");
  Alcotest.(check int) "no object was collectable" 0 plan.Gc.collectible_bytes

let transaction_record_has_stable_canonical_bytes () =
  let plan =
    Gc.classify ~state_head:(id 'a')
      ~objects:
        [
          info 'a' Envelope.V4_project_state 10;
          info 'b' Envelope.Content 20;
        ]
      ~reachable:[]
    |> require_ok Gc.error_to_string
  in
  let transaction = Gc.make_transaction plan |> require_ok Gc.error_to_string in
  let expected =
    Golden.read_lower_hex_file (golden_path "v4/gc-transaction-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let actual = Gc.encode_transaction transaction |> require_ok Gc.error_to_string in
  Alcotest.(check string) "transaction bytes" expected actual;
  let decoded = Gc.decode_transaction expected |> require_ok Gc.error_to_string in
  Alcotest.(check string) "transaction keeps its exact ID"
    (Gc.transaction_id transaction)
    (Gc.transaction_id decoded)

let initialize root =
  Service.init ~root
    ~creator:(Model.Device_id.of_string "device-alice" |> Result.get_ok)
    ~username:(Model.Username.of_string "alice" |> Result.get_ok)
    ~initial_draft:(Model.Draft_id.of_string "draft-one" |> Result.get_ok)
    ~title:"gc work"
  |> require_ok Service.error_to_string

let local_quarantine_restore_and_purge_are_explicit () =
  with_directory "yeokcham-v4-gc-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let status = initialize root in
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
      let orphan =
        Snapshot.Content.store store "unreachable bytes"
        |> require_ok Snapshot.error_to_string
        |> Snapshot.Content.stored_object_id
      in
      let plan = Gc.plan ~root |> require_ok Gc.error_to_string in
      let orphan_plan =
        List.find
          (fun object_ -> Store.Stored_object_id.equal object_.Gc.object_id orphan)
          plan.Gc.objects
      in
      (match orphan_plan.Gc.disposition with
      | Gc.Collect -> ()
      | Gc.Retain _ -> Alcotest.fail "orphan content was retained");
      let active_snapshot =
        Store.Stored_object_id.of_hex (Model.Snapshot_id.to_string status.Service.checkpoint)
        |> Result.get_ok
      in
      let snapshot_plan =
        List.find
          (fun object_ ->
            Store.Stored_object_id.equal object_.Gc.object_id active_snapshot)
          plan.Gc.objects
      in
      (match snapshot_plan.Gc.disposition with
      | Gc.Retain _ -> ()
      | Gc.Collect -> Alcotest.fail "current checkpoint was collectable");
      let progress = Gc.apply ~root |> require_ok Gc.error_to_string in
      Alcotest.(check bool) "apply stages the orphan" true
        (List.exists (Store.Stored_object_id.equal orphan) progress.Gc.staged_objects);
      (match Store.get store orphan with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "staged orphan remained in the active store");
      let transactions = Gc.transactions ~root |> require_ok Gc.error_to_string in
      Alcotest.(check int) "one recoverable transaction" 1 (List.length transactions);
      Gc.restore ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
      |> require_ok Gc.error_to_string;
      ignore (Store.get store orphan |> require_ok Store.error_to_string);
      let progress = Gc.apply ~root |> require_ok Gc.error_to_string in
      let reclaimed =
        Gc.purge ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
        |> require_ok Gc.error_to_string
      in
      Alcotest.(check bool) "purge reports reclaimed bytes" true (reclaimed > 0);
      match Store.get store orphan with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "purge left the orphan in the active store")

let corrupted_object_blocks_planning_without_quarantine_mutation () =
  with_directory "yeokcham-v4-gc-corrupt-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
      let corrupt = id 'e' in
      let directory = Filename.dirname (Store.object_path store corrupt) in
      Unix.mkdir (Filename.dirname directory) 0o700;
      Unix.mkdir directory 0o700;
      Out_channel.with_open_bin (Store.object_path store corrupt) (fun channel ->
          Out_channel.output_string channel "not an object");
      (match Gc.plan ~root with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "planner accepted a corrupt object");
      Alcotest.(check bool) "failed planning creates no quarantine" false
        (Sys.file_exists (Filename.concat (Filename.concat root ".yeokcham") "gc")))

let () =
  Alcotest.run "V4 garbage collection"
    [
      ( "planner",
        [
          Alcotest.test_case "pure classification retains roots" `Quick
            pure_classification_keeps_reachable_objects_and_unsupported_types;
          Alcotest.test_case "canonical transaction record" `Quick
            transaction_record_has_stable_canonical_bytes;
          Alcotest.test_case "quarantine restore and purge" `Quick
            local_quarantine_restore_and_purge_are_explicit;
          Alcotest.test_case "corruption blocks planning" `Quick
            corrupted_object_blocks_planning_without_quarantine_mutation;
        ] );
    ]
