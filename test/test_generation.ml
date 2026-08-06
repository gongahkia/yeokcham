module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw value =
  let bytes = Bytes.make 32 '\000' in
  Bytes.set bytes 0 (Char.chr value);
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string bytes)
  |> Option.get

let with_store run =
  let root = Filename.temp_file "yeokcham-generation-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR ->
            Sys.readdir path
            |> Array.iter (fun name -> remove (Filename.concat path name));
            Unix.rmdir path
        | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
        | Unix.S_SOCK ->
            Unix.unlink path
      in
      remove root)
    (fun () -> run root (Store.init ~root |> require_ok Store.error_to_string))

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let fixture store =
  let logical = Scratch.Checkpoint_id.of_stored_object_id (raw 1) in
  let physical = Scratch.Checkpoint_id.of_stored_object_id (raw 2) in
  let snapshot = Snapshot.Snapshot.of_stored_object_id (raw 3) in
  let candidate : Scratch.Cleanup_manifest.candidate =
    {
      Scratch.Cleanup_manifest.object_id = raw 4;
      expected_type = Envelope.Scratch_event;
    }
  in
  let manifest =
    Scratch.Cleanup_manifest.create [ candidate ]
    |> require_ok Scratch.error_to_string
  in
  let manifest_id =
    Scratch.Cleanup_manifest.store store manifest
    |> require_ok Scratch.error_to_string
  in
  let entry =
    Scratch.Generation.entry ~logical ~physical ~snapshot ~previous_logical:None
      ~effective_retention:[ Scratch.User_pinned ]
  in
  let generation =
    Scratch.Generation.store store ~previous:None ~source_scratch_head:logical
      ~source_scratch_ref_generation:7L ~source_retention_head:None
      ~source_retention_ref_generation:None ~recent_window_seconds:10L
      ~periodic_interval_seconds:20L ~storage_budget_bytes:(Some 30L)
      ~entries:[ entry ] ~physical_head:physical ~retention_cutoff:None
      ~cleanup_manifest:manifest_id
    |> require_ok Scratch.error_to_string
  in
  (logical, physical, manifest_id, generation)

let schemas_have_canonical_goldens_and_inverse_decoders () =
  with_store (fun root store ->
      let logical, physical, manifest_id, generation = fixture store in
      let bytes identity =
        Store.get store identity
        |> require_ok Store.error_to_string
        |> Envelope.encode
      in
      let manifest_bytes =
        bytes (Scratch.Cleanup_manifest_id.stored_object_id manifest_id)
      in
      Alcotest.(check string)
        "cleanup manifest golden"
        (refreshed_golden "scratch-v1-cleanup-manifest.yeok.hex" manifest_bytes)
        manifest_bytes;
      let loaded =
        Scratch.Generation.load store generation
        |> require_ok Scratch.error_to_string
      in
      let segment = List.hd (Scratch.Generation.segment_ids loaded) in
      let segment_bytes =
        bytes (Scratch.Generation_id.stored_object_id segment)
      in
      let generation_bytes =
        bytes (Scratch.Generation_id.stored_object_id generation)
      in
      Alcotest.(check string)
        "generation segment golden"
        (refreshed_golden "scratch-v1-generation-segment.yeok.hex" segment_bytes)
        segment_bytes;
      Alcotest.(check string)
        "generation golden"
        (refreshed_golden "scratch-v1-generation.yeok.hex" generation_bytes)
        generation_bytes;
      let entry = List.hd (Scratch.Generation.entries loaded) in
      Alcotest.(check bool)
        "inverse logical ID" true
        (Scratch.Checkpoint_id.equal logical (Scratch.Generation.logical entry));
      Alcotest.(check bool)
        "inverse physical ID" true
        (Scratch.Checkpoint_id.equal physical
           (Scratch.Generation.physical entry));
      ignore
        (Store.compare_and_swap_ref store ~name:"scratch-generation"
           ~expected:None
           ~target:(Some (Scratch.Generation_id.stored_object_id generation))
        |> require_ok Store.error_to_string);
      let ref_path = Filename.concat root ".yeokcham/refs/scratch-generation" in
      let ref_bytes = In_channel.with_open_bin ref_path In_channel.input_all in
      Alcotest.(check string)
        "generation ref golden"
        (refreshed_golden "scratch-v1-generation.ref.hex" ref_bytes)
        ref_bytes;
      match
        Scratch.Generation.load store
          (Scratch.Generation_id.of_stored_object_id
             (Scratch.Cleanup_manifest_id.stored_object_id manifest_id))
      with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail "generation decoder accepted cleanup-manifest type")

let () =
  Alcotest.run "scratch generation schemas"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical goldens and inverse decoders" `Quick
            schemas_have_canonical_goldens_and_inverse_decoders;
        ] );
    ]
