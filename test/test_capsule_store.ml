module Capsule = Paengi_capsule
module Capsule_store = Paengi_capsule_store
module Envelope = Paengi_envelope
module Golden = Paengi_testkit.Golden_fixture
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

[@@@warning "-4"]

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed = Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get
let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok
let revision_id seed = Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok
let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)
let content_id seed = Snapshot.Content.of_stored_object_id (stored_id seed)
let checkpoint_id seed = Scratch.Checkpoint_id.of_stored_object_id (stored_id seed)

let fixture () =
  let capsule =
    Capsule_store.create_capsule ~id:(capsule_id 1) ~title:"initial title"
      ~description:"initial description" ~created_at:11L
    |> require_ok Capsule_store.error_to_string
  in
  let transition : Capsule.exact_file_transition =
    {
      Capsule.transition_path = [ "src"; "main" ];
      expected_entry = None;
      replacement_entry =
        Some
          (Scratch.File
             { mode = Snapshot.Executable; content = content_id 40 });
    }
  in
  let parent : Capsule_store.parent_link =
    { Capsule_store.revision = revision_id 2; object_id = stored_id 3 }
  in
  let dependency =
    Capsule.Requires_capsule
      { capsule = capsule_id 8; revision = Some (revision_id 9) }
  in
  let evidence : Capsule.validation_evidence =
    {
      Capsule.command = [ "dune"; "runtest" ];
      environment_fingerprint = Some "host-a";
      snapshot = snapshot_id 6;
      status = Capsule.Passed;
      stdout_digest = Some (content_id 7);
      stderr_digest = None;
      started_at = 12L;
      duration_ms = 13L;
    }
  in
  let revision =
    Capsule_store.create_revision ~capsule ~parent:(Some parent)
      ~declared_base:(snapshot_id 4) ~expected_result:(snapshot_id 5)
      ~operations:[ Capsule.Exact_file_transition transition ] ~dependencies:[ dependency ]
      ~evidence:[ evidence ]
      ~boundaries:[ { Capsule_store.source = checkpoint_id 10; target = checkpoint_id 11 } ]
      ~provenance:Capsule_store.Folded ~created_at:14L
    |> require_ok Capsule_store.error_to_string
  in
  let current =
    Capsule_store.make_current_ref ~generation:3L ~capsule:(Capsule_store.capsule_id capsule)
      ~capsule_object:(stored_id 12) ~revision:(Capsule_store.revision_id revision)
      ~revision_object:(stored_id 13)
    |> require_ok Capsule_store.error_to_string
  in
  (capsule, revision, current)

let golden name =
  let candidates = [ Filename.concat "golden" name; Filename.concat "test/golden" name ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> Golden.read_lower_hex_file path |> require_ok Fun.id
  | None -> Alcotest.fail ("missing golden fixture: " ^ name)

let with_store run =
  let root = Filename.temp_file "paengi-capsule-store-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
        Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      run root store)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel bytes)

type scratch_fixture = {
  scratch : Scratch.repository;
  initial : Scratch.Checkpoint_id.t;
  first : Scratch.Checkpoint_id.t;
  second : Scratch.Checkpoint_id.t;
}

let checkpoint_id_of checkpoint = Scratch.Checkpoint.id checkpoint

let make_scratch_fixture root store =
  let file = Filename.concat root "tracked" in
  write_file file "before";
  let scratch = Scratch.open_repository store in
  let initial_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let initial =
    Scratch.create_initial scratch ~snapshot:initial_snapshot ~created_at:0L
    |> require_ok Scratch.error_to_string |> checkpoint_id_of
  in
  write_file file "first";
  let first_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let first =
    Scratch.checkpoint scratch ~snapshot:first_snapshot ~source:Scratch.Explicit
      ~observed_at:1L ~created_at:1L
    |> require_ok Scratch.error_to_string
  in
  let first =
    match first with
    | Scratch.Created checkpoint | Scratch.Unchanged checkpoint -> checkpoint_id_of checkpoint
  in
  write_file file "second";
  let second_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let second =
    Scratch.checkpoint scratch ~snapshot:second_snapshot ~source:Scratch.Explicit
      ~observed_at:2L ~created_at:2L
    |> require_ok Scratch.error_to_string
  in
  let second =
    match second with
    | Scratch.Created checkpoint | Scratch.Unchanged checkpoint -> checkpoint_id_of checkpoint
  in
  { scratch; initial; first; second }

let durable_create root store id =
  let fixture = make_scratch_fixture root store in
  let resolved =
    Capsule_store.Durable.create_from_checkpoints ~store ~scratch:fixture.scratch
      ~id ~title:"durable" ~description:"durable capsule" ~dependencies:[]
      ~evidence:[] ~from:fixture.initial ~target:fixture.first ~created_at:3L
      ~changed_at:3L ()
    |> require_ok Capsule_store.error_to_string
  in
  (fixture, resolved)

let schemas_have_canonical_goldens_and_inverse_decoders () =
  with_store (fun _ store ->
      let capsule, revision, current = fixture () in
      let capsule_object =
        Capsule_store.store_capsule store capsule
        |> require_ok Capsule_store.error_to_string
      in
      let revision_object =
        Capsule_store.store_revision store revision
        |> require_ok Capsule_store.error_to_string
      in
      let envelope object_id =
        Store.get store object_id |> require_ok Store.error_to_string |> Envelope.encode
      in
      Alcotest.(check string)
        "capsule golden" (golden "capsule-v1.peng.hex") (envelope capsule_object);
      Alcotest.(check string)
        "revision golden" (golden "capsule-revision-v1.peng.hex")
        (envelope revision_object);
      Alcotest.(check string)
        "current ref golden" (golden "capsule-current-v1.ref.hex")
        (Capsule_store.encode_current_ref current);
      let loaded_capsule =
        Capsule_store.load_capsule store capsule_object
        |> require_ok Capsule_store.error_to_string
      in
      let loaded_revision =
        Capsule_store.load_revision store revision_object
        |> require_ok Capsule_store.error_to_string
      in
      let decoded_current =
        Capsule_store.decode_current_ref (Capsule_store.encode_current_ref current)
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "capsule inverse ID" true
        (Id.Capsule_id.equal (Capsule_store.capsule_id capsule)
           (Capsule_store.capsule_id loaded_capsule));
      Alcotest.(check bool)
        "revision inverse logical ID" true
        (Id.Capsule_revision_id.equal (Capsule_store.revision_id revision)
           (Capsule_store.revision_id loaded_revision));
      Alcotest.(check bool)
        "current inverse logical ID" true
        (Id.Capsule_revision_id.equal (Capsule_store.current_revision current)
           (Capsule_store.current_revision decoded_current)))

let decoders_reject_noncanonical_and_wrong_types () =
  with_store (fun _ store ->
      let capsule, revision, current = fixture () in
      let capsule_object =
        Capsule_store.store_capsule store capsule
        |> require_ok Capsule_store.error_to_string
      in
      (match Capsule_store.load_revision store capsule_object with
      | Error (Capsule_store.Unexpected_object_type _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "capsule object decoded as revision");
      let body = Capsule_store.encode_current_ref current in
      let malformed = body ^ "\000" in
      (match Capsule_store.decode_current_ref malformed with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "noncanonical ref bytes decoded");
      ignore revision)

let durable_creation_reopens_pins_and_resolves_exactly () =
  with_store (fun root store ->
      let id = capsule_id 80 in
      let fixture, created = durable_create root store id in
      let reopened =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let resolved =
        Capsule_store.Durable.read_current reopened id
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "stable logical capsule ID" true
        (Id.Capsule_id.equal id
           (Capsule_store.capsule_id
              (Capsule_store.Durable.resolved_capsule resolved)));
      Alcotest.(check bool)
        "immutable revision resolves" true
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision created))
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision resolved)));
      Alcotest.(check int)
        "current exact changes" 1
        (List.length
           (Capsule_store.Durable.current_diff reopened id
           |> require_ok Capsule_store.error_to_string));
      Alcotest.(check int)
        "one revision in history" 1
        (List.length
           (Capsule_store.Durable.history reopened id
           |> require_ok Capsule_store.error_to_string));
      Alcotest.(check int)
        "listing derives from refs" 1
        (List.length
           (Capsule_store.Durable.list reopened
           |> require_ok Capsule_store.error_to_string));
      Alcotest.(check bool)
        "source boundary remains pinned" true
        (Scratch.has_capsule_boundary fixture.scratch fixture.initial ~capsule:id
        |> require_ok Scratch.error_to_string);
      Alcotest.(check bool)
        "target boundary remains pinned" true
        (Scratch.has_capsule_boundary fixture.scratch fixture.first ~capsule:id
        |> require_ok Scratch.error_to_string))

let durable_creation_interruptions_retry_and_conflict_reuse () =
  with_store (fun root store ->
      let fixture = make_scratch_fixture root store in
      let id = capsule_id 90 in
      let before =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch:fixture.scratch
          ~id ~title:"retry" ~description:"safe" ~dependencies:[] ~evidence:[]
          ~from:fixture.initial ~target:fixture.first ~created_at:3L ~changed_at:3L
          ~fail_at:Capsule_store.Durable.Before_create_current_ref ()
      in
      (match before with
      | Error (Capsule_store.Injected_interruption _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "pre-ref interruption exposed a capsule");
      (match Capsule_store.Durable.read_current store id with
      | Error (Capsule_store.Current_ref_missing _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "pre-ref interruption left a visible capsule");
      let created =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch:fixture.scratch
          ~id ~title:"retry" ~description:"safe" ~dependencies:[] ~evidence:[]
          ~from:fixture.initial ~target:fixture.first ~created_at:3L ~changed_at:3L ()
        |> require_ok Capsule_store.error_to_string
      in
      let retried =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch:fixture.scratch
          ~id ~title:"retry" ~description:"safe" ~dependencies:[] ~evidence:[]
          ~from:fixture.initial ~target:fixture.first ~created_at:3L ~changed_at:3L ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "retry preserves physical revision" true
        (Store.Stored_object_id.equal
           (Capsule_store.Durable.resolved_revision_object created)
           (Capsule_store.Durable.resolved_revision_object retried));
      (match
         Capsule_store.Durable.create_from_checkpoints ~store ~scratch:fixture.scratch
           ~id ~title:"different" ~description:"safe" ~dependencies:[] ~evidence:[]
           ~from:fixture.initial ~target:fixture.first ~created_at:3L ~changed_at:3L ()
       with
      | Error (Capsule_store.Conflicting_capsule_id_reuse _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "conflicting capsule reuse was accepted");
      let after_id = capsule_id 91 in
      let after =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch:fixture.scratch
          ~id:after_id ~title:"after" ~description:"safe" ~dependencies:[] ~evidence:[]
          ~from:fixture.initial ~target:fixture.first ~created_at:3L ~changed_at:3L
          ~fail_at:Capsule_store.Durable.After_create_current_ref ()
      in
      (match after with
      | Error (Capsule_store.Injected_interruption _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "post-ref interruption did not interrupt");
      ignore
        (Capsule_store.Durable.read_current store after_id
        |> require_ok Capsule_store.error_to_string))

let folding_is_cas_protected_and_preserves_history () =
  with_store (fun root store ->
      let id = capsule_id 100 in
      let fixture, initial = durable_create root store id in
      let expected_revision =
        Capsule_store.revision_id (Capsule_store.Durable.resolved_revision initial)
      in
      let folded =
        Capsule_store.Durable.fold_from_checkpoints ~store ~scratch:fixture.scratch
          ~capsule:id ~expected_revision ~expected_generation:0L ~evidence:[]
          ~from:fixture.first ~target:fixture.second ~created_at:4L ~changed_at:4L ()
        |> require_ok Capsule_store.error_to_string
      in
      let folded_revision = Capsule_store.Durable.resolved_revision folded in
      Alcotest.(check bool)
        "fold creates a new logical revision" false
        (Id.Capsule_revision_id.equal expected_revision
           (Capsule_store.revision_id folded_revision));
      Alcotest.(check bool)
        "fold retains capsule ID" true
        (Id.Capsule_id.equal id (Capsule_store.revision_capsule folded_revision));
      Alcotest.(check int)
        "history retains old revision" 2
        (List.length
           (Capsule_store.Durable.history store id
           |> require_ok Capsule_store.error_to_string));
      (match
         Capsule_store.Durable.fold_from_checkpoints ~store ~scratch:fixture.scratch
           ~capsule:id ~expected_revision ~expected_generation:0L ~evidence:[]
           ~from:fixture.first ~target:fixture.second ~created_at:4L ~changed_at:4L ()
       with
      | Error (Capsule_store.Concurrent_current_update _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale fold was accepted"))

let () =
  Alcotest.run "capsule persistent schemas"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical goldens and inverse decoders" `Quick
            schemas_have_canonical_goldens_and_inverse_decoders;
          Alcotest.test_case "wrong types and malformed bytes reject" `Quick
            decoders_reject_noncanonical_and_wrong_types;
          Alcotest.test_case "durable creation reopens and pins" `Quick
            durable_creation_reopens_pins_and_resolves_exactly;
          Alcotest.test_case "creation interruption retry and reuse" `Quick
            durable_creation_interruptions_retry_and_conflict_reuse;
          Alcotest.test_case "folding is CAS protected" `Quick
            folding_is_cas_protected_and_preserves_history;
        ] );
    ]
