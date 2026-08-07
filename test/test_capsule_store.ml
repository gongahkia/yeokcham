module Capsule = Yeokcham_capsule
module Capsule_store = Yeokcham_capsule_store
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

[@@@warning "-4-42"]

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed =
  Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)
let content_id seed = Snapshot.Content.of_stored_object_id (stored_id seed)

let checkpoint_id seed =
  Scratch.Checkpoint_id.of_stored_object_id (stored_id seed)

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
          (Scratch.File { mode = Snapshot.Executable; content = content_id 40 });
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
      ~operations:[ Capsule.Exact_file_transition transition ]
      ~dependencies:[ dependency ] ~evidence:[ evidence ]
      ~boundaries:
        [
          { Capsule_store.source = checkpoint_id 10; target = checkpoint_id 11 };
        ]
      ~provenance:Capsule_store.Folded ~created_at:14L
    |> require_ok Capsule_store.error_to_string
  in
  let current =
    Capsule_store.make_current_ref ~generation:3L
      ~capsule:(Capsule_store.capsule_id capsule)
      ~capsule_object:(stored_id 12)
      ~revision:(Capsule_store.revision_id revision)
      ~revision_object:(stored_id 13)
    |> require_ok Capsule_store.error_to_string
  in
  (capsule, revision, current)

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let with_store run =
  let root = Filename.temp_file "yeokcham-capsule-store-test-" "" in
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
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      run root store)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

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
    |> require_ok Scratch.error_to_string
    |> checkpoint_id_of
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
    | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
        checkpoint_id_of checkpoint
  in
  write_file file "second";
  let second_snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let second =
    Scratch.checkpoint scratch ~snapshot:second_snapshot
      ~source:Scratch.Explicit ~observed_at:2L ~created_at:2L
    |> require_ok Scratch.error_to_string
  in
  let second =
    match second with
    | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
        checkpoint_id_of checkpoint
  in
  { scratch; initial; first; second }

let durable_create root store id =
  let fixture = make_scratch_fixture root store in
  let resolved =
    Capsule_store.Durable.create_from_checkpoints ~store
      ~scratch:fixture.scratch ~id ~title:"durable"
      ~description:"durable capsule" ~dependencies:[] ~evidence:[]
      ~from:fixture.initial ~target:fixture.first ~created_at:3L ~changed_at:3L
      ()
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
        Store.get store object_id
        |> require_ok Store.error_to_string
        |> Envelope.encode
      in
      let capsule_bytes = envelope capsule_object in
      let revision_bytes = envelope revision_object in
      let current_bytes = Capsule_store.encode_current_ref current in
      Alcotest.(check string)
        "capsule golden"
        (refreshed_golden "capsule-v1.yeok.hex" capsule_bytes)
        capsule_bytes;
      Alcotest.(check string)
        "revision golden"
        (refreshed_golden "capsule-revision-v1.yeok.hex" revision_bytes)
        revision_bytes;
      Alcotest.(check string)
        "current ref golden"
        (refreshed_golden "capsule-current-v1.ref.hex" current_bytes)
        current_bytes;
      let loaded_capsule =
        Capsule_store.load_capsule store capsule_object
        |> require_ok Capsule_store.error_to_string
      in
      let loaded_revision =
        Capsule_store.load_revision store revision_object
        |> require_ok Capsule_store.error_to_string
      in
      let decoded_current =
        Capsule_store.decode_current_ref
          (Capsule_store.encode_current_ref current)
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "capsule inverse ID" true
        (Id.Capsule_id.equal
           (Capsule_store.capsule_id capsule)
           (Capsule_store.capsule_id loaded_capsule));
      Alcotest.(check bool)
        "revision inverse logical ID" true
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_id revision)
           (Capsule_store.revision_id loaded_revision));
      Alcotest.(check bool)
        "current inverse logical ID" true
        (Id.Capsule_revision_id.equal
           (Capsule_store.current_revision current)
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
        (Scratch.has_capsule_boundary fixture.scratch fixture.initial
           ~capsule:id
        |> require_ok Scratch.error_to_string);
      Alcotest.(check bool)
        "target boundary remains pinned" true
        (Scratch.has_capsule_boundary fixture.scratch fixture.first ~capsule:id
        |> require_ok Scratch.error_to_string))

let durable_retarget_publishes_an_immutable_revision_or_returns_conflicts () =
  with_store (fun root store ->
      let fixture, original = durable_create root store (capsule_id 70) in
      let initial =
        Scratch.resolve_checkpoint fixture.scratch fixture.initial
        |> require_ok Scratch.error_to_string
        |> Scratch.resolved_checkpoint |> Scratch.Checkpoint.snapshot
      in
      let retargeted =
        Capsule_store.Durable.retarget ~store ~capsule:(capsule_id 70)
          ~base:initial ~created_at:4L
        |> require_ok Capsule_store.error_to_string
      in
      let retargeted =
        match retargeted with
        | Capsule_store.Durable.Retargeted resolved -> resolved
        | Capsule_store.Durable.Retarget_conflicts _ ->
            Alcotest.fail "matching base unexpectedly conflicted"
      in
      let revision = Capsule_store.Durable.resolved_revision retargeted in
      Alcotest.(check bool)
        "new logical revision" false
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision original))
           (Capsule_store.revision_id revision));
      Alcotest.(check bool)
        "retargeted base" true
        (Snapshot.Snapshot.equal_id initial
           (Capsule_store.revision_declared_base revision));
      (match Capsule_store.revision_provenance revision with
      | Capsule_store.Retargeted_from source ->
          Alcotest.(check bool)
            "retarget provenance points at prior revision" true
            (Id.Capsule_revision_id.equal
               (Capsule_store.revision_id
                  (Capsule_store.Durable.resolved_revision original))
               (Capsule_store.revision_link_revision source))
      | _ -> Alcotest.fail "retargeted revision has wrong provenance");
      let history =
        Capsule_store.Durable.history store (capsule_id 70)
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check int) "retarget extends history" 2 (List.length history);
      let changed_base =
        Scratch.resolve_checkpoint fixture.scratch fixture.second
        |> require_ok Scratch.error_to_string
        |> Scratch.resolved_checkpoint |> Scratch.Checkpoint.snapshot
      in
      let before_conflict =
        Capsule_store.Durable.resolved_current_ref retargeted
        |> Capsule_store.current_revision
      in
      let conflict =
        Capsule_store.Durable.retarget ~store ~capsule:(capsule_id 70)
          ~base:changed_base ~created_at:5L
        |> require_ok Capsule_store.error_to_string
      in
      (match conflict with
      | Capsule_store.Durable.Retarget_conflicts (_ :: _) -> ()
      | Capsule_store.Durable.Retarget_conflicts [] ->
          Alcotest.fail "conflicting retarget returned no conflicts"
      | Capsule_store.Durable.Retargeted _ ->
          Alcotest.fail "conflicting retarget unexpectedly published");
      let after_conflict =
        Capsule_store.Durable.read_current store (capsule_id 70)
        |> require_ok Capsule_store.error_to_string
        |> Capsule_store.Durable.resolved_current_ref
        |> Capsule_store.current_revision
      in
      Alcotest.(check bool)
        "conflicting retarget keeps current revision" true
        (Id.Capsule_revision_id.equal before_conflict after_conflict))

let durable_creation_interruptions_retry_and_conflict_reuse () =
  with_store (fun root store ->
      let fixture = make_scratch_fixture root store in
      let id = capsule_id 90 in
      let before =
        Capsule_store.Durable.create_from_checkpoints ~store
          ~scratch:fixture.scratch ~id ~title:"retry" ~description:"safe"
          ~dependencies:[] ~evidence:[] ~from:fixture.initial
          ~target:fixture.first ~created_at:3L ~changed_at:3L
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
        Capsule_store.Durable.create_from_checkpoints ~store
          ~scratch:fixture.scratch ~id ~title:"retry" ~description:"safe"
          ~dependencies:[] ~evidence:[] ~from:fixture.initial
          ~target:fixture.first ~created_at:3L ~changed_at:3L ()
        |> require_ok Capsule_store.error_to_string
      in
      let retried =
        Capsule_store.Durable.create_from_checkpoints ~store
          ~scratch:fixture.scratch ~id ~title:"retry" ~description:"safe"
          ~dependencies:[] ~evidence:[] ~from:fixture.initial
          ~target:fixture.first ~created_at:3L ~changed_at:3L ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "retry preserves physical revision" true
        (Store.Stored_object_id.equal
           (Capsule_store.Durable.resolved_revision_object created)
           (Capsule_store.Durable.resolved_revision_object retried));
      (match
         Capsule_store.Durable.create_from_checkpoints ~store
           ~scratch:fixture.scratch ~id ~title:"different" ~description:"safe"
           ~dependencies:[] ~evidence:[] ~from:fixture.initial
           ~target:fixture.first ~created_at:3L ~changed_at:3L ()
       with
      | Error (Capsule_store.Conflicting_capsule_id_reuse _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "conflicting capsule reuse was accepted");
      let after_id = capsule_id 91 in
      let after =
        Capsule_store.Durable.create_from_checkpoints ~store
          ~scratch:fixture.scratch ~id:after_id ~title:"after"
          ~description:"safe" ~dependencies:[] ~evidence:[]
          ~from:fixture.initial ~target:fixture.first ~created_at:3L
          ~changed_at:3L ~fail_at:Capsule_store.Durable.After_create_current_ref
          ()
      in
      (match after with
      | Error (Capsule_store.Injected_interruption _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "post-ref interruption did not interrupt");
      ignore
        (Capsule_store.Durable.read_current store after_id
        |> require_ok Capsule_store.error_to_string))

let current_working_diff_creation_is_exact_and_pins_after_reopen () =
  with_store (fun root store ->
      let fixture = make_scratch_fixture root store in
      write_file (Filename.concat root "tracked") "current";
      let id = capsule_id 95 in
      let created =
        Capsule_store.Durable.create_from_current ~store
          ~scratch:fixture.scratch ~root ~id ~title:"current"
          ~description:"working diff" ~dependencies:[] ~evidence:[]
          ~created_at:9L ~changed_at:9L ()
        |> require_ok Capsule_store.error_to_string
      in
      let resolved, source, target =
        match created with
        | Capsule_store.Durable.No_current_changes _ ->
            Alcotest.fail "current working diff was not published"
        | Capsule_store.Durable.Created_from_current value ->
            (value.resolved, value.source, value.target)
      in
      Alcotest.(check bool)
        "current creation starts at the old scratch head" true
        (Scratch.Checkpoint_id.equal fixture.second source);
      let head =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "current creation advances scratch head" true
        (Option.exists (Scratch.Checkpoint_id.equal target) head);
      Alcotest.(check int)
        "current revision has the exact delta" 1
        (List.length
           (Capsule_store.revision_operations
              (Capsule_store.Durable.resolved_revision resolved)));
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened_scratch = Scratch.open_repository reopened_store in
      let reopened =
        Capsule_store.Durable.read_current reopened_store id
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "current revision survives reopen" true
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision resolved))
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision reopened)));
      List.iter
        (fun checkpoint ->
          Alcotest.(check bool)
            "current creation boundary remains pinned after reopen" true
            (Scratch.has_capsule_boundary reopened_scratch checkpoint
               ~capsule:id
            |> require_ok Scratch.error_to_string))
        [ source; target ])

let current_working_diff_no_changes_and_mutation_reject_safely () =
  with_store (fun root store ->
      let fixture = make_scratch_fixture root store in
      let unchanged_id = capsule_id 96 in
      let unchanged =
        Capsule_store.Durable.create_from_current ~store
          ~scratch:fixture.scratch ~root ~id:unchanged_id ~title:"unchanged"
          ~description:"unchanged" ~dependencies:[] ~evidence:[] ~created_at:10L
          ~changed_at:10L ()
        |> require_ok Capsule_store.error_to_string
      in
      (match unchanged with
      | Capsule_store.Durable.No_current_changes { checkpoint; _ } ->
          Alcotest.(check bool)
            "no-change result names the existing head" true
            (Scratch.Checkpoint_id.equal fixture.second checkpoint)
      | Capsule_store.Durable.Created_from_current _ ->
          Alcotest.fail "no-change creation published a capsule");
      (match Capsule_store.Durable.read_current store unchanged_id with
      | Error (Capsule_store.Current_ref_missing _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "no-change creation published a current ref");
      write_file (Filename.concat root "tracked") "before-verification";
      let mutated =
        Capsule_store.Durable.create_from_current ~store
          ~scratch:fixture.scratch ~root ~id:(capsule_id 97) ~title:"mutated"
          ~description:"mutated" ~dependencies:[] ~evidence:[] ~created_at:11L
          ~changed_at:11L
          ~before_verify:(fun () ->
            write_file (Filename.concat root "tracked") "after-verification")
          ()
      in
      (match mutated with
      | Error (Capsule_store.Current_working_directory_changed _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "working-directory mutation was accepted");
      let head =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "mutation rejection leaves scratch head unchanged" true
        (Option.exists (Scratch.Checkpoint_id.equal fixture.second) head))

let current_working_diff_interruption_retries_idempotently () =
  with_store (fun root store ->
      let fixture = make_scratch_fixture root store in
      write_file (Filename.concat root "tracked") "interrupted";
      let id = capsule_id 98 in
      let interrupted =
        Capsule_store.Durable.create_from_current ~store
          ~scratch:fixture.scratch ~root ~id ~title:"retry current"
          ~description:"retry current" ~dependencies:[] ~evidence:[]
          ~created_at:12L ~changed_at:12L
          ~fail_at:Capsule_store.Durable.Before_create_current_ref ()
      in
      (match interrupted with
      | Error (Capsule_store.Injected_interruption _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "pre-ref interruption published a capsule");
      let target =
        Scratch.head_id fixture.scratch
        |> require_ok Scratch.error_to_string
        |> Option.get
      in
      Alcotest.(check bool)
        "interruption leaves the new work checkpointed" false
        (Scratch.Checkpoint_id.equal fixture.second target);
      (match Capsule_store.Durable.read_current store id with
      | Error (Capsule_store.Current_ref_missing _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "interruption left a partial capsule visible");
      let retry () =
        Capsule_store.Durable.create_from_current ~store
          ~scratch:fixture.scratch ~root ~id ~title:"retry current"
          ~description:"retry current" ~dependencies:[] ~evidence:[]
          ~created_at:12L ~changed_at:12L ()
        |> require_ok Capsule_store.error_to_string
      in
      let first = retry () in
      let second = retry () in
      let revision = function
        | Capsule_store.Durable.Created_from_current { resolved; _ } ->
            Capsule_store.Durable.resolved_revision_object resolved
        | Capsule_store.Durable.No_current_changes _ ->
            Alcotest.fail "retry did not resume the interrupted creation"
      in
      Alcotest.(check bool)
        "current creation retry is idempotent" true
        (Store.Stored_object_id.equal (revision first) (revision second)))

let enabling_capsule_is_exact_and_safety_checkpoints_existing_work () =
  with_store (fun root store ->
      let id = capsule_id 99 in
      let fixture, created = durable_create root store id in
      write_file (Filename.concat root "tracked") "uncheckpointed work";
      let safety_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let anchor =
        Capsule_store.Durable.enable_for_editing ~store ~scratch:fixture.scratch
          ~root ~capsule:id ~observed_at:13L ~created_at:13L ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check string)
        "editing materialises expected bytes" "first"
        (In_channel.with_open_bin
           (Filename.concat root "tracked")
           In_channel.input_all);
      let anchor_checkpoint =
        Scratch.Checkpoint.load store anchor
        |> require_ok Scratch.error_to_string
      in
      let safety =
        match Scratch.Checkpoint.parent anchor_checkpoint with
        | Some checkpoint -> checkpoint
        | None ->
            Alcotest.fail "editing anchor was not staged after safety work"
      in
      let safety_checkpoint =
        Scratch.Checkpoint.load store safety
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "existing work is safety checkpointed before materialisation" true
        (Snapshot.Snapshot.equal_id safety_snapshot
           (Scratch.Checkpoint.snapshot safety_checkpoint));
      let materialised, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      Alcotest.(check bool)
        "editing result equals immutable revision result" true
        (Snapshot.Snapshot.equal_id materialised
           (Capsule_store.revision_expected_result
              (Capsule_store.Durable.resolved_revision created)));
      let current =
        Capsule_store.Durable.read_current store id
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "editing does not mutate the capsule revision" true
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision created))
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision current))))

let enabling_capsule_restores_bytes_mode_and_symlink_target_exactly () =
  with_store (fun root store ->
      let tracked = Filename.concat root "tracked" in
      let link = Filename.concat root "link" in
      write_file tracked "base";
      Unix.chmod tracked 0o644;
      let scratch = Scratch.open_repository store in
      let base, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:base ~created_at:20L
        |> require_ok Scratch.error_to_string
        |> Scratch.Checkpoint.id
      in
      write_file tracked "target";
      Unix.chmod tracked 0o755;
      Unix.symlink "tracked" link;
      let target, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let target_checkpoint =
        Scratch.checkpoint scratch ~snapshot:target ~source:Scratch.Explicit
          ~observed_at:21L ~created_at:21L
        |> require_ok Scratch.error_to_string
        |> function
        | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
            Scratch.Checkpoint.id checkpoint
      in
      let id = capsule_id 102 in
      ignore
        (Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id
           ~title:"exact edit" ~description:"exact edit" ~dependencies:[]
           ~evidence:[] ~from:initial ~target:target_checkpoint ~created_at:22L
           ~changed_at:22L ()
        |> require_ok Capsule_store.error_to_string);
      write_file tracked "diverged";
      Unix.chmod tracked 0o644;
      Unix.unlink link;
      ignore
        (Capsule_store.Durable.enable_for_editing ~store ~scratch ~root
           ~capsule:id ~observed_at:23L ~created_at:23L ()
        |> require_ok Capsule_store.error_to_string);
      Alcotest.(check string)
        "editing restores exact file bytes" "target"
        (In_channel.with_open_bin tracked In_channel.input_all);
      Alcotest.(check bool)
        "editing restores executable mode" true
        ((Unix.stat tracked).Unix.st_perm land 0o111 <> 0);
      Alcotest.(check string)
        "editing restores exact symlink target" "tracked" (Unix.readlink link))

let enabling_reuses_matching_head_and_failed_apply_keeps_it () =
  with_store (fun root store ->
      let id = capsule_id 100 in
      let fixture, _ = durable_create root store id in
      write_file (Filename.concat root "tracked") "first";
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let matching =
        Scratch.checkpoint fixture.scratch ~snapshot ~source:Scratch.Explicit
          ~observed_at:14L ~created_at:14L
        |> require_ok Scratch.error_to_string
        |> function
        | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
            Scratch.Checkpoint.id checkpoint
      in
      let reused =
        Capsule_store.Durable.enable_for_editing ~store ~scratch:fixture.scratch
          ~root ~capsule:id ~observed_at:15L ~created_at:15L ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "matching scratch head is the editing anchor" true
        (Scratch.Checkpoint_id.equal matching reused);
      let head_before =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      let failed =
        Capsule_store.Durable.enable_for_editing ~store ~scratch:fixture.scratch
          ~root ~capsule:id ~observed_at:16L ~created_at:16L
          ~before_apply:(fun () ->
            write_file (Filename.concat root "tracked") "external mutation")
          ()
      in
      (match failed with
      | Error error
        when String.starts_with ~prefix:"restore plan is stale: "
               (Capsule_store.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale editing materialisation was accepted");
      let head_after =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "failed editing materialisation does not advance scratch head" true
        (Option.equal Scratch.Checkpoint_id.equal head_before head_after))

let folding_from_editing_anchor_creates_an_immutable_revision () =
  with_store (fun root store ->
      let id = capsule_id 101 in
      let fixture, created = durable_create root store id in
      let anchor =
        Capsule_store.Durable.enable_for_editing ~store ~scratch:fixture.scratch
          ~root ~capsule:id ~observed_at:17L ~created_at:17L ()
        |> require_ok Capsule_store.error_to_string
      in
      write_file (Filename.concat root "tracked") "folded after editing";
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let target =
        Scratch.checkpoint fixture.scratch ~snapshot ~source:Scratch.Explicit
          ~observed_at:18L ~created_at:18L
        |> require_ok Scratch.error_to_string
        |> function
        | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
            Scratch.Checkpoint.id checkpoint
      in
      let current = Capsule_store.Durable.resolved_current_ref created in
      let folded =
        Capsule_store.Durable.fold_from_checkpoints ~store
          ~scratch:fixture.scratch ~capsule:id
          ~expected_revision:(Capsule_store.current_revision current)
          ~expected_generation:(Capsule_store.current_generation current)
          ~evidence:[] ~from:anchor ~target ~created_at:19L ~changed_at:19L ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "fold keeps the stable capsule identity" true
        (Id.Capsule_id.equal id
           (Capsule_store.revision_capsule
              (Capsule_store.Durable.resolved_revision folded)));
      Alcotest.(check bool)
        "fold creates a distinct immutable revision" false
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision created))
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision folded))))

let folding_is_cas_protected_and_preserves_history () =
  with_store (fun root store ->
      let id = capsule_id 100 in
      let fixture, initial = durable_create root store id in
      let expected_revision =
        Capsule_store.revision_id
          (Capsule_store.Durable.resolved_revision initial)
      in
      let folded =
        Capsule_store.Durable.fold_from_checkpoints ~store
          ~scratch:fixture.scratch ~capsule:id ~expected_revision
          ~expected_generation:0L ~evidence:[] ~from:fixture.first
          ~target:fixture.second ~created_at:4L ~changed_at:4L ()
        |> require_ok Capsule_store.error_to_string
      in
      let folded_revision = Capsule_store.Durable.resolved_revision folded in
      Alcotest.(check bool)
        "fold creates a new logical revision" false
        (Id.Capsule_revision_id.equal expected_revision
           (Capsule_store.revision_id folded_revision));
      Alcotest.(check bool)
        "fold retains capsule ID" true
        (Id.Capsule_id.equal id
           (Capsule_store.revision_capsule folded_revision));
      Alcotest.(check int)
        "history retains old revision" 2
        (List.length
           (Capsule_store.Durable.history store id
           |> require_ok Capsule_store.error_to_string));
      match
        Capsule_store.Durable.fold_from_checkpoints ~store
          ~scratch:fixture.scratch ~capsule:id ~expected_revision
          ~expected_generation:0L ~evidence:[] ~from:fixture.first
          ~target:fixture.second ~created_at:4L ~changed_at:4L ()
      with
      | Error (Capsule_store.Concurrent_current_update _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale fold was accepted")

let split_and_combine_preserve_sources_and_replay () =
  with_store (fun root store ->
      let source_id = capsule_id 110 in
      let fixture, initial = durable_create root store source_id in
      let source =
        Capsule_store.Durable.fold_from_checkpoints ~store
          ~scratch:fixture.scratch ~capsule:source_id
          ~expected_revision:
            (Capsule_store.revision_id
               (Capsule_store.Durable.resolved_revision initial))
          ~expected_generation:0L ~evidence:[] ~from:fixture.first
          ~target:fixture.second ~created_at:4L ~changed_at:4L ()
        |> require_ok Capsule_store.error_to_string
      in
      let source_revision =
        Capsule_store.revision_id
          (Capsule_store.Durable.resolved_revision source)
      in
      let plan =
        Capsule_store.Durable.plan_split ~store ~source:source_id
          ~left_id:(capsule_id 111) ~left_title:"left" ~left_description:"left"
          ~right_id:(capsule_id 112) ~right_title:"right"
          ~right_description:"right" ~left_operation_indices:[ 0 ]
          ~created_at:5L
        |> require_ok Capsule_store.error_to_string
      in
      let planned_outputs = Capsule_store.Durable.split_plan_outputs plan in
      let planned_source = Capsule_store.Durable.split_plan_source plan in
      Alcotest.(check bool)
        "split plan preserves source revision" true
        (Id.Capsule_revision_id.equal source_revision
           (Capsule_store.revision_link_revision planned_source));
      Alcotest.(check int)
        "split plan has two output capsules" 2
        (List.length planned_outputs);
      let planned_left, planned_right =
        match planned_outputs with
        | [ left; right ] -> (left, right)
        | _ -> Alcotest.fail "split plan output count changed"
      in
      let _, planned_left_revision = planned_left in
      let _, planned_right_revision = planned_right in
      Alcotest.(check bool)
        "split plan preserves source selection" true
        (Capsule_store.Durable.split_plan_selected_operation_indices plan
        = [ 0 ]);
      Alcotest.(check bool)
        "split plan exposes declared composition base" true
        (Snapshot.Snapshot.equal_id
           (Capsule_store.revision_declared_base planned_right_revision)
           (Capsule_store.revision_expected_result planned_left_revision));
      Alcotest.(check int)
        "split plan declares output order" 2
        (List.length (Capsule_store.Durable.split_plan_composition_order plan));
      Alcotest.(check int)
        "split plan lists boundary pins" 2
        (List.length (Capsule_store.Durable.split_plan_boundary_pins plan));
      Alcotest.(check int)
        "split plan publishes no output current refs" 1
        (List.length
           (Capsule_store.Durable.list store
           |> require_ok Capsule_store.error_to_string));
      (match
         Capsule_store.Durable.split ~store ~scratch:fixture.scratch
           ~source:source_id ~left_id:(capsule_id 111) ~left_title:"left"
           ~left_description:"left" ~right_id:(capsule_id 112)
           ~right_title:"right" ~right_description:"right"
           ~left_operation_indices:[ 0 ] ~created_at:5L ~changed_at:5L
           ~confirmed:false ()
       with
      | Error (Capsule_store.Confirmation_required "split") -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "unconfirmed split published output capsules");
      let left, right =
        Capsule_store.Durable.split ~store ~scratch:fixture.scratch
          ~source:source_id ~left_id:(capsule_id 111) ~left_title:"left"
          ~left_description:"left" ~right_id:(capsule_id 112)
          ~right_title:"right" ~right_description:"right"
          ~left_operation_indices:[ 0 ] ~created_at:5L ~changed_at:5L
          ~confirmed:true ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "split does not mutate source" true
        (Id.Capsule_revision_id.equal source_revision
           (Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision
                 (Capsule_store.Durable.read_current store source_id
                 |> require_ok Capsule_store.error_to_string))));
      Alcotest.(check int)
        "split left has one operation" 1
        (List.length
           (Capsule_store.revision_operations
              (Capsule_store.Durable.resolved_revision left)));
      Alcotest.(check int)
        "split right has one operation" 1
        (List.length
           (Capsule_store.revision_operations
              (Capsule_store.Durable.resolved_revision right)));
      (match
         Capsule_store.Durable.split ~store ~scratch:fixture.scratch
           ~source:source_id ~left_id:(capsule_id 113) ~left_title:"bad"
           ~left_description:"bad" ~right_id:(capsule_id 114) ~right_title:"bad"
           ~right_description:"bad" ~left_operation_indices:[ 1 ] ~created_at:6L
           ~changed_at:6L ~confirmed:true ()
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "dependency-breaking split partition was accepted");
      let source_link resolved =
        {
          Capsule_store.capsule =
            Capsule_store.capsule_id
              (Capsule_store.Durable.resolved_capsule resolved);
          Capsule_store.revision =
            Capsule_store.revision_id
              (Capsule_store.Durable.resolved_revision resolved);
          Capsule_store.object_id =
            Capsule_store.Durable.resolved_revision_object resolved;
        }
      in
      let sources = [ source_link left; source_link right ] in
      let combine_plan =
        Capsule_store.Durable.plan_combine ~store ~id:(capsule_id 115)
          ~title:"combined" ~description:"combined" ~sources ~created_at:7L
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check int)
        "combine plan publishes no output current ref" 3
        (List.length
           (Capsule_store.Durable.list store
           |> require_ok Capsule_store.error_to_string));
      Alcotest.(check int)
        "combine plan preserves explicit source order" 2
        (List.length
           (Capsule_store.Durable.combine_plan_composition_order combine_plan));
      let _, planned_combined =
        Capsule_store.Durable.combine_plan_output combine_plan
      in
      Alcotest.(check int)
        "combine plan exposes exact operations" 2
        (List.length (Capsule_store.revision_operations planned_combined));
      (match
         Capsule_store.Durable.combine ~store ~scratch:fixture.scratch
           ~id:(capsule_id 115) ~title:"combined" ~description:"combined"
           ~sources ~created_at:7L ~changed_at:7L ~confirmed:false ()
       with
      | Error (Capsule_store.Confirmation_required "combine") -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "unconfirmed combine published a capsule");
      let combined =
        Capsule_store.Durable.combine ~store ~scratch:fixture.scratch
          ~id:(capsule_id 115) ~title:"combined" ~description:"combined"
          ~sources ~created_at:7L ~changed_at:7L ~confirmed:true ()
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check int)
        "combined revision has both operations" 2
        (List.length
           (Capsule_store.revision_operations
              (Capsule_store.Durable.resolved_revision combined)));
      match
        Capsule_store.Durable.combine ~store ~scratch:fixture.scratch
          ~id:(capsule_id 116) ~title:"bad" ~description:"bad"
          ~sources:[ source_link right; source_link left ]
          ~created_at:8L ~changed_at:8L ~confirmed:true ()
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "incompatible combine sources were accepted")

let corrupt_missing_wrong_type_and_cross_capsule_links_reject () =
  with_store (fun root store ->
      let fixture = make_scratch_fixture root store in
      let create id =
        Capsule_store.Durable.create_from_checkpoints ~store
          ~scratch:fixture.scratch ~id ~title:"links" ~description:"links"
          ~dependencies:[] ~evidence:[] ~from:fixture.initial
          ~target:fixture.first ~created_at:3L ~changed_at:3L ()
        |> require_ok Capsule_store.error_to_string
      in
      let replace id bytes =
        let expected =
          Store.Ref_file.read store
            ~components:(Capsule_store.current_ref_components id)
          |> require_ok Store.error_to_string
        in
        Store.Ref_file.compare_and_swap store
          ~components:(Capsule_store.current_ref_components id)
          ~expected ~replacement:bytes
        |> require_ok Store.error_to_string
      in
      let corrupted_id = capsule_id 120 in
      ignore (create corrupted_id);
      replace corrupted_id "not a current ref";
      (match Capsule_store.Durable.read_current store corrupted_id with
      | Error (Capsule_store.Current_ref_corrupt _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "corrupt current ref resolved");
      let first_id = capsule_id 121 in
      let first = create first_id in
      let second_id = capsule_id 122 in
      let second = create second_id in
      let missing =
        Capsule_store.make_current_ref ~generation:0L ~capsule:first_id
          ~capsule_object:(Capsule_store.Durable.resolved_capsule_object first)
          ~revision:
            (Capsule_store.revision_id
               (Capsule_store.Durable.resolved_revision first))
          ~revision_object:(stored_id 123)
        |> require_ok Capsule_store.error_to_string
      in
      replace first_id (Capsule_store.encode_current_ref missing);
      (match Capsule_store.Durable.read_current store first_id with
      | Error (Capsule_store.Store_error _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "missing revision object resolved");
      let wrong_type =
        Capsule_store.make_current_ref ~generation:0L ~capsule:second_id
          ~capsule_object:(Capsule_store.Durable.resolved_capsule_object second)
          ~revision:
            (Capsule_store.revision_id
               (Capsule_store.Durable.resolved_revision second))
          ~revision_object:
            (Capsule_store.Durable.resolved_capsule_object second)
        |> require_ok Capsule_store.error_to_string
      in
      replace second_id (Capsule_store.encode_current_ref wrong_type);
      (match Capsule_store.Durable.read_current store second_id with
      | Error (Capsule_store.Unexpected_object_type _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "wrong revision object type resolved");
      let third_id = capsule_id 124 in
      let third = create third_id in
      let cross =
        Capsule_store.make_current_ref ~generation:0L ~capsule:third_id
          ~capsule_object:(Capsule_store.Durable.resolved_capsule_object third)
          ~revision:
            (Capsule_store.revision_id
               (Capsule_store.Durable.resolved_revision second))
          ~revision_object:
            (Capsule_store.Durable.resolved_revision_object second)
        |> require_ok Capsule_store.error_to_string
      in
      replace third_id (Capsule_store.encode_current_ref cross);
      (match Capsule_store.Durable.read_current store third_id with
      | Error Capsule_store.Current_ref_capsule_mismatch -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "cross-capsule current ref resolved");
      let parent_id = capsule_id 125 in
      let parent_target = create parent_id in
      let parent_revision =
        Capsule_store.Durable.resolved_revision parent_target
      in
      let child =
        Capsule_store.create_revision
          ~capsule:(Capsule_store.Durable.resolved_capsule parent_target)
          ~parent:
            (Some
               {
                 Capsule_store.revision =
                   Capsule_store.revision_id
                     (Capsule_store.Durable.resolved_revision first);
                 object_id =
                   Capsule_store.Durable.resolved_revision_object first;
               })
          ~declared_base:(Capsule_store.revision_declared_base parent_revision)
          ~expected_result:
            (Capsule_store.revision_expected_result parent_revision)
          ~operations:(Capsule_store.revision_operations parent_revision)
          ~dependencies:[] ~evidence:[] ~boundaries:[]
          ~provenance:Capsule_store.Folded ~created_at:4L
        |> require_ok Capsule_store.error_to_string
      in
      let child_object =
        Capsule_store.store_revision store child
        |> require_ok Capsule_store.error_to_string
      in
      let cross_parent =
        Capsule_store.make_current_ref ~generation:1L ~capsule:parent_id
          ~capsule_object:
            (Capsule_store.Durable.resolved_capsule_object parent_target)
          ~revision:(Capsule_store.revision_id child)
          ~revision_object:child_object
        |> require_ok Capsule_store.error_to_string
      in
      replace parent_id (Capsule_store.encode_current_ref cross_parent);
      match Capsule_store.Durable.history store parent_id with
      | Error (Capsule_store.Parent_link_mismatch _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "cross-capsule parent link resolved")

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
          Alcotest.test_case
            "durable retarget publishes or reports without mutating current"
            `Quick
            durable_retarget_publishes_an_immutable_revision_or_returns_conflicts;
          Alcotest.test_case "creation interruption retry and reuse" `Quick
            durable_creation_interruptions_retry_and_conflict_reuse;
          Alcotest.test_case "current working diff creates and pins" `Quick
            current_working_diff_creation_is_exact_and_pins_after_reopen;
          Alcotest.test_case
            "current working diff no-change and mutation safety" `Quick
            current_working_diff_no_changes_and_mutation_reject_safely;
          Alcotest.test_case "current working diff interruption retry" `Quick
            current_working_diff_interruption_retries_idempotently;
          Alcotest.test_case "editing is exact and safety checkpoints work"
            `Quick
            enabling_capsule_is_exact_and_safety_checkpoints_existing_work;
          Alcotest.test_case "editing restores bytes modes and symlinks" `Quick
            enabling_capsule_restores_bytes_mode_and_symlink_target_exactly;
          Alcotest.test_case
            "editing reuses matching head and rejects stale apply" `Quick
            enabling_reuses_matching_head_and_failed_apply_keeps_it;
          Alcotest.test_case "folding from editing anchor is immutable" `Quick
            folding_from_editing_anchor_creates_an_immutable_revision;
          Alcotest.test_case "folding is CAS protected" `Quick
            folding_is_cas_protected_and_preserves_history;
          Alcotest.test_case "split and combine replay exactly" `Quick
            split_and_combine_preserve_sources_and_replay;
          Alcotest.test_case "corrupt and cross-capsule links reject" `Quick
            corrupt_missing_wrong_type_and_cross_capsule_links_reject;
        ] );
    ]
