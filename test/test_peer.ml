module Capsule_store = Yeokcham_capsule_store
module Envelope = Yeokcham_envelope
module Exchange = Yeokcham_exchange
module Golden = Yeokcham_testkit.Golden_fixture
module Id = Yeokcham_id
module Peer = Yeokcham_peer
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

let capsule_id seed =
  Id.Capsule_id.of_bytes (raw_id seed) |> require_ok Id.parse_error_to_string

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
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
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

type fixture = {
  store : Store.repository;
  capsule : Id.Capsule_id.t;
  revision : Id.Capsule_revision_id.t;
  source_snapshot : Snapshot.Snapshot.id;
  target_snapshot : Snapshot.Snapshot.id;
}

let source_fixture root =
  let store = Store.init ~root |> require_ok Store.error_to_string in
  let scratch = Scratch.open_repository store in
  let tracked = Filename.concat root "tracked" in
  write_file tracked "before\n";
  let source_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let initial =
    Scratch.create_initial scratch ~snapshot:source_snapshot ~created_at:0L
    |> require_ok Scratch.error_to_string
    |> Scratch.Checkpoint.id
  in
  write_file tracked "after\n";
  let target_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let target =
    Scratch.checkpoint scratch ~snapshot:target_snapshot
      ~source:Scratch.Explicit ~observed_at:1L ~created_at:1L
    |> require_ok Scratch.error_to_string
    |> function
    | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
        Scratch.Checkpoint.id checkpoint
  in
  let capsule = capsule_id 41 in
  let resolved =
    Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id:capsule
      ~title:"source capsule" ~description:"peer publication source"
      ~dependencies:[] ~evidence:[] ~from:initial ~target ~created_at:2L
      ~changed_at:2L ()
    |> require_ok Capsule_store.error_to_string
  in
  {
    store;
    capsule;
    revision =
      Capsule_store.Durable.resolved_revision resolved
      |> Capsule_store.revision_id;
    source_snapshot;
    target_snapshot;
  }

type release_fixture = {
  release_store : Store.repository;
  release : Id.Release_id.t;
  base_snapshot : Snapshot.Snapshot.id;
  final_snapshot : Snapshot.Snapshot.id;
}

let workspace_id seed =
  Id.Workspace_id.of_bytes (raw_id seed) |> require_ok Id.parse_error_to_string

let checkpoint scratch snapshot timestamp =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:timestamp ~created_at:timestamp
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let release_source_fixture root =
  write_file (Filename.concat root "release-tracked") "base\n";
  let store = Store.init ~root |> require_ok Store.error_to_string in
  let scratch = Scratch.open_repository store in
  let base_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let initial =
    Scratch.create_initial scratch ~snapshot:base_snapshot ~created_at:0L
    |> require_ok Scratch.error_to_string
    |> Scratch.Checkpoint.id
  in
  write_file (Filename.concat root "release-tracked") "release\n";
  let target_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let target = checkpoint scratch target_snapshot 1L in
  let capsule = capsule_id 51 in
  ignore
    (Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id:capsule
       ~title:"release source" ~description:"peer release source"
       ~dependencies:[] ~evidence:[] ~from:initial ~target ~created_at:2L
       ~changed_at:2L ()
    |> require_ok Capsule_store.error_to_string);
  let workspace = workspace_id 52 in
  ignore
    (Workspace_store.Durable.create ~store ~id:workspace ~base:base_snapshot
       ~name:None ~description:None ~created_at:3L
    |> require_ok Workspace_store.error_to_string);
  ignore
    (Workspace_store.Durable.enable_current_capsule ~store ~workspace ~capsule
       ~expected_generation:None ~created_at:4L
    |> require_ok Workspace_store.error_to_string);
  let materialised =
    Workspace_store.Durable.materialise ~store ~scratch ~root ~workspace
      ~observed_at:5L ~created_at:5L ~dry_run:false ()
    |> require_ok Workspace_store.error_to_string
  in
  if materialised.Workspace_store.Durable.partial then
    Alcotest.fail "release source fixture conflicted";
  let release =
    Release.Durable.create ~store ~workspace ~parents:[] ~commands:[]
      ~message:(Some "peer release") ~observed_at:6L ~created_at:6L ()
    |> require_ok Release.error_to_string
  in
  {
    release_store = store;
    release = Release.release_id release;
    base_snapshot;
    final_snapshot = Release.release_final_snapshot release;
  }

let no_scratch_objects store =
  Store.list_objects store
  |> require_ok Store.error_to_string
  |> List.iter (fun info ->
      Alcotest.(check bool)
        "peer receiver has no scratch object" false
        (match info.Store.object_type with
        | Envelope.Scratch_event | Envelope.Checkpoint
        | Envelope.Retention_change | Envelope.Scratch_generation_segment
        | Envelope.Scratch_generation | Envelope.Scratch_cleanup_manifest ->
            true
        | Envelope.Content | Envelope.Tree | Envelope.Snapshot
        | Envelope.Capsule | Envelope.Capsule_revision | Envelope.Release
        | Envelope.Conflict | Envelope.Validation | Envelope.Resolution
        | Envelope.Repository_config | Envelope.Chunk | Envelope.File_manifest
        | Envelope.Workspace | Envelope.Workspace_revision
        | Envelope.Workspace_attempt | Envelope.Release_attestation
        | Envelope.Git_mapping | Envelope.Imported_transition
        | Envelope.Imported_tag | Envelope.Ref_event | Envelope.Device_identity
        | Envelope.Divergent_ref_set | Envelope.Git_archive
        | Envelope.Git_adoption | Envelope.Peer_publication
        | Envelope.Peer_integration | Envelope.Git_lineage_node
        | Envelope.Git_lineage | Envelope.Peer_identity | Envelope.Peer_contact
        | Envelope.Peer_advertisement | Envelope.Peer_sync_node
        | Envelope.Peer_sync_conflict ->
            false))

let only_projection_objects store =
  Store.list_objects store
  |> require_ok Store.error_to_string
  |> List.iter (fun info ->
      Alcotest.(check bool)
        "peer receiver contains only a publication projection and snapshots"
        false
        (match info.Store.object_type with
        | Envelope.Snapshot | Envelope.Tree | Envelope.Content
        | Envelope.File_manifest | Envelope.Chunk | Envelope.Peer_publication ->
            false
        | Envelope.Scratch_event | Envelope.Checkpoint | Envelope.Capsule
        | Envelope.Capsule_revision | Envelope.Release | Envelope.Conflict
        | Envelope.Validation | Envelope.Resolution | Envelope.Repository_config
        | Envelope.Retention_change | Envelope.Scratch_generation_segment
        | Envelope.Scratch_generation | Envelope.Scratch_cleanup_manifest
        | Envelope.Workspace | Envelope.Workspace_revision
        | Envelope.Workspace_attempt | Envelope.Release_attestation
        | Envelope.Git_mapping | Envelope.Imported_transition
        | Envelope.Imported_tag | Envelope.Ref_event | Envelope.Device_identity
        | Envelope.Divergent_ref_set | Envelope.Git_archive
        | Envelope.Git_adoption | Envelope.Peer_integration
        | Envelope.Git_lineage_node | Envelope.Git_lineage
        | Envelope.Peer_identity | Envelope.Peer_contact
        | Envelope.Peer_advertisement | Envelope.Peer_sync_node
        | Envelope.Peer_sync_conflict ->
            true))

let capsule_publication_transfers_only_snapshot_closure () =
  with_directory "yeokcham-peer-source-" (fun source_root ->
      with_directory "yeokcham-peer-destination-" (fun destination_root ->
          let source = source_fixture source_root in
          let publication =
            Peer.publish_capsule_revision source.store ~capsule:source.capsule
              ~revision:source.revision
            |> require_ok Peer.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          let preexisting =
            Store.get source.store
              (Snapshot.Snapshot.stored_object_id source.source_snapshot)
            |> require_ok Store.error_to_string
          in
          ignore
            (Store.put destination preexisting
            |> require_ok Store.error_to_string);
          let source_head_before =
            Scratch.head_id (Scratch.open_repository source.store)
            |> require_ok Scratch.error_to_string
          in
          let outcome, received =
            Peer.fetch_local ~source:source.store ~destination
              (Peer.publication_id publication)
            |> require_ok Peer.error_to_string
          in
          Alcotest.(check bool)
            "publication identity survives transfer" true
            (Id.Publication_id.equal
               (Peer.publication_id publication)
               (Peer.publication_id received));
          Alcotest.(check bool)
            "preexisting snapshot was not requested" true
            (outcome.Yeokcham_exchange_store.requested
            < List.length (Peer.transfer_objects publication) + 1);
          Alcotest.(check bool)
            "source scratch head is unchanged" true
            (Scratch.head_id (Scratch.open_repository source.store)
            |> require_ok Scratch.error_to_string
            = source_head_before);
          Alcotest.(check (option string))
            "receiver has no scratch head" None
            (Scratch.head_id (Scratch.open_repository destination)
            |> require_ok Scratch.error_to_string
            |> Option.map (fun identity ->
                Store.Stored_object_id.to_hex
                  (Scratch.Checkpoint_id.stored_object_id identity)));
          no_scratch_objects destination;
          let reopened =
            Peer.load_publication destination (Peer.publication_id publication)
            |> require_ok Peer.error_to_string
          in
          match Peer.publication_target reopened with
          | Peer.Release _ ->
              Alcotest.fail "capsule publication changed target kind"
          | Peer.Capsule_revision target ->
              Alcotest.(check string)
                "source title is provenance" "source capsule"
                (Peer.capsule_target_title target);
              Alcotest.(check bool)
                "target snapshot survives" true
                (Snapshot.Snapshot.equal_id
                   (Peer.capsule_target_result_snapshot target)
                   source.target_snapshot)))

let interruption_retries_without_visible_publication () =
  with_directory "yeokcham-peer-interrupted-source-" (fun source_root ->
      with_directory "yeokcham-peer-interrupted-destination-"
        (fun destination_root ->
          let source = source_fixture source_root in
          let publication =
            Peer.publish_capsule_revision source.store ~capsule:source.capsule
              ~revision:source.revision
            |> require_ok Peer.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          Peer.fetch_local ~interrupt_after:1 ~source:source.store ~destination
            (Peer.publication_id publication)
          |> Result.fold
               ~ok:(fun _ -> Alcotest.fail "interrupted peer fetch succeeded")
               ~error:(fun _ -> ());
          Peer.load_publication destination (Peer.publication_id publication)
          |> Result.fold
               ~ok:(fun _ ->
                 Alcotest.fail "interrupted peer fetch became visible")
               ~error:(function
                 | Peer.Publication_missing _ -> ()
                 | Peer.Store_error _ | Peer.Envelope_error _
                 | Peer.Encoding_error _ | Peer.Decode_error _
                 | Peer.Snapshot_error _ | Peer.Capsule_error _
                 | Peer.Release_error _ | Peer.Scratch_error _
                 | Peer.Exchange_error _ | Peer.Integration_missing _
                 | Peer.Invalid_publication _
                 | Peer.Unsupported_integration_target
                 | Peer.Publication_binding_conflict _
                 | Peer.Integration_binding_conflict _
                 | Peer.Injected_interruption _ | Peer.Transport_error _ ->
                     Alcotest.fail
                       "interrupted peer fetch returned the wrong error");
          let _, received =
            Peer.fetch_local ~source:source.store ~destination
              (Peer.publication_id publication)
            |> require_ok Peer.error_to_string
          in
          Alcotest.(check bool)
            "retry returns original publication" true
            (Id.Publication_id.equal
               (Peer.publication_id publication)
               (Peer.publication_id received))))

let release_publication_remains_a_projection () =
  with_directory "yeokcham-peer-release-source-" (fun source_root ->
      with_directory "yeokcham-peer-release-destination-"
        (fun destination_root ->
          let source = release_source_fixture source_root in
          let publication =
            Peer.publish_release source.release_store source.release
            |> require_ok Peer.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          let _, received =
            Peer.fetch_local ~source:source.release_store ~destination
              (Peer.publication_id publication)
            |> require_ok Peer.error_to_string
          in
          only_projection_objects destination;
          match Peer.publication_target received with
          | Peer.Capsule_revision _ ->
              Alcotest.fail "release publication changed target kind"
          | Peer.Release target ->
              Alcotest.(check bool)
                "release provenance survives transfer" true
                (Id.Release_id.equal source.release
                   (Peer.release_target_source_release target));
              Alcotest.(check bool)
                "release base survives transfer" true
                (Snapshot.Snapshot.equal_id source.base_snapshot
                   (Peer.release_target_base target));
              Alcotest.(check bool)
                "release final snapshot survives transfer" true
                (Snapshot.Snapshot.equal_id source.final_snapshot
                   (Peer.release_target_final_snapshot target));
              Peer.integrate_capsule destination
                ~publication:(Peer.publication_id publication)
                ~capsule:(capsule_id 110) ~title:"must refuse"
                ~description:"release provenance is not local validation"
                ~created_at:10L
              |> Result.fold
                   ~ok:(fun _ ->
                     Alcotest.fail "peer release was implicitly integrated")
                   ~error:(function
                     | error ->
                     Alcotest.(check string)
                       "peer release integration has a structured refusal"
                       (Peer.error_to_string Peer.Unsupported_integration_target)
                       (Peer.error_to_string error))))

let rejects_a_missing_publication_closure_object () =
  with_directory "yeokcham-peer-missing-closure-" (fun root ->
      let source = source_fixture root in
      let publication =
        Peer.publish_capsule_revision source.store ~capsule:source.capsule
          ~revision:source.revision
        |> require_ok Peer.error_to_string
      in
      let missing = List.hd (Peer.publication_objects publication) in
      Unix.unlink (Store.object_path source.store missing);
      Peer.load_publication source.store (Peer.publication_id publication)
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "missing closure object was accepted")
           ~error:(fun _ -> ()))

let malformed_or_incompatible_streams_publish_nothing () =
  with_directory "yeokcham-peer-invalid-stream-" (fun root ->
      let source = source_fixture root in
      let publication =
        Peer.publish_capsule_revision source.store ~capsule:source.capsule
          ~revision:source.revision
        |> require_ok Peer.error_to_string
      in
      let attempt name bytes =
        let input_path = Filename.concat root (name ^ ".input") in
        let output_path = Filename.concat root (name ^ ".output") in
        write_file input_path bytes;
        let input = In_channel.open_bin input_path in
        let output = Out_channel.open_bin output_path in
        Fun.protect
          ~finally:(fun () ->
            In_channel.close input;
            Out_channel.close output)
          (fun () ->
            let destination_root =
              Filename.concat root (name ^ ".destination")
            in
            Unix.mkdir destination_root 0o700;
            let destination =
              Store.init ~root:destination_root
              |> require_ok Store.error_to_string
            in
            Peer.fetch_stream ~destination
              ~publication:(Peer.publication_id publication)
              ~input ~output
            |> Result.fold
                 ~ok:(fun _ -> Alcotest.fail "invalid peer stream succeeded")
                 ~error:(function
                   | error ->
                   Alcotest.(check bool)
                     "invalid peer stream returns a transport error" true
                     (String.starts_with ~prefix:"peer transport: "
                        (Peer.error_to_string error)));
            Alcotest.(check int)
              "invalid peer stream leaves destination empty" 0
              (Store.list_objects destination
              |> require_ok Store.error_to_string
              |> List.length))
      in
      attempt "malformed" "\000\000\000\000\000\000\000\000";
      let incompatible =
        Exchange.encode
          (Exchange.Hello
             {
               repository_format = "incompatible-peer-format";
               supported_versions = [ Exchange.protocol_version ];
               required_features = Exchange.supported_required_features;
             })
        |> require_ok Exchange.error_to_string
      in
      attempt "incompatible" incompatible)

let capsule_integration_is_explicit_and_local () =
  with_directory "yeokcham-peer-integrate-source-" (fun source_root ->
      with_directory "yeokcham-peer-integrate-destination-"
        (fun destination_root ->
          let source = source_fixture source_root in
          let publication =
            Peer.publish_capsule_revision source.store ~capsule:source.capsule
              ~revision:source.revision
            |> require_ok Peer.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          let _, _ =
            Peer.fetch_local ~source:source.store ~destination
              (Peer.publication_id publication)
            |> require_ok Peer.error_to_string
          in
          let local_capsule = capsule_id 99 in
          let integration =
            Peer.integrate_capsule destination
              ~publication:(Peer.publication_id publication)
              ~capsule:local_capsule ~title:"receiver intent"
              ~description:"receiver authored intent" ~created_at:10L
            |> require_ok Peer.error_to_string
          in
          Alcotest.(check bool)
            "integration uses receiver capsule identity" true
            (Id.Capsule_id.equal local_capsule
               (Peer.integration_capsule integration));
          Alcotest.(check bool)
            "integration does not use source capsule identity" false
            (Id.Capsule_id.equal source.capsule
               (Peer.integration_capsule integration));
          let reopened =
            Peer.load_integration destination (Peer.integration_id integration)
            |> require_ok Peer.error_to_string
          in
          Alcotest.(check bool)
            "integration receipt reopens" true
            (Id.Peer_integration_id.equal
               (Peer.integration_id integration)
               (Peer.integration_id reopened));
          Alcotest.(check (option string))
            "integration does not move scratch head" None
            (Scratch.head_id (Scratch.open_repository destination)
            |> require_ok Scratch.error_to_string
            |> Option.map (fun identity ->
                Store.Stored_object_id.to_hex
                  (Scratch.Checkpoint_id.stored_object_id identity)))))

let framed_peer_stream_and_ssh_arguments_are_direct () =
  with_directory "yeokcham-peer-stream-source-" (fun source_root ->
      with_directory "yeokcham-peer-stream-destination-"
        (fun destination_root ->
          let source = source_fixture source_root in
          let publication =
            Peer.publish_capsule_revision source.store ~capsule:source.capsule
              ~revision:source.revision
            |> require_ok Peer.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          let server_input, client_output = Unix.pipe () in
          let client_input, server_output = Unix.pipe () in
          match Unix.fork () with
          | 0 ->
              Unix.close client_output;
              Unix.close client_input;
              let input = Unix.in_channel_of_descr server_input in
              let output = Unix.out_channel_of_descr server_output in
              let status =
                match
                  Peer.serve source.store
                    ~publication:(Peer.publication_id publication)
                    ~input ~output
                with
                | Ok () -> 0
                | Error error ->
                    prerr_endline (Peer.error_to_string error);
                    1
              in
              Out_channel.close output;
              In_channel.close input;
              exit status
          | child ->
              Unix.close server_input;
              Unix.close server_output;
              let input = Unix.in_channel_of_descr client_input in
              let output = Unix.out_channel_of_descr client_output in
              let _, received =
                Peer.fetch_stream ~destination
                  ~publication:(Peer.publication_id publication)
                  ~input ~output
                |> require_ok Peer.error_to_string
              in
              Out_channel.close output;
              In_channel.close input;
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "peer stream server exits successfully" true
                (status = Unix.WEXITED 0);
              Alcotest.(check bool)
                "peer stream returns the named publication" true
                (Id.Publication_id.equal
                   (Peer.publication_id publication)
                   (Peer.publication_id received));
              let arguments =
                Peer.ssh_arguments ~target:"person@example.test"
                  ~remote_root:"/srv/yeokcham"
                  ~publication:(Peer.publication_id publication)
                |> require_ok Peer.error_to_string
              in
              Alcotest.(check (array string))
                "SSH is invoked through direct argv"
                [|
                  "ssh";
                  "-T";
                  "-o";
                  "BatchMode=yes";
                  "-o";
                  "ConnectTimeout=5";
                  "-o";
                  "ClearAllForwardings=yes";
                  "--";
                  "person@example.test";
                  "yeokcham peer --root /srv/yeokcham serve --publication "
                  ^ Id.Publication_id.to_hex (Peer.publication_id publication);
                |]
                arguments;
              Peer.ssh_arguments ~target:"bad;target"
                ~remote_root:"/srv/yeokcham"
                ~publication:(Peer.publication_id publication)
              |> Result.is_error
              |> Alcotest.(check bool) "unsafe SSH target is rejected" true))

let peer_persistence_goldens_are_stable () =
  with_directory "yeokcham-peer-golden-" (fun root ->
      let source = source_fixture root in
      let publication =
        Peer.publish_capsule_revision source.store ~capsule:source.capsule
          ~revision:source.revision
        |> require_ok Peer.error_to_string
      in
      let publication_bytes =
        Peer.publication_envelope_bytes publication
        |> require_ok Peer.error_to_string
      in
      let binding =
        Peer.publication_binding_bytes publication
        |> require_ok Peer.error_to_string
      in
      Alcotest.(check string)
        "peer publication envelope golden"
        (Golden.refresh_lower_hex_file "golden/peer-publication-v1.yeok.hex"
           publication_bytes
        |> require_ok Fun.id)
        publication_bytes;
      Alcotest.(check string)
        "peer publication binding golden"
        (Golden.refresh_lower_hex_file "golden/peer-publication-v1.ref.hex"
           binding
        |> require_ok Fun.id)
        binding;
      let destination_root = Filename.concat root "receiver" in
      Unix.mkdir destination_root 0o700;
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let _, _ =
        Peer.fetch_local ~source:source.store ~destination
          (Peer.publication_id publication)
        |> require_ok Peer.error_to_string
      in
      let integration =
        Peer.integrate_capsule destination
          ~publication:(Peer.publication_id publication)
          ~capsule:(capsule_id 99) ~title:"receiver intent"
          ~description:"receiver-authored intent" ~created_at:10L
        |> require_ok Peer.error_to_string
      in
      let integration_bytes =
        Peer.integration_envelope_bytes integration
        |> require_ok Peer.error_to_string
      in
      let integration_binding =
        Peer.integration_binding_bytes integration
        |> require_ok Peer.error_to_string
      in
      Alcotest.(check string)
        "peer integration envelope golden"
        (Golden.refresh_lower_hex_file "golden/peer-integration-v1.yeok.hex"
           integration_bytes
        |> require_ok Fun.id)
        integration_bytes;
      Alcotest.(check string)
        "peer integration binding golden"
        (Golden.refresh_lower_hex_file "golden/peer-integration-v1.ref.hex"
           integration_binding
        |> require_ok Fun.id)
        integration_binding)

let () =
  Alcotest.run "yeokcham_peer"
    [
      ( "peer",
        [
          Alcotest.test_case "capsule publication transfers snapshot closure"
            `Quick capsule_publication_transfers_only_snapshot_closure;
          Alcotest.test_case "interruption retries without visible publication"
            `Quick interruption_retries_without_visible_publication;
          Alcotest.test_case "release publication remains a projection" `Quick
            release_publication_remains_a_projection;
          Alcotest.test_case "missing closure objects are rejected" `Quick
            rejects_a_missing_publication_closure_object;
          Alcotest.test_case
            "malformed and incompatible streams publish nothing" `Quick
            malformed_or_incompatible_streams_publish_nothing;
          Alcotest.test_case "capsule integration is explicit and local" `Quick
            capsule_integration_is_explicit_and_local;
          Alcotest.test_case "framed stream and SSH argv are direct" `Quick
            framed_peer_stream_and_ssh_arguments_are_direct;
          Alcotest.test_case "peer persistence schemas have stable goldens"
            `Quick peer_persistence_goldens_are_stable;
        ] );
    ]
