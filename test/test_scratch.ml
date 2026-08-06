module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Golden = Yeokcham_testkit.Golden_fixture
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope

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
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let with_history run =
  with_directory "yeokcham-scratch-source-" (fun source ->
      with_directory "yeokcham-scratch-store-" (fun store_root ->
          write_file (Filename.concat source "file") "base\000bytes";
          Unix.mkdir (Filename.concat source "nested") 0o700;
          write_file
            (Filename.concat (Filename.concat source "nested") "child")
            "child";
          let store =
            Store.init ~root:store_root |> require_ok Store.error_to_string
          in
          let scratch = Scratch.open_repository store in
          let base_id, _ =
            Snapshot.scan ~root:source ~store
            |> require_ok Snapshot.error_to_string
          in
          let initial =
            Scratch.create_initial scratch ~snapshot:base_id ~created_at:10L
            |> require_ok Scratch.error_to_string
          in
          write_file (Filename.concat source "file") "changed\000bytes";
          Unix.chmod (Filename.concat source "file") 0o755;
          write_file (Filename.concat source "new") "new";
          let changed_id, _ =
            Snapshot.scan ~root:source ~store
            |> require_ok Snapshot.error_to_string
          in
          let changed =
            Scratch.checkpoint scratch ~snapshot:changed_id
              ~source:Scratch.Explicit ~observed_at:20L ~created_at:21L
            |> require_ok Scratch.error_to_string
          in
          let changed =
            match changed with
            | Scratch.Created checkpoint -> checkpoint
            | Scratch.Unchanged _ ->
                Alcotest.fail "changed scan was not checkpointed"
          in
          run source store_root store scratch initial changed))

let scratch_records_replay_and_reopen () =
  with_history (fun _source store_root _store scratch _initial changed ->
      let timeline =
        Scratch.timeline scratch ~limit:8 ()
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int) "timeline depth" 2 (List.length timeline);
      let bounded =
        Scratch.timeline scratch ~limit:1 ()
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int)
        "timeline obeys bounded traversal" 1 (List.length bounded);
      let newest = List.hd timeline in
      Alcotest.(check bool)
        "newest checkpoint is changed checkpoint" true
        (Scratch.Checkpoint_id.equal
           (Scratch.Checkpoint.id newest.Scratch.checkpoint)
           (Scratch.Checkpoint.id changed));
      Alcotest.(check int) "initial depth" 1 (List.nth timeline 1).Scratch.depth;
      Alcotest.(check bool)
        "initial checkpoint is retained" true
        (List.mem Scratch.Recent_window
           (List.nth timeline 1).Scratch.effective_retention);
      let reopened_store =
        Store.open_repository ~root:store_root
        |> require_ok Store.error_to_string
      in
      let reopened = Scratch.open_repository reopened_store in
      let reopened_head =
        Scratch.head reopened |> require_ok Scratch.error_to_string
      in
      match reopened_head with
      | Some checkpoint ->
          Alcotest.(check bool)
            "reopened head is retained" true
            (Scratch.Checkpoint_id.equal
               (Scratch.Checkpoint.id checkpoint)
               (Scratch.Checkpoint.id changed))
      | None -> Alcotest.fail "scratch head disappeared after reopen")

let pinning_is_separate_from_checkpoint_identity () =
  with_history (fun _source _store_root store scratch _ changed ->
      let checkpoint_id = Scratch.Checkpoint.id changed in
      Scratch.pin scratch checkpoint_id ~changed_at:30L
      |> require_ok Scratch.error_to_string;
      let pinned =
        Scratch.timeline scratch ~limit:1 ()
        |> require_ok Scratch.error_to_string
        |> List.hd
      in
      Alcotest.(check bool)
        "pin preserves checkpoint identity" true
        (Scratch.Checkpoint_id.equal checkpoint_id
           (Scratch.Checkpoint.id pinned.Scratch.checkpoint));
      Alcotest.(check bool)
        "pin becomes effective retention" true
        (List.mem Scratch.User_pinned pinned.Scratch.effective_retention);
      Scratch.unpin scratch checkpoint_id ~changed_at:31L
      |> require_ok Scratch.error_to_string;
      let unpinned =
        Scratch.timeline scratch ~limit:1 ()
        |> require_ok Scratch.error_to_string
        |> List.hd
      in
      Alcotest.(check bool)
        "unpin preserves checkpoint identity" true
        (Scratch.Checkpoint_id.equal checkpoint_id
           (Scratch.Checkpoint.id unpinned.Scratch.checkpoint));
      Alcotest.(check bool)
        "unpin removes effective user retention" false
        (List.mem Scratch.User_pinned unpinned.Scratch.effective_retention);
      let head =
        Store.read_ref store ~name:"retention-head"
        |> require_ok Store.error_to_string
      in
      Alcotest.(check bool) "retention head exists" true (Option.is_some head))

let scratch_head_is_compare_and_swap () =
  with_history (fun _source _store_root store _ _ changed ->
      let actual =
        Store.read_ref store ~name:"scratch-head"
        |> require_ok Store.error_to_string
      in
      (match actual with
      | Some reference ->
          Alcotest.(check int64)
            "checkpoint publications advance generation" 1L
            (Store.Mutable_ref.generation reference)
      | None -> Alcotest.fail "scratch-head is missing");
      let target =
        Scratch.Checkpoint_id.stored_object_id (Scratch.Checkpoint.id changed)
      in
      (match
         Store.compare_and_swap_ref store ~name:"scratch-head" ~expected:None
           ~target:(Some target)
       with
      | Error error ->
          Alcotest.(check bool)
            "stale CAS is explicit" true
            (String.starts_with
               ~prefix:"mutable ref scratch-head changed concurrently: "
               (Store.error_to_string error))
      | Ok _ -> Alcotest.fail "scratch-head accepted stale compare-and-swap");
      let after =
        Store.read_ref store ~name:"scratch-head"
        |> require_ok Store.error_to_string
      in
      Alcotest.(check bool)
        "failed CAS preserves ref" true
        (Option.equal Store.Mutable_ref.equal actual after))

let failed_event_publication_does_not_advance_head () =
  with_history (fun source _store_root store scratch _ changed ->
      write_file (Filename.concat source "file") "publication failure target";
      let resulting, _ =
        Snapshot.scan ~root:source ~store |> require_ok Snapshot.error_to_string
      in
      let parent_snapshot =
        Snapshot.Snapshot.load store (Scratch.Checkpoint.snapshot changed)
        |> require_ok Snapshot.error_to_string
      in
      let resulting_snapshot =
        Snapshot.Snapshot.load store resulting
        |> require_ok Snapshot.error_to_string
      in
      let from =
        Scratch.State.of_snapshot store parent_snapshot
        |> require_ok Scratch.error_to_string
      in
      let to_ =
        Scratch.State.of_snapshot store resulting_snapshot
        |> require_ok Scratch.error_to_string
      in
      let operations = Scratch.State.diff ~from ~to_ in
      let rec choose_event timestamp =
        let event =
          Scratch.Event.create
            ~parent:(Scratch.Checkpoint.id changed)
            ~base:(Scratch.Checkpoint.snapshot changed)
            ~resulting ~operations ~source:Scratch.Explicit
            ~observed_at:timestamp
        in
        let object_path =
          Store.object_path store
            (Scratch.Event_id.stored_object_id (Scratch.Event.id event))
        in
        let first_shard = Filename.dirname (Filename.dirname object_path) in
        if Sys.file_exists first_shard then choose_event (Int64.succ timestamp)
        else (first_shard, timestamp)
      in
      let first_shard, timestamp = choose_event 100L in
      write_file first_shard "block scratch event publication";
      (match
         Scratch.checkpoint scratch ~snapshot:resulting ~source:Scratch.Explicit
           ~observed_at:timestamp ~created_at:200L
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "checkpoint accepted a failed event publication");
      match Scratch.head scratch |> require_ok Scratch.error_to_string with
      | Some checkpoint ->
          Alcotest.(check bool)
            "failed publication preserves scratch-head" true
            (Scratch.Checkpoint_id.equal
               (Scratch.Checkpoint.id checkpoint)
               (Scratch.Checkpoint.id changed))
      | None -> Alcotest.fail "failed publication removed scratch-head")

let unsupported_record_versions_are_rejected () =
  with_history (fun _source _store_root store _scratch _initial _changed ->
      let payload =
        Encoding.array
          [
            Encoding.integer 2L;
            Encoding.null;
            Encoding.null;
            Encoding.null;
            Encoding.null;
            Encoding.null;
            Encoding.null;
          ]
        |> require_ok Encoding.construction_error_to_string
      in
      let envelope =
        Envelope.create ~object_type:Envelope.Scratch_event
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
        |> require_ok Envelope.creation_error_to_string
      in
      let identity =
        Store.put store envelope |> require_ok Store.error_to_string
      in
      match
        Scratch.Event.load store (Scratch.Event_id.of_stored_object_id identity)
      with
      | Error error ->
          Alcotest.(check bool)
            "unsupported version is explicit" true
            (String.starts_with ~prefix:"unsupported scratch schema version: "
               (Scratch.error_to_string error))
      | Ok _ -> Alcotest.fail "unsupported scratch event version was accepted")

let corrupt_or_missing_records_are_rejected () =
  with_history (fun _source store_root store scratch _ changed ->
      write_file
        (Filename.concat
           (Filename.concat (Filename.concat store_root ".yeokcham") "refs")
           "scratch-head")
        "corrupt";
      (match Scratch.head scratch with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "corrupt scratch-head was accepted");
      let event =
        match Scratch.Checkpoint.event changed with
        | Some event -> event
        | None -> Alcotest.fail "non-initial checkpoint lacks event"
      in
      let event_path =
        Store.object_path store (Scratch.Event_id.stored_object_id event)
      in
      Unix.unlink event_path;
      let reopened = Scratch.open_repository store in
      match
        Scratch.timeline reopened
          ~start:(Scratch.Checkpoint.id changed)
          ~limit:2 ()
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "missing scratch event was accepted")

let disposable_indexes_do_not_affect_recovery () =
  with_history (fun _source store_root store scratch _ changed ->
      let index_directory =
        Filename.concat (Filename.concat store_root ".yeokcham") "indexes"
      in
      Unix.mkdir index_directory 0o700;
      let stale_index = Filename.concat index_directory "scratch.cache" in
      write_file stale_index "corrupt disposable cache";
      let before =
        Scratch.timeline scratch ~limit:1 ()
        |> require_ok Scratch.error_to_string
        |> List.hd
      in
      Unix.unlink stale_index;
      Unix.rmdir index_directory;
      let reopened = Scratch.open_repository store in
      let after =
        Scratch.timeline reopened ~limit:1 ()
        |> require_ok Scratch.error_to_string
        |> List.hd
      in
      Alcotest.(check bool)
        "cache does not define timeline meaning" true
        (Scratch.Checkpoint_id.equal
           (Scratch.Checkpoint.id before.Scratch.checkpoint)
           (Scratch.Checkpoint.id after.Scratch.checkpoint));
      Alcotest.(check bool)
        "canonical parent chain remains available" true
        (Scratch.Checkpoint_id.equal
           (Scratch.Checkpoint.id after.Scratch.checkpoint)
           (Scratch.Checkpoint.id changed)))

let no_change_does_not_create_a_checkpoint () =
  with_history (fun _source _store_root _store scratch _ changed ->
      let result =
        Scratch.checkpoint scratch
          ~snapshot:(Scratch.Checkpoint.snapshot changed)
          ~source:Scratch.Scan ~observed_at:40L ~created_at:41L
        |> require_ok Scratch.error_to_string
      in
      match result with
      | Scratch.Unchanged checkpoint ->
          Alcotest.(check bool)
            "unchanged checkpoint remains head" true
            (Scratch.Checkpoint_id.equal
               (Scratch.Checkpoint.id checkpoint)
               (Scratch.Checkpoint.id changed))
      | Scratch.Created _ -> Alcotest.fail "unchanged scan created a checkpoint")

let polling_debounces_and_skips_unchanged_snapshots () =
  with_history (fun _source _store_root _store _scratch initial changed ->
      let base = Scratch.Checkpoint.snapshot initial in
      let changed = Scratch.Checkpoint.snapshot changed in
      let polling = Scratch.Polling.create ~debounce_ms:10 in
      let polling, checkpoint =
        Scratch.Polling.observe polling ~head:base ~observed:base ~now_ms:0L
      in
      Alcotest.(check bool)
        "unchanged snapshot emits no checkpoint" false checkpoint;
      let polling, checkpoint =
        Scratch.Polling.observe polling ~head:base ~observed:changed ~now_ms:0L
      in
      Alcotest.(check bool)
        "first changed observation is debounced" false checkpoint;
      let polling, checkpoint =
        Scratch.Polling.observe polling ~head:base ~observed:changed ~now_ms:9L
      in
      Alcotest.(check bool) "debounce remains pending" false checkpoint;
      let polling, checkpoint =
        Scratch.Polling.observe polling ~head:base ~observed:changed ~now_ms:10L
      in
      Alcotest.(check bool) "stable changed snapshot emits once" true checkpoint;
      let _polling, duplicate =
        Scratch.Polling.observe polling ~head:changed ~observed:changed
          ~now_ms:20L
      in
      Alcotest.(check bool) "new head suppresses duplicate" false duplicate)

let v1_golden_bytes_are_stable () =
  with_history (fun _source store_root store scratch _initial changed ->
      Scratch.pin scratch (Scratch.Checkpoint.id changed) ~changed_at:30L
      |> require_ok Scratch.error_to_string;
      let event =
        match Scratch.Checkpoint.event changed with
        | Some value -> value
        | None -> Alcotest.fail "non-initial checkpoint lacks event"
      in
      let envelope identity =
        Store.get store identity
        |> require_ok Store.error_to_string
        |> Yeokcham_envelope.encode
      in
      let refreshed_golden name actual =
        Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
        |> require_ok Fun.id
      in
      let event_bytes = envelope (Scratch.Event_id.stored_object_id event) in
      let checkpoint_bytes =
        envelope
          (Scratch.Checkpoint_id.stored_object_id
             (Scratch.Checkpoint.id changed))
      in
      Alcotest.(check string)
        "scratch event v1"
        (refreshed_golden "scratch-v1-event.yeok.hex" event_bytes)
        event_bytes;
      Alcotest.(check string)
        "scratch checkpoint v1"
        (refreshed_golden "scratch-v1-checkpoint.yeok.hex" checkpoint_bytes)
        checkpoint_bytes;
      let retention =
        Store.read_ref store ~name:"retention-head"
        |> require_ok Store.error_to_string
        |> Option.get |> Store.Mutable_ref.target |> Option.get
      in
      let retention_bytes = envelope retention in
      Alcotest.(check string)
        "retention change v1"
        (refreshed_golden "scratch-v1-retention-change.yeok.hex" retention_bytes)
        retention_bytes;
      let head_bytes =
        In_channel.with_open_bin
          (Filename.concat
             (Filename.concat (Filename.concat store_root ".yeokcham") "refs")
             "scratch-head")
          In_channel.input_all
      in
      Alcotest.(check string)
        "scratch-head ref v1"
        (refreshed_golden "scratch-v1-head.ref.hex" head_bytes)
        head_bytes)

let () =
  Alcotest.run "scratch records"
    [
      ( "unit",
        [
          Alcotest.test_case "records replay and survive reopen" `Quick
            scratch_records_replay_and_reopen;
          Alcotest.test_case "pinning is separate from checkpoint identity"
            `Quick pinning_is_separate_from_checkpoint_identity;
          Alcotest.test_case "scratch-head uses compare-and-swap" `Quick
            scratch_head_is_compare_and_swap;
          Alcotest.test_case "failed event publication preserves scratch-head"
            `Quick failed_event_publication_does_not_advance_head;
          Alcotest.test_case "corrupt and missing records reject" `Quick
            corrupt_or_missing_records_are_rejected;
          Alcotest.test_case "disposable indexes do not affect recovery" `Quick
            disposable_indexes_do_not_affect_recovery;
          Alcotest.test_case "unsupported record versions reject" `Quick
            unsupported_record_versions_are_rejected;
          Alcotest.test_case "unchanged scan creates no checkpoint" `Quick
            no_change_does_not_create_a_checkpoint;
          Alcotest.test_case "polling debounces and skips unchanged snapshots"
            `Quick polling_debounces_and_skips_unchanged_snapshots;
          Alcotest.test_case "v1 golden bytes are stable" `Quick
            v1_golden_bytes_are_stable;
        ] );
    ]
