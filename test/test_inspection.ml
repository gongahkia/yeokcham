module Capsule = Yeokcham_capsule
module Capsule_store = Yeokcham_capsule_store
module Id = Yeokcham_id
module Inspection = Yeokcham_inspection
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace_store = Yeokcham_workspace_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok
let workspace_id seed = Id.Workspace_id.of_bytes (raw_id seed) |> Result.get_ok

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
  let root = Filename.temp_file "yeokcham-inspection-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      run root store)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let checkpoint scratch store root timestamp =
  let snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:timestamp ~created_at:timestamp
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let inspection_is_read_only_complete_and_compaction_safe () =
  with_repository (fun root store ->
      let tracked = Filename.concat root "tracked" in
      write_file tracked "zero";
      let scratch = Scratch.open_repository store in
      let initial_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:initial_snapshot ~created_at:0L
        |> require_ok Scratch.error_to_string
        |> Scratch.Checkpoint.id
      in
      write_file tracked "one";
      let changed = checkpoint scratch store root 1L in
      ignore
        (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
           ~id:(capsule_id 1) ~title:"inspection" ~description:"inspection"
           ~dependencies:[] ~evidence:[] ~from:initial ~target:changed
           ~created_at:2L ~changed_at:2L ()
        |> require_ok Capsule_store.error_to_string);
      ignore
        (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
           ~id:(capsule_id 2) ~title:"dependent" ~description:"dependent"
           ~dependencies:
             [
               Capsule.Requires_capsule
                 { capsule = capsule_id 1; revision = None };
             ]
           ~evidence:[] ~from:initial ~target:changed ~created_at:3L
           ~changed_at:3L ()
        |> require_ok Capsule_store.error_to_string);
      let before =
        Store.list_objects store |> require_ok Store.error_to_string
      in
      let timeline =
        Inspection.timeline store ~limit:8
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int) "timeline entry count" 2 (List.length timeline);
      let newest = List.hd timeline in
      Alcotest.(check (list string))
        "timeline reports changed paths" [ "tracked" ]
        newest.Inspection.changed_paths;
      Alcotest.(check int64)
        "timeline reports exact snapshot byte count" 3L
        newest.Inspection.snapshot_bytes;
      Alcotest.(check string)
        "timeline reports validation state" "not-recorded"
        newest.Inspection.validation_state;
      let status =
        Inspection.status store |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "two current capsules" 2 status.Inspection.capsule_count;
      Alcotest.(check int)
        "inventory count in status" (List.length before)
        status.Inspection.repository_object_count;
      let storage =
        Inspection.storage store |> require_ok Inspection.error_to_string
      in
      let capsule_bucket =
        List.find
          (fun (stat : Inspection.storage_stat) ->
            stat.Inspection.bucket = Inspection.Capsule)
          storage.Inspection.buckets
      in
      Alcotest.(check bool)
        "capsule objects are accounted separately" true
        (capsule_bucket.Inspection.object_count >= 4);
      Alcotest.(check int)
        "two retained logical checkpoints" 2
        storage.Inspection.retained_checkpoints;
      Alcotest.(check bool)
        "retained physical checkpoint bytes are reported" true
        (Int64.compare storage.Inspection.retained_checkpoint_object_bytes 0L
        > 0);
      let verification =
        Inspection.verify store |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "all objects verified" (List.length before)
        verification.Inspection.verified_objects;
      Alcotest.(check int)
        "two current capsule refs verified" 2
        verification.Inspection.verified_capsules;
      Alcotest.(check int)
        "two capsule revisions verified" 2
        verification.Inspection.verified_capsule_revisions;
      let after =
        Store.list_objects store |> require_ok Store.error_to_string
      in
      Alcotest.(check int)
        "inspection does not write objects" (List.length before)
        (List.length after))

let graph_is_read_only_and_preserves_native_boundaries () =
  with_repository (fun root store ->
      let tracked = Filename.concat root "tracked" in
      write_file tracked "zero";
      let scratch = Scratch.open_repository store in
      let initial_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:initial_snapshot ~created_at:0L
        |> require_ok Scratch.error_to_string
        |> Scratch.Checkpoint.id
      in
      write_file tracked "one";
      let changed = checkpoint scratch store root 1L in
      let capsule =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch
          ~id:(capsule_id 10) ~title:"safe\nname" ~description:"history"
          ~dependencies:[] ~evidence:[] ~from:initial ~target:changed
          ~created_at:2L ~changed_at:2L ()
        |> require_ok Capsule_store.error_to_string
      in
      let capsule_revision =
        Capsule_store.Durable.resolved_revision capsule
        |> Capsule_store.revision_id
      in
      ignore
        (Workspace_store.Durable.create ~store ~id:(workspace_id 11)
           ~base:initial_snapshot ~name:(Some "inspection workspace")
           ~description:None ~created_at:3L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_revision ~store
           ~workspace:(workspace_id 11) ~revision:capsule_revision
           ~expected_generation:None ~created_at:4L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.materialise ~store ~scratch ~root
           ~workspace:(workspace_id 11) ~observed_at:5L ~created_at:5L
           ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string);
      let release =
        Release.Durable.create ~store ~workspace:(workspace_id 11) ~parents:[]
          ~commands:[] ~message:(Some "first release") ~observed_at:6L
          ~created_at:6L ()
        |> require_ok Release.error_to_string
      in
      ignore
        (Release.Durable.create ~store ~workspace:(workspace_id 11)
           ~parents:[ Release.release_id release ]
           ~commands:[] ~message:(Some "second release") ~observed_at:7L
           ~created_at:7L ()
        |> require_ok Release.error_to_string);
      let before =
        Store.list_objects store |> require_ok Store.error_to_string
      in
      let graph =
        Inspection.history_graph store ~scope:Inspection.Combined_history
        |> require_ok Inspection.error_to_string
        |> Inspection.render_history_graph
      in
      let contains needle = List.exists (String.equal needle) graph in
      Alcotest.(check bool)
        "scratch heading" true
        (contains "scratch (retained checkpoints, newest first)");
      Alcotest.(check bool)
        "capsule heading" true
        (contains "capsules (immutable revisions)");
      Alcotest.(check bool)
        "workspace heading" true
        (contains "workspaces (selected capsule revisions)");
      Alcotest.(check bool)
        "release heading" true
        (contains "releases (immutable reproducible snapshots)");
      Alcotest.(check bool)
        "newlines are escaped" true
        (List.exists (fun line -> String.contains line '\\') graph);
      Alcotest.(check bool)
        "release parent is rendered" true
        (List.exists
           (fun line ->
             String.starts_with ~prefix:"  |-- parent -> release" line)
           graph);
      let focused =
        Inspection.history_graph store
          ~scope:(Inspection.Workspace_history (workspace_id 11))
        |> require_ok Inspection.error_to_string
        |> Inspection.render_history_graph
      in
      Alcotest.(check bool)
        "focused workspace graph" true
        (List.exists
           (String.equal "workspaces (selected capsule revisions)")
           focused);
      let after =
        Store.list_objects store |> require_ok Store.error_to_string
      in
      Alcotest.(check int)
        "graph inspection does not write objects" (List.length before)
        (List.length after))

let () =
  Alcotest.run "repository inspection"
    [
      ( "unit",
        [
          Alcotest.test_case
            "read-only status timeline storage and verification" `Quick
            inspection_is_read_only_complete_and_compaction_safe;
          Alcotest.test_case "native graph is typed, complete, and read-only"
            `Quick graph_is_read_only_and_preserves_native_boundaries;
        ] );
    ]
