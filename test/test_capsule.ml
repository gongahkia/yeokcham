module Capsule = Yeokcham_capsule
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

[@@@warning "-4"]

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

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed =
  Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get

let capsule_id seed =
  Id.Capsule_id.of_bytes (raw_id seed) |> require_ok Id.parse_error_to_string

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed)
  |> require_ok Id.parse_error_to_string

let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)
let content_id seed = Snapshot.Content.of_stored_object_id (stored_id seed)
let file mode content = Scratch.File { mode; content }

let capsule () =
  Capsule.create ~id:(capsule_id 1) ~title:"exact files"
    ~description:"preserves stored content IDs"
    ~dependencies:
      [
        Capsule.Requires_capsule
          { capsule = capsule_id 2; revision = Some (revision_id 3) };
        Capsule.Ordered_after (capsule_id 4);
      ]
  |> require_ok Capsule.construction_error_to_string

let revision ~operations =
  Capsule.create_revision ~id:(revision_id 5) ~capsule:(capsule ()) ~parent:None
    ~declared_base:(snapshot_id 6) ~operations
    ~expected_result:(Some (snapshot_id 7))
    ~evidence:
      [
        {
          Capsule.command = [ "dune"; "runtest" ];
          environment_fingerprint = Some "test-host";
          snapshot = snapshot_id 7;
          status = Capsule.Passed;
          stdout_digest = Some (content_id 8);
          stderr_digest = None;
          started_at = 10L;
          duration_ms = 11L;
        };
      ]
    ~created_at:12L
  |> require_ok Capsule.construction_error_to_string

let revision_with ~id ~capsule ~parent ~operations =
  Capsule.create_revision ~id ~capsule ~parent ~declared_base:(snapshot_id 60)
    ~operations ~expected_result:None ~evidence:[] ~created_at:0L
  |> require_ok Capsule.construction_error_to_string

let revision_applies_exact_transitions () =
  let first = file Snapshot.Regular (content_id 20) in
  let second = file Snapshot.Regular (content_id 21) in
  let executable = file Snapshot.Executable (content_id 21) in
  let third = file Snapshot.Regular (content_id 22) in
  let state =
    Scratch.State.create
      [ ([ "src" ], Scratch.Directory); ([ "src"; "a" ], first) ]
    |> require_ok Scratch.error_to_string
  in
  let target =
    Scratch.State.create
      [
        ([ "src" ], Scratch.Directory);
        ([ "src"; "b" ], executable);
        ([ "src"; "c" ], third);
      ]
    |> require_ok Scratch.error_to_string
  in
  let applied =
    Capsule.apply ~actual_base:(snapshot_id 6) ~state
      (revision
         ~operations:
           [
             Capsule.Exact_file_transition
               {
                 Capsule.transition_path = [ "src"; "a" ];
                 expected_entry = Some first;
                 replacement_entry = Some second;
               };
             Capsule.Mode_change
               {
                 path = [ "src"; "a" ];
                 expected = Snapshot.Regular;
                 replacement = Snapshot.Executable;
               };
             Capsule.Move
               {
                 source = [ "src"; "a" ];
                 destination = [ "src"; "b" ];
                 prior = executable;
               };
             Capsule.Exact_file_transition
               {
                 Capsule.transition_path = [ "src"; "c" ];
                 expected_entry = None;
                 replacement_entry = Some third;
               };
           ])
  in
  Alcotest.(check bool)
    "exact transitions reach expected state" true
    (Scratch.State.equal target applied.Capsule.state);
  Alcotest.(check int)
    "all operations apply exactly" 4
    (List.length applied.Capsule.outcomes);
  Alcotest.(check int)
    "exact application has no conflicts" 0
    (List.length applied.Capsule.conflicts)

let declared_base_mismatch_is_a_value () =
  let state = Scratch.State.create [] |> require_ok Scratch.error_to_string in
  let applied =
    Capsule.apply ~actual_base:(snapshot_id 9) ~state (revision ~operations:[])
  in
  Alcotest.(check bool)
    "state is unchanged" true
    (Scratch.State.equal state applied.Capsule.state);
  if
    not
      (List.exists
         (function Capsule.Declared_base_mismatch _ -> true | _ -> false)
         applied.Capsule.conflicts)
  then Alcotest.fail "base mismatch was not returned as an application conflict"

let text_edit_requires_explicit_exact_fallback () =
  let before = file Snapshot.Regular (content_id 30) in
  let after = file Snapshot.Regular (content_id 31) in
  let state =
    Scratch.State.create [ ([ "file" ], before) ]
    |> require_ok Scratch.error_to_string
  in
  let edit =
    {
      Capsule.edit_path = [ "file" ];
      anchor =
        {
          Capsule.before_context = "before";
          selected = "selected";
          after_context = "after";
        };
      replacement = "replacement";
      fallback_transition =
        {
          Capsule.transition_path = [ "file" ];
          expected_entry = Some before;
          replacement_entry = Some after;
        };
    }
  in
  let applied =
    Capsule.apply ~actual_base:(snapshot_id 6) ~state
      (revision ~operations:[ Capsule.Text_edit edit ])
  in
  Alcotest.(check bool)
    "text edit does not silently apply" true
    (Scratch.State.equal state applied.Capsule.state);
  if
    not
      (List.exists
         (function
           | Capsule.Text_fallback_required { edit = actual; _ } ->
               actual.Capsule.edit_path = [ "file" ]
           | _ -> false)
         applied.Capsule.conflicts)
  then Alcotest.fail "text fallback was not explicit";
  let fallback = Capsule.apply_text_fallback state edit |> require_ok Fun.id in
  let expected =
    Scratch.State.create [ ([ "file" ], after) ]
    |> require_ok Scratch.error_to_string
  in
  Alcotest.(check bool)
    "selected fallback is exact" true
    (Scratch.State.equal expected fallback)

let capsule_and_revision_metadata_are_immutable_values () =
  let capsule = capsule () in
  let revision = revision ~operations:[] in
  Alcotest.(check bool)
    "stable capsule ID is preserved" true
    (Id.Capsule_id.equal (capsule_id 1) (Capsule.id capsule));
  Alcotest.(check string)
    "title is preserved" "exact files" (Capsule.title capsule);
  Alcotest.(check int)
    "dependencies are preserved" 2
    (List.length (Capsule.dependencies capsule));
  Alcotest.(check bool)
    "revision keeps capsule identity" true
    (Id.Capsule_id.equal (Capsule.id capsule)
       (Capsule.revision_capsule revision));
  Alcotest.(check bool)
    "revision ID is preserved" true
    (Id.Capsule_revision_id.equal (revision_id 5)
       (Capsule.revision_id revision));
  Alcotest.(check int)
    "evidence is preserved" 1
    (List.length (Capsule.revision_evidence revision))

let construction_rejects_nonpersistable_identities () =
  let short = Id.Capsule_id.of_bytes "short" |> Result.get_ok in
  let short_error =
    Capsule.create ~id:short ~title:"title" ~description:"description"
      ~dependencies:[]
  in
  if
    not
      (match short_error with
      | Error (Capsule.Invalid_capsule_id_length 5) -> true
      | Error _ | Ok _ -> false)
  then Alcotest.fail "short capsule ID was accepted";
  let empty_title =
    Capsule.create ~id:(capsule_id 40) ~title:"" ~description:"description"
      ~dependencies:[]
  in
  if
    not
      (match empty_title with
      | Error Capsule.Empty_title -> true
      | Error _ | Ok _ -> false)
  then Alcotest.fail "empty title was accepted"

let draft_from_checkpoints_replays_and_pins_boundaries () =
  with_directory "yeokcham-capsule-draft-" (fun root ->
      let file = Filename.concat root "file" in
      write_file file "before";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let scratch = Scratch.open_repository store in
      let initial_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:initial_snapshot ~created_at:0L
        |> require_ok Scratch.error_to_string
      in
      write_file file "after";
      let target_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let target =
        Scratch.checkpoint scratch ~snapshot:target_snapshot
          ~source:Scratch.Explicit ~observed_at:1L ~created_at:1L
        |> require_ok Scratch.error_to_string
      in
      let target =
        match target with
        | Scratch.Created checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "target checkpoint was unchanged"
      in
      let draft =
        Capsule.Draft.from_checkpoints ~store ~scratch ~capsule:(capsule ())
          ~revision_id:(revision_id 50)
          ~from:(Scratch.Checkpoint.id initial)
          ~target:(Scratch.Checkpoint.id target)
          ~evidence:[] ~created_at:2L
        |> require_ok Capsule.Draft.error_to_string
      in
      let source_snapshot =
        Snapshot.Snapshot.load store (Capsule.Draft.source_snapshot draft)
        |> require_ok Snapshot.error_to_string
      in
      let source_state =
        Scratch.State.of_snapshot store source_snapshot
        |> require_ok Scratch.error_to_string
      in
      let target_snapshot =
        Snapshot.Snapshot.load store (Capsule.Draft.target_snapshot draft)
        |> require_ok Snapshot.error_to_string
      in
      let target_state =
        Scratch.State.of_snapshot store target_snapshot
        |> require_ok Scratch.error_to_string
      in
      let applied =
        Capsule.apply
          ~actual_base:(Capsule.Draft.source_snapshot draft)
          ~state:source_state
          (Capsule.Draft.revision draft)
      in
      Alcotest.(check bool)
        "range replay reaches target state" true
        (Scratch.State.equal target_state applied.Capsule.state);
      Alcotest.(check int)
        "range replay has no conflicts" 0
        (List.length applied.Capsule.conflicts);
      Alcotest.(check bool)
        "revision records target snapshot" true
        (Option.equal Snapshot.Snapshot.equal_id
           (Some (Capsule.Draft.target_snapshot draft))
           (Capsule.revision_expected_result (Capsule.Draft.revision draft)));
      Capsule.Draft.pin_boundaries scratch draft ~changed_at:3L
      |> require_ok Capsule.Draft.error_to_string;
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened = Scratch.open_repository reopened_store in
      let expected_capsule = Capsule.id (capsule ()) in
      List.iter
        (fun checkpoint ->
          let entry =
            Scratch.timeline reopened ~start:checkpoint ~limit:1 ()
            |> require_ok Scratch.error_to_string
            |> List.hd
          in
          Alcotest.(check bool)
            "capsule boundary survives reopen" true
            (List.exists
               (function
                 | Scratch.Capsule_boundary actual ->
                     Id.Capsule_id.equal expected_capsule actual
                 | _ -> false)
               entry.Scratch.effective_retention))
        [ Scratch.Checkpoint.id initial; Scratch.Checkpoint.id target ])

let draft_rejects_missing_checkpoint () =
  with_directory "yeokcham-capsule-missing-" (fun root ->
      write_file (Filename.concat root "file") "content";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let scratch = Scratch.open_repository store in
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot ~created_at:0L
        |> require_ok Scratch.error_to_string
      in
      let missing = Scratch.Checkpoint_id.of_stored_object_id (stored_id 100) in
      match
        Capsule.Draft.from_checkpoints ~store ~scratch ~capsule:(capsule ())
          ~revision_id:(revision_id 51) ~from:missing
          ~target:(Scratch.Checkpoint.id initial)
          ~evidence:[] ~created_at:1L
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "draft accepted a missing checkpoint")

let catalog_preserves_immutable_revisions_and_history () =
  let stable = capsule () in
  let first =
    revision_with ~id:(revision_id 61) ~capsule:stable ~parent:None
      ~operations:[]
  in
  let second =
    revision_with ~id:(revision_id 62) ~capsule:stable
      ~parent:(Some (Capsule.revision_id first))
      ~operations:
        [
          Capsule.Exact_file_transition
            {
              Capsule.transition_path = [ "file" ];
              expected_entry = None;
              replacement_entry = Some (file Snapshot.Regular (content_id 63));
            };
        ]
  in
  let catalog =
    Capsule.Catalog.empty |> fun catalog ->
    Capsule.Catalog.add_capsule catalog stable
    |> require_ok Capsule.Catalog.error_to_string
    |> fun catalog ->
    Capsule.Catalog.add_revision catalog first
    |> require_ok Capsule.Catalog.error_to_string
    |> fun catalog ->
    Capsule.Catalog.add_revision catalog second
    |> require_ok Capsule.Catalog.error_to_string
  in
  let current =
    Capsule.Catalog.current_revision catalog (Capsule.id stable) |> Option.get
  in
  Alcotest.(check bool)
    "new revision is current" true
    (Id.Capsule_revision_id.equal
       (Capsule.revision_id second)
       (Capsule.revision_id current));
  let history =
    Capsule.Catalog.history catalog (Capsule.id stable)
    |> require_ok Capsule.Catalog.error_to_string
  in
  Alcotest.(check int)
    "all revisions remain addressable" 2 (List.length history);
  Alcotest.(check bool)
    "history starts with current revision" true
    (Id.Capsule_revision_id.equal
       (Capsule.revision_id second)
       (Capsule.revision_id (List.hd history)));
  Alcotest.(check bool)
    "history retains prior revision" true
    (Id.Capsule_revision_id.equal
       (Capsule.revision_id first)
       (Capsule.revision_id (List.nth history 1)));
  let diff =
    Capsule.Catalog.diff catalog
      ~from:(Capsule.revision_id first)
      ~to_:(Capsule.revision_id second)
    |> require_ok Capsule.Catalog.error_to_string
  in
  Alcotest.(check int)
    "revision diff exposes changed operations" 1
    (List.length diff.Capsule.Catalog.to_operations);
  let selected =
    Capsule.Catalog.select_current catalog ~capsule:(Capsule.id stable)
      ~revision:(Capsule.revision_id first)
    |> require_ok Capsule.Catalog.error_to_string
  in
  let selected_current =
    Capsule.Catalog.current_revision selected (Capsule.id stable) |> Option.get
  in
  Alcotest.(check bool)
    "current selection is explicit" true
    (Id.Capsule_revision_id.equal
       (Capsule.revision_id first)
       (Capsule.revision_id selected_current));
  let divergent =
    revision_with
      ~id:(Capsule.revision_id first)
      ~capsule:stable ~parent:None
      ~operations:
        [
          Capsule.Exact_file_transition
            {
              Capsule.transition_path = [ "other" ];
              expected_entry = None;
              replacement_entry = Some (file Snapshot.Regular (content_id 64));
            };
        ]
  in
  (match Capsule.Catalog.add_revision catalog divergent with
  | Error (Capsule.Catalog.Revision_id_collision _) -> ()
  | Error _ | Ok _ -> Alcotest.fail "revision ID collision was accepted");
  let other =
    Capsule.create ~id:(capsule_id 65) ~title:"other" ~description:"other"
      ~dependencies:[]
    |> require_ok Capsule.construction_error_to_string
  in
  let catalog =
    Capsule.Catalog.add_capsule catalog other
    |> require_ok Capsule.Catalog.error_to_string
  in
  let invalid_parent =
    revision_with ~id:(revision_id 66) ~capsule:other
      ~parent:(Some (Capsule.revision_id first))
      ~operations:[]
  in
  match Capsule.Catalog.add_revision catalog invalid_parent with
  | Error (Capsule.Catalog.Parent_capsule_mismatch _) -> ()
  | Error _ | Ok _ -> Alcotest.fail "cross-capsule parent was accepted"

let pure_parent_resolver_rejects_synthetic_cycles () =
  let capsule = capsule_id 70 in
  let first = revision_id 71 in
  let second = revision_id 72 in
  let nodes : Capsule.Parent_resolver.node list =
    [
      {
        Capsule.Parent_resolver.revision = first;
        capsule;
        parent = Some second;
      };
      {
        Capsule.Parent_resolver.revision = second;
        capsule;
        parent = Some first;
      };
    ]
  in
  match Capsule.Parent_resolver.history ~nodes ~capsule ~current:first with
  | Error (Capsule.Parent_resolver.Cycle cycle) ->
      Alcotest.(check bool)
        "cycle rejection identifies the repeated logical revision" true
        (Id.Capsule_revision_id.equal first cycle)
  | Error error -> Alcotest.fail (Capsule.Parent_resolver.error_to_string error)
  | Ok _ -> Alcotest.fail "synthetic parent cycle resolved"

let () =
  Alcotest.run "capsule core"
    [
      ( "unit",
        [
          Alcotest.test_case "revision applies exact transitions" `Quick
            revision_applies_exact_transitions;
          Alcotest.test_case "declared base mismatch is a value" `Quick
            declared_base_mismatch_is_a_value;
          Alcotest.test_case "text fallback remains explicit" `Quick
            text_edit_requires_explicit_exact_fallback;
          Alcotest.test_case
            "capsule and revision metadata are immutable values" `Quick
            capsule_and_revision_metadata_are_immutable_values;
          Alcotest.test_case "construction rejects nonpersistable identities"
            `Quick construction_rejects_nonpersistable_identities;
          Alcotest.test_case "checkpoint range replays and pins boundaries"
            `Quick draft_from_checkpoints_replays_and_pins_boundaries;
          Alcotest.test_case "checkpoint draft rejects missing checkpoints"
            `Quick draft_rejects_missing_checkpoint;
          Alcotest.test_case "catalog preserves immutable revisions and history"
            `Quick catalog_preserves_immutable_revisions_and_history;
          Alcotest.test_case "pure parent resolver rejects cycles" `Quick
            pure_parent_resolver_rejects_synthetic_cycles;
        ] );
    ]
