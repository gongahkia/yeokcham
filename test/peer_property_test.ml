module Capsule_store = Yeokcham_capsule_store
module Id = Yeokcham_id
module Peer = Yeokcham_peer
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let default_seed = 20_260_815

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let state = Random.State.make [| base_seed |]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let rec remove path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let checkpoint scratch snapshot timestamp =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:timestamp ~created_at:timestamp
  |> Result.get_ok
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let no_scratch_objects store =
  Store.list_objects store |> Result.get_ok
  |> List.for_all (fun info ->
      match info.Store.object_type with
      | Yeokcham_envelope.Scratch_event | Yeokcham_envelope.Checkpoint
      | Yeokcham_envelope.Retention_change
      | Yeokcham_envelope.Scratch_generation_segment
      | Yeokcham_envelope.Scratch_generation
      | Yeokcham_envelope.Scratch_cleanup_manifest ->
          false
      | Yeokcham_envelope.Content | Yeokcham_envelope.Tree
      | Yeokcham_envelope.Snapshot | Yeokcham_envelope.Capsule
      | Yeokcham_envelope.Capsule_revision | Yeokcham_envelope.Release
      | Yeokcham_envelope.Conflict | Yeokcham_envelope.Validation
      | Yeokcham_envelope.Resolution | Yeokcham_envelope.Repository_config
      | Yeokcham_envelope.Chunk | Yeokcham_envelope.File_manifest
      | Yeokcham_envelope.Workspace | Yeokcham_envelope.Workspace_revision
      | Yeokcham_envelope.Workspace_attempt
      | Yeokcham_envelope.Release_attestation | Yeokcham_envelope.Git_mapping
      | Yeokcham_envelope.Imported_transition | Yeokcham_envelope.Imported_tag
      | Yeokcham_envelope.Ref_event | Yeokcham_envelope.Device_identity
      | Yeokcham_envelope.Divergent_ref_set | Yeokcham_envelope.Git_archive
      | Yeokcham_envelope.Git_adoption | Yeokcham_envelope.Peer_publication
      | Yeokcham_envelope.Peer_integration | Yeokcham_envelope.Git_lineage_node
      | Yeokcham_envelope.Git_lineage | Yeokcham_envelope.Peer_identity
      | Yeokcham_envelope.Peer_contact | Yeokcham_envelope.Peer_advertisement
      | Yeokcham_envelope.Peer_sync_node | Yeokcham_envelope.Peer_sync_conflict
      | Yeokcham_envelope.V4_project_state ->
          true)

let generated_capsule_projection_is_missing_only_and_scratch_free =
  QCheck2.Test.make ~count:24
    ~name:
      "generated capsule publications transfer only missing snapshot objects \
       and no scratch history"
    QCheck2.Gen.(triple (string_size (int_range 0 512)) bool bool)
    (fun (bytes, executable, preseed_source_snapshot) ->
      try
        with_directory "yeokcham-peer-property-source-" (fun source_root ->
            with_directory "yeokcham-peer-property-destination-"
              (fun destination_root ->
                let store = Store.init ~root:source_root |> Result.get_ok in
                let scratch = Scratch.open_repository store in
                let tracked = Filename.concat source_root "tracked" in
                write_file tracked bytes;
                Unix.chmod tracked (if executable then 0o755 else 0o644);
                let source_snapshot, _ =
                  Snapshot.scan ~root:source_root ~store |> Result.get_ok
                in
                let initial =
                  Scratch.create_initial scratch ~snapshot:source_snapshot
                    ~created_at:0L
                  |> Result.get_ok |> Scratch.Checkpoint.id
                in
                write_file tracked (bytes ^ "\000peer-target");
                Unix.chmod tracked (if executable then 0o644 else 0o755);
                let target_snapshot, _ =
                  Snapshot.scan ~root:source_root ~store |> Result.get_ok
                in
                let target = checkpoint scratch target_snapshot 1L in
                let capsule = capsule_id 81 in
                let resolved =
                  Capsule_store.Durable.create_from_checkpoints ~store ~scratch
                    ~id:capsule ~title:"generated source"
                    ~description:"generated peer source" ~dependencies:[]
                    ~evidence:[] ~from:initial ~target ~created_at:2L
                    ~changed_at:2L ()
                  |> Result.get_ok
                in
                let revision =
                  Capsule_store.Durable.resolved_revision resolved
                  |> Capsule_store.revision_id
                in
                let publication =
                  Peer.publish_capsule_revision store ~capsule ~revision
                  |> Result.get_ok
                in
                let destination =
                  Store.init ~root:destination_root |> Result.get_ok
                in
                (if preseed_source_snapshot then
                   let object_ =
                     Store.get store
                       (Snapshot.Snapshot.stored_object_id source_snapshot)
                     |> Result.get_ok
                   in
                   ignore (Store.put destination object_ |> Result.get_ok));
                let outcome, received =
                  Peer.fetch_local ~source:store ~destination
                    (Peer.publication_id publication)
                  |> Result.get_ok
                in
                Id.Publication_id.equal
                  (Peer.publication_id publication)
                  (Peer.publication_id received)
                && no_scratch_objects destination
                && Scratch.head_id (Scratch.open_repository destination)
                   |> Result.get_ok |> Option.is_none
                && List.for_all
                     (fun identity ->
                       Store.get destination identity |> Result.is_ok)
                     (Peer.transfer_objects publication)
                && outcome.Yeokcham_exchange_store.requested
                   <= List.length (Peer.transfer_objects publication) + 1))
      with _ -> false)

let () =
  Printf.printf "peer property base seed: %d\n%!" base_seed;
  Alcotest.run "peer properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick ~rand:state
            generated_capsule_projection_is_missing_only_and_scratch_free;
        ] );
    ]
