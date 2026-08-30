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

let contains text needle =
  let needle_length = String.length needle in
  let rec find offset =
    if offset + needle_length > String.length text then false
    else if String.equal (String.sub text offset needle_length) needle then true
    else find (offset + 1)
  in
  needle_length > 0 && find 0

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
            [
              Gc.Checkpoint
                { snapshot = checkpoint_snapshot; reasons = [ Model.Pin ] };
            ] );
          ( content,
            [
              Gc.Checkpoint
                { snapshot = checkpoint_snapshot; reasons = [ Model.Pin ] };
            ] );
        ]
    |> require_ok Gc.error_to_string
  in
  let disposition object_id =
    List.find
      (fun object_ ->
        Store.Stored_object_id.equal object_.Gc.object_id object_id)
      plan.Gc.objects
    |> fun object_ -> object_.Gc.disposition
  in
  (match disposition state_head with
  | Gc.Retain reasons
    when List.exists
           (fun reason ->
             String.equal (Gc.root_reason_to_string reason) "state-head")
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
             String.equal
               (Gc.root_reason_to_string reason)
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
        [ info 'a' Envelope.V4_project_state 10; info 'b' Envelope.Content 20 ]
      ~reachable:[]
    |> require_ok Gc.error_to_string
  in
  let transaction = Gc.make_transaction plan |> require_ok Gc.error_to_string in
  let expected =
    Golden.read_lower_hex_file (golden_path "v4/gc-transaction-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let actual =
    Gc.encode_transaction transaction |> require_ok Gc.error_to_string
  in
  Alcotest.(check string) "transaction bytes" expected actual;
  let decoded =
    Gc.decode_transaction expected |> require_ok Gc.error_to_string
  in
  Alcotest.(check string)
    "transaction keeps its exact ID"
    (Gc.transaction_id transaction)
    (Gc.transaction_id decoded)

let transaction_rejects_unknown_or_truncated_schema () =
  let expected =
    Golden.read_lower_hex_file (golden_path "v4/gc-transaction-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let unsupported = Bytes.of_string expected in
  Bytes.set unsupported 1 (Char.chr 2);
  (match Gc.decode_transaction (Bytes.unsafe_to_string unsupported) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "collector accepted a newer transaction schema");
  match
    Gc.decode_transaction (String.sub expected 0 (String.length expected - 1))
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "collector accepted truncated transaction bytes"

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
          (fun object_ ->
            Store.Stored_object_id.equal object_.Gc.object_id orphan)
          plan.Gc.objects
      in
      (match orphan_plan.Gc.disposition with
      | Gc.Collect -> ()
      | Gc.Retain _ -> Alcotest.fail "orphan content was retained");
      let active_snapshot =
        Store.Stored_object_id.of_hex
          (Model.Snapshot_id.to_string status.Service.checkpoint)
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
      Alcotest.(check bool)
        "apply stages the orphan" true
        (List.exists
           (Store.Stored_object_id.equal orphan)
           progress.Gc.staged_objects);
      (match Store.get store orphan with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "staged orphan remained in the active store");
      let transactions =
        Gc.transactions ~root |> require_ok Gc.error_to_string
      in
      Alcotest.(check int)
        "one recoverable transaction" 1 (List.length transactions);
      Gc.restore ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
      |> require_ok Gc.error_to_string;
      ignore (Store.get store orphan |> require_ok Store.error_to_string);
      let progress = Gc.apply ~root |> require_ok Gc.error_to_string in
      let reclaimed =
        Gc.purge ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
        |> require_ok Gc.error_to_string
      in
      Alcotest.(check bool) "purge reports reclaimed bytes" true (reclaimed > 0);
      let repeated =
        Gc.purge ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
        |> require_ok Gc.error_to_string
      in
      Alcotest.(check int) "repeated purge reclaims no bytes" 0 repeated;
      match Store.get store orphan with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "purge left the orphan in the active store")

let named_manifest_and_chunk_closure_is_not_collectable () =
  with_directory "yeokcham-v4-gc-manifest-" (fun root ->
      write_file root "large.bin"
        (String.make (Snapshot.inline_file_limit + 1) 'x');
      ignore (initialize root);
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
      let plan = Gc.plan ~root |> require_ok Gc.error_to_string in
      let manifest_and_chunks =
        Store.list_objects store
        |> require_ok Store.error_to_string
        |> List.filter (fun object_ ->
            object_.Store.object_type = Envelope.File_manifest
            || object_.Store.object_type = Envelope.Chunk)
      in
      Alcotest.(check bool)
        "large file has a manifest closure" true
        (manifest_and_chunks <> []);
      List.iter
        (fun info ->
          let planned =
            List.find
              (fun object_ ->
                Store.Stored_object_id.equal object_.Gc.object_id info.Store.id)
              plan.Gc.objects
          in
          match planned.Gc.disposition with
          | Gc.Retain _ -> ()
          | Gc.Collect ->
              Alcotest.fail "reachable manifest closure was collectable")
        manifest_and_chunks)

let shared_snapshot_closure_has_an_explicit_retention_reason () =
  with_directory "yeokcham-v4-gc-shared-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      let shared =
        Service.share ~root
          ~change:(Model.Change_id.of_string "change-gc" |> Result.get_ok)
          ~revision:(Model.Revision_id.of_string "revision-gc" |> Result.get_ok)
        |> require_ok Service.error_to_string
      in
      Service.compact ~root ~keep_recent:0 ~dry_run:false
      |> require_ok Service.error_to_string
      |> ignore;
      let shared_snapshot =
        Model.Snapshot_id.to_string shared.Service.checkpoint
        |> Store.Stored_object_id.of_hex |> Result.get_ok
      in
      let plan = Gc.plan ~root |> require_ok Gc.error_to_string in
      let planned =
        List.find
          (fun object_ ->
            Store.Stored_object_id.equal object_.Gc.object_id shared_snapshot)
          plan.Gc.objects
      in
      match planned.Gc.disposition with
      | Gc.Retain reasons ->
          Alcotest.(check bool)
            "share root is explained" true
            (List.exists
               (fun reason ->
                 contains (Gc.root_reason_to_string reason) "share")
               reasons)
      | Gc.Collect -> Alcotest.fail "shared snapshot was collectable")

let initialized_empty_worktree_has_no_collectible_objects () =
  with_directory "yeokcham-v4-gc-empty-" (fun root ->
      ignore (initialize root);
      let plan = Gc.plan ~root |> require_ok Gc.error_to_string in
      Alcotest.(check int)
        "empty worktree has no candidates" 0 plan.Gc.collectible_bytes)

let purge_recovers_after_a_durable_marker_before_unlink () =
  with_directory "yeokcham-v4-gc-purge-recovery-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
      let orphan =
        Snapshot.Content.store store "interrupted purge"
        |> require_ok Snapshot.error_to_string
        |> Snapshot.Content.stored_object_id
      in
      let progress = Gc.apply ~root |> require_ok Gc.error_to_string in
      let transaction = progress.Gc.progress_transaction in
      let transaction_directory =
        Filename.concat
          (Filename.concat (Filename.concat root ".yeokcham") "gc")
          ("v4-gc-" ^ Gc.transaction_id transaction)
      in
      let purge_directory = Filename.concat transaction_directory "purged" in
      Unix.mkdir purge_directory 0o700;
      Out_channel.with_open_bin
        (Filename.concat purge_directory (Store.Stored_object_id.to_hex orphan))
        (fun _ -> ());
      (match Gc.restore ~root ~id:(Gc.transaction_id transaction) with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "restore crossed a durable purge marker");
      Gc.purge ~root ~id:(Gc.transaction_id transaction)
      |> require_ok Gc.error_to_string
      |> ignore;
      let terminal =
        Gc.transactions ~root |> require_ok Gc.error_to_string |> List.hd
      in
      Alcotest.(check bool)
        "purge is recorded as terminal" true terminal.Gc.purge_started;
      Alcotest.(check bool)
        "purge records the unlinked object" true
        (List.exists
           (Store.Stored_object_id.equal orphan)
           terminal.Gc.purged_objects);
      match Store.get store orphan with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail "resumed purge left the orphan in the active store")

let missing_reachable_closure_blocks_planning_without_quarantine_mutation () =
  with_directory "yeokcham-v4-gc-missing-closure-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let status = initialize root in
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
      let snapshot =
        Model.Snapshot_id.to_string status.Service.checkpoint
        |> Store.Stored_object_id.of_hex |> Result.get_ok
        |> Snapshot.Snapshot.of_stored_object_id
      in
      let snapshot =
        Snapshot.Snapshot.load store snapshot
        |> require_ok Snapshot.error_to_string
      in
      let tree =
        Snapshot.Tree.load store (Snapshot.Snapshot.root snapshot)
        |> require_ok Snapshot.error_to_string
      in
      let content =
        Snapshot.Tree.entries tree
        |> List.find_map (fun (_, entry) ->
            match entry with
            | Snapshot.Tree.File { content; _ } -> Some content
            | Snapshot.Tree.Directory _ -> None)
        |> Option.get
      in
      Unix.unlink
        (Store.object_path store (Snapshot.Content.stored_object_id content));
      (match Gc.plan ~root with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "planner accepted a missing reachable object");
      Alcotest.(check bool)
        "missing closure creates no quarantine" false
        (Sys.file_exists
           (Filename.concat (Filename.concat root ".yeokcham") "gc")))

let state_head_change_after_quarantine_blocks_purge () =
  with_directory "yeokcham-v4-gc-stale-head-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      let second = Service.save ~root |> require_ok Service.error_to_string in
      let second =
        match second with
        | Service.Saved status -> status.Service.checkpoint
        | Service.Unchanged _ -> Alcotest.fail "second snapshot was not saved"
      in
      write_file root "main.ml" "let version = 3\n";
      ignore (Service.save ~root |> require_ok Service.error_to_string);
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let before_compaction =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      Service.compact ~root ~keep_recent:0 ~dry_run:false
      |> require_ok Service.error_to_string
      |> ignore;
      let candidate =
        Model.Snapshot_id.to_string second
        |> Store.Stored_object_id.of_hex |> Result.get_ok
      in
      let progress = Gc.apply ~root |> require_ok Gc.error_to_string in
      Alcotest.(check bool)
        "compacted checkpoint is quarantined" true
        (List.exists
           (Store.Stored_object_id.equal candidate)
           progress.Gc.staged_objects);
      let current =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      V4_store.save repository ~expected:current.V4_store.head
        ~project:before_compaction.V4_store.project
      |> require_ok V4_store.error_to_string
      |> ignore;
      (match
         Gc.purge ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
       with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail "purge accepted a state head that restored its root");
      let retained_transaction =
        Gc.transactions ~root |> require_ok Gc.error_to_string |> List.hd
      in
      Alcotest.(check bool)
        "stale purge leaves candidate quarantined" true
        (List.exists
           (Store.Stored_object_id.equal candidate)
           retained_transaction.Gc.staged_objects);
      Gc.restore ~root ~id:(Gc.transaction_id progress.Gc.progress_transaction)
      |> require_ok Gc.error_to_string;
      ignore (Gc.plan ~root |> require_ok Gc.error_to_string))

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
      Out_channel.with_open_bin (Store.object_path store corrupt)
        (fun channel -> Out_channel.output_string channel "not an object");
      (match Gc.plan ~root with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "planner accepted a corrupt object");
      Alcotest.(check bool)
        "failed planning creates no quarantine" false
        (Sys.file_exists
           (Filename.concat (Filename.concat root ".yeokcham") "gc")))

let () =
  Alcotest.run "V4 garbage collection"
    [
      ( "planner",
        [
          Alcotest.test_case "pure classification retains roots" `Quick
            pure_classification_keeps_reachable_objects_and_unsupported_types;
          Alcotest.test_case "canonical transaction record" `Quick
            transaction_record_has_stable_canonical_bytes;
          Alcotest.test_case "transaction rejects unsupported schema" `Quick
            transaction_rejects_unknown_or_truncated_schema;
          Alcotest.test_case "quarantine restore and purge" `Quick
            local_quarantine_restore_and_purge_are_explicit;
          Alcotest.test_case "reachable manifest closure is retained" `Quick
            named_manifest_and_chunk_closure_is_not_collectable;
          Alcotest.test_case "shared closure has an explicit root" `Quick
            shared_snapshot_closure_has_an_explicit_retention_reason;
          Alcotest.test_case "empty worktree has no candidates" `Quick
            initialized_empty_worktree_has_no_collectible_objects;
          Alcotest.test_case "purge resumes after its durable marker" `Quick
            purge_recovers_after_a_durable_marker_before_unlink;
          Alcotest.test_case "missing reachable closure blocks planning" `Quick
            missing_reachable_closure_blocks_planning_without_quarantine_mutation;
          Alcotest.test_case "state-head change blocks stale purge" `Quick
            state_head_change_after_quarantine_blocks_purge;
          Alcotest.test_case "corruption blocks planning" `Quick
            corrupted_object_blocks_planning_without_quarantine_mutation;
        ] );
    ]
